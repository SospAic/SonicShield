import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../data/db/app_database.dart';
import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';
import '../data/repositories/task_repository.dart';
import '../domain/models/task.dart';
import '../domain/models/trigger.dart';
import '../domain/scheduling/schedule_engine.dart';
import '../services/background_service_manager.dart';
import '../services/native_bridge.dart';
import '../services/notification_service.dart';
import 'call_service.dart';
import 'assist.dart';
import 'assist_host.dart';
import 'assist_join.dart';
import 'guarded_dispatch.dart';
import 'protocol.dart';
import 'rc_script.dart';
import 'remote_playback.dart';
import 'remote_store.dart';
import 'script_executor.dart';
import 'task_wire.dart';

/// 远程遥控端点服务（被控端）。
///
/// 主题：
/// - 订阅 `sonicshield/v1/{deviceId}/cmd`（控制器 → 本机）
/// - 发布 `sonicshield/v1/{deviceId}/evt`（本机 → 控制器广播）
/// - 遗嘱   `sonicshield/v1/{deviceId}/evt`（offline 哨兵，明文，无敏感内容）
///
/// 安全：业务消息 AES-256-GCM 端到端加密（按配对秘密派生）；
/// 时间窗 + 去重防重放（docs/14 §4）。broker 不可见任何内容。
class RcEndpointService {
  RcEndpointService._();
  static final RcEndpointService instance = RcEndpointService._();

  MqttClient? _client;
  RemoteStore? _store;
  AppDatabase? _db;
  bool _running = false;
  final _seen = <String, int>{};
  Timer? _hb;

  /// 本机配对码（共享秘密）：接收消息时用它派生解密密钥。
  String _ownCode = '';

  /// 解密成功的消息广播（控制器 UI 消费回执：rc.tasks/rc.status/rc.pong…）。
  final _rcEvtCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _rcEvtCtrl.stream;

  // 能力注入（由 UI/引擎层提供；端点不直接依赖播放单例）。
  Future<bool> Function(String path, double volume, int durationMs,
      {bool loop})? playHandler;
  Future<String?> Function(String presetCategory)? resolvePresetHandler;
  Future<void> Function(String text, double volume)? ttsHandler;
  Future<void> Function(List<int> pattern)? vibrateHandler;

  bool get isRunning => _running;

  Future<void> start(RemoteStore store, AppDatabase db) async {
    if (_running) return;
    _running = true;
    _store = store;
    _db = db;
    // 接收侧密钥依赖本机配对码（发送方用它加密），必须在连接前就绪。
    _ownCode = await store.ensurePairingCode();
    _wireAssist(store, db);
    await _connect();
  }

  /// 协助会话接线（docs/18 S2）：注入传输、审计、显示名与执行层入口。
  ///
  /// 密钥与会话状态**全部留在** [RcAssistHost] 内，本服务只提供字节通道与
  /// 落库审计，避免会话密钥散落到网络层。
  void _wireAssist(RemoteStore store, AppDatabase db) {
    final assist = RcAssistHost.instance;
    assist.bind(_MqttAssistTransport(this));
    assist.endpointName = store.deviceName;
    assist.audit = (action, status, message) => LogRepository(db).append(
          source: 'assist',
          action: action,
          status: status,
          message: message,
        );
    assist.onCommand = (msg) => _dispatch(msg, _assistPeer());

    // 控制端侧（S3）：同一台设备也可以接入**别人**的会话。
    final join = AssistJoinClient.instance;
    join.bind(_MqttAssistTransport(this));
    join.ctrlName = store.deviceName.isEmpty ? '声盾控制端' : store.deviceName;
  }

  /// 协助会话控制端的虚拟对端。
  ///
  /// 控制端**不是已配对设备**（这正是协助会话的价值：无需预先配对），
  /// 因此没有配对秘密；这里只构造日志/展示所需的身份，`secret` 留空，
  /// 任何把它当密钥用的路径都会立刻失败而不是静默用错密钥。
  PairedEndpoint _assistPeer() {
    final s = RcAssistHost.instance.session;
    final name = s?.ctrlName ?? '';
    return PairedEndpoint(
      deviceId: 'assist',
      name: name.isEmpty ? '协助控制端' : name,
      secret: '',
      pairedAt: DateTime.now(),
    );
  }

  Future<void> stop() async {
    _running = false;
    _hb?.cancel();
    RcScriptExecutor.instance.stop();
    // 先终止协助会话（此刻 _client 仍在，才能发出 close 并退订会合主题）。
    await RcAssistHost.instance.close(reason: 'local', silent: true);
    await AssistJoinClient.instance.leave(silent: true);
    _client?.disconnect();
    _client = null;
  }

  Future<void> _connect() async {
    final store = _store!;
    final deviceId = store.deviceId;
    if (deviceId.isEmpty) return;

    final client =
        _client = MqttServerClient.withPort(store.broker, deviceId, 1883)
          ..port = 1883
          ..keepAlivePeriod = 30
          ..autoReconnect = true
          ..resubscribeOnAutoReconnect = true
          ..logging(on: false);
    client.onConnected = () => unawaited(refreshSubscriptions());

    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(deviceId)
        .withWillTopic('sonicshield/v1/$deviceId/evt')
        .withWillMessage(
            jsonEncode({'type': RcEvt.offline, 'deviceId': deviceId}))
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();

    try {
      await client.connect();
    } on Object {
      _scheduleReconnect();
      return;
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _scheduleReconnect();
      return;
    }
    client.updates!.listen((c) async {
      for (final m in c) {
        final topic = m.topic;
        final payload = m.payload as MqttPublishMessage;
        final text = utf8.decode(payload.payload.message, allowMalformed: true);
        // **绝不能把异常漏出这个回调**：漏出去只会变成一条无人看见的异步错误，
        // 而监听循环会继续 —— 表现为"端点还活着，但对某些命令永远没反应"
        // （BUG-051 的温床）。命令级兜底在 _handleRaw 内（那里能拿到 msg.id，
        // 才好回执），这里只是最后一道防线。
        try {
          await _handleRaw(topic, text);
        } on Object catch (e) {
          // ignore: avoid_print
          print('[sonic_shield][remote] inbound dropped: $e');
        }
      }
    });
    client.subscribe('sonicshield/v1/$deviceId/cmd', MqttQos.atLeastOnce);
    await refreshSubscriptions();

    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 60), (t) {
      if (!_running ||
          _client?.connectionStatus?.state != MqttConnectionState.connected) {
        t.cancel();
        return;
      }
      // 心跳顺带补齐订阅：新增配对后无需重连即可收到对端回执（BUG-013）。
      unawaited(refreshSubscriptions());
      unawaited(_send(RcMessage.now(RcEvt.heartbeat)));
    });
  }

  /// 订阅集合：本机 `cmd`（接收命令）+ 每个已配对端点的 `evt`（接收回执）。
  ///
  /// 端点把回执与通话信令（call.answer / call.candidate）发布到
  /// `sonicshield/v1/{端点ID}/evt`；控制器若不订阅该主题，
  /// 所有回执与信令永久不可达——视频通话会停在 connecting（BUG-013）。
  Future<void> refreshSubscriptions() async {
    final client = _client;
    final store = _store;
    if (client == null || store == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    final own = store.deviceId;
    if (own.isNotEmpty) {
      client.subscribe('sonicshield/v1/$own/cmd', MqttQos.atLeastOnce);
    }
    for (final p in store.paired()) {
      if (p.deviceId.isEmpty || p.deviceId == own) continue;
      client.subscribe('sonicshield/v1/${p.deviceId}/evt', MqttQos.atLeastOnce);
    }
    // 协助会话进行中：重连后必须补订会合主题，否则握手与回执静默丢失
    // （与 BUG-013 同类：订阅集合不补齐 → 对端永远收不到回执）。
    final assist = RcAssistHost.instance.session;
    if (assist != null) {
      client.subscribe(assist.topic, MqttQos.atLeastOnce);
    }
    // 控制端侧接入的会话同样要补订。
    final joined = AssistJoinClient.instance.topic;
    if (joined.isNotEmpty) {
      client.subscribe(joined, MqttQos.atLeastOnce);
    }
  }

  void _scheduleReconnect() {
    if (!_running) return;
    Timer(const Duration(seconds: 10), () {
      if (_running) _connect();
    });
  }

  /// 入站消息分派。
  ///
  /// 密钥模型（两端对称，按**接收方身份**派生）：
  /// 发送方用「接收方 deviceId + 接收方配对码」加密；接收方用自己的
  /// 配对码 + 自己的 deviceId 解密。因此本机既能解密他人发来的命令
  /// （`{本机ID}|cmd`），也能解密对端广播给本机的回执（`{本机ID}|evt`）。
  ///
  /// 旧实现遍历对端列表用 `peer.secret / peer.deviceId` 派生，与发送方
  /// 的加密参数永不相等 → 命令**从未被成功解密**（BUG-021）。
  Future<void> _handleRaw(String topic, String wire) async {
    // 协助会话会合主题与配对遥控主题**命名空间隔离**：它不依赖本机配对码，
    // 密钥由「临时码 + 访问密码」派生，且受权限门控（docs/18 §4.4）。
    //
    // **必须按主题精确路由**：同一台设备可能既在托管会话（端点侧）又在接入
    // 别人的会话（控制端侧），两个主题不同但前缀相同。若一律丢给 Host，
    // Host 会拿自己的 ctlKey 去解密"别人会话"的报文 → 解密失败 →
    // **误计入握手失败计数**，几次之后把自己的会话锁死。
    if (topic.startsWith(RcAssist.topicPrefix)) {
      if (RcAssistHost.instance.session?.topic == topic) {
        await RcAssistHost.instance.onWire(wire);
      } else if (AssistJoinClient.instance.topic == topic) {
        await AssistJoinClient.instance.onWire(wire);
      }
      return;
    }

    final store = _store!;
    final ownId = store.deviceId;
    final ownCode = _ownCode;
    if (ownId.isEmpty || ownCode.isEmpty) return;

    if (topic.endsWith('/evt')) {
      await _handlePeerEvent(topic, wire, ownId, ownCode);
      return;
    }

    final key = await RcCodec.deriveKey(ownCode, '$ownId|cmd');
    final msg = await RcCodec.decode(wire, key, topic, seenIds: _seen);
    if (msg == null) return;
    _rememberSeen(msg.id);
    final peer = _peerOf(msg);
    // 命令处理失败必须**留下痕迹**（BUG-051）：此前处理器抛异常会直接逃逸，
    // 后果是"不回执 + 不写审计"，控制器只看到超时、真实原因被完全隐藏
    // （实测形状：ping 通、status.get 超时）。
    final outcome = await guardDispatch(
      () => _dispatch(msg, peer),
      audit: (reason) => LogRepository(_db!).append(
        source: 'remote',
        action: msg.type,
        status: 'failed',
        message: 'by ${peer.name} · 处理器异常：$reason',
      ),
    );
    if (!outcome.ok) {
      if (!outcome.auditOk) {
        // 连审计都失败（通常是数据库本身不可用）—— 必须被看见。
        // ignore: avoid_print
        print('[sonic_shield][remote] audit failed for '
            '${msg.type}: ${outcome.reason}');
      }
      // 回执失败同样不能外泄，否则又退回静默。
      try {
        await _ack(msg, false, data: '处理器异常：${outcome.reason}');
      } on Object {
        // 信道本身不可用 —— 审计已落盘，不再挣扎。
      }
    }
    _broadcast(msg, peerId: msg.from, peerName: _peerName(msg.from));
  }

  /// 对端广播的回执/信令（`{对端ID}/evt`）：仅解密并转发给 UI，不执行。
  Future<void> _handlePeerEvent(
      String topic, String wire, String ownId, String ownCode) async {
    final parts = topic.split('/');
    final peerId = parts.length >= 3 ? parts[2] : '';

    // LWT 离线哨兵由 broker 代发，明文且无敏感内容，单独识别。
    final trimmed = wire.trimLeft();
    if (trimmed.startsWith('{')) {
      try {
        final j = jsonDecode(trimmed);
        if (j is Map && j['type'] == RcEvt.offline) {
          if (!_rcEvtCtrl.isClosed) {
            _rcEvtCtrl.add({
              'v': 1,
              'id': '',
              'ts': DateTime.now().millisecondsSinceEpoch,
              'type': RcEvt.offline,
              'payload': const <String, dynamic>{},
              'from': peerId,
              'peerId': peerId,
              'peerName': _peerName(peerId),
            });
          }
          return;
        }
      } on Object {
        // 非明文哨兵 → 继续按密文处理
      }
    }

    final key = await RcCodec.deriveKey(ownCode, '$ownId|evt');
    final msg = await RcCodec.decode(wire, key, topic, seenIds: _seen);
    if (msg == null) return;
    _rememberSeen(msg.id);
    _broadcast(msg, peerId: peerId, peerName: _peerName(peerId));
  }

  void _rememberSeen(String id) {
    if (id.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _seen[id] = now;
    _seen.removeWhere((_, t) => now - t > 10 * 60 * 1000);
  }

  void _broadcast(RcMessage msg, {String peerId = '', String peerName = ''}) {
    if (_rcEvtCtrl.isClosed) return;
    _rcEvtCtrl.add({
      ...msg.toJson(),
      if (peerId.isNotEmpty) 'peerId': peerId,
      if (peerName.isNotEmpty) 'peerName': peerName,
    });
  }

  String _peerName(String peerId) {
    if (peerId.isEmpty) return '';
    for (final p in _store?.paired() ?? const <PairedEndpoint>[]) {
      if (p.deviceId == peerId) return p.name;
    }
    return peerId;
  }

  /// 命令发送方（由信封 `from` 反查配对表）。
  ///
  /// 能成功解密即证明其持有本机配对码（配对时物理在场授权），
  /// 反查不到名称时给出占位标识，审计仍然完整。
  PairedEndpoint _peerOf(RcMessage msg) {
    for (final p in _store!.paired()) {
      if (msg.from.isNotEmpty && p.deviceId == msg.from) return p;
    }
    final short = msg.from.length > 6 ? msg.from.substring(0, 6) : msg.from;
    return PairedEndpoint(
      deviceId: msg.from,
      name: msg.from.isEmpty ? '已配对控制器' : '控制器 $short',
      secret: _ownCode,
      pairedAt: DateTime.now(),
    );
  }

  Future<void> _dispatch(RcMessage msg, PairedEndpoint peer) async {
    final db = _db!;
    final logs = LogRepository(db);
    final tasks = TaskRepository(db);
    final occ = OccurrenceRepository(db);

    switch (msg.type) {
      case RcCmd.ping:
        await _send(RcMessage.now(RcEvt.pong, {
          'device': _store!.deviceName,
          'at': DateTime.now().millisecondsSinceEpoch,
        }));
      case RcCmd.statusGet:
        final next = await occ.pendingWithin(
            DateTime.now(), DateTime.now().add(const Duration(days: 7)),
            limit: 1);
        await _send(RcMessage.now(RcEvt.status, {
          'engine': true,
          'pendingCount': await occ.pendingCountAfter(DateTime.now()),
          'nextFireAt':
              next.isEmpty ? null : next.first.fireAt.millisecondsSinceEpoch,
          'version': AppMeta.version,
        }));
      case RcCmd.taskList:
        await _sendTaskList(msg);
      case RcCmd.taskGet:
        await _sendTask(msg);
      case RcCmd.taskUpsert:
        await _upsertTask(msg, peer, logs, tasks, occ);
      case RcCmd.taskDelete:
        await _deleteTask(msg, peer, logs, tasks, occ);
      case RcCmd.taskRunNow:
        await _runTaskNow(msg, peer, logs, tasks);
      case RcCmd.assetList:
        await _sendAssets(msg);
      case RcCmd.presetList:
        await _sendPresets(msg);
      case RcCmd.taskToggle:
        final id = msg.payload['taskId'] as String?;
        final enabled = msg.payload['enabled'] as bool? ?? false;
        if (id != null) {
          await tasks.setEnabled(id, enabled);
          await logs.append(
              source: 'remote',
              action: 'task.toggle',
              status: 'success',
              taskId: id,
              message: 'by ${peer.name}');
          await _ack(msg, true);
        }
      case RcCmd.taskSkipNext:
        final id = msg.payload['taskId'] as String?;
        if (id != null) {
          final n = await occ.skipNextForTask(id);
          await logs.append(
              source: 'remote',
              action: 'task.skipNext',
              status: n > 0 ? 'success' : 'skipped',
              taskId: id,
              message: 'by ${peer.name}');
          await _ack(msg, n > 0);
        }
      case RcCmd.guardSet:
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(
            'guard_enabled', msg.payload['enabled'] as bool? ?? false);
        await logs.append(
            source: 'remote',
            action: 'guard.set',
            status: 'success',
            message: 'by ${peer.name}');
        await _ack(msg, true);
      case RcCmd.soundPlay:
        await _playRemote(msg, peer, logs);
      case RcCmd.logsRecent:
        final limit = (msg.payload['limit'] as num?)?.toInt() ?? 50;
        final rows = await logs.recent(limit: limit);
        await _send(RcMessage.now(RcEvt.logs, {
          'logs': [
            for (final r in rows)
              {
                't': r['created_at'],
                'source': r['source'],
                'action': r['action'],
                'status': r['status'],
              }
          ],
        }));
      case RcCmd.scriptRun:
        await _runScript(msg, peer, logs);
      case RcCmd.scriptStop:
        final sid = msg.payload['scriptId'] as String?;
        if (sid == null ||
            sid == '*' ||
            sid == RcScriptExecutor.instance.currentScriptId) {
          RcScriptExecutor.instance.stop();
          await logs.append(
              source: 'remote',
              action: 'script.stop',
              status: 'success',
              message: 'by ${peer.name}');
        }
        await _ack(msg, true);
      case RcCmd.pttVoice:
        await _playPtt(msg, peer, logs);
      case RcCmd.callInvite:
        await _handleCallInvite(msg, peer);
      case RcCmd.callAnswer:
        await CallService.instance.onAnswer(msg.payload);
      case RcCmd.callCandidate:
        await CallService.instance.onCandidate(msg.payload);
      case RcCmd.callEnd:
        await CallService.instance.onRemoteEnd();
      case RcCmd.deviceStatus:
        await _sendDeviceStatus(msg, peer);
      case RcCmd.cameraSnap:
        // v1.6 降级：camera 插件（camerax 实现）与 AGP9 内置 Kotlin 不兼容，
        // 拍照回传暂缓启用（协议与 UI 保留；见 docs/16 §9 注记）。
        await logs.append(
            source: 'remote',
            action: 'camera.snap',
            status: 'skipped',
            message: 'by ${peer.name} · 等待 camera 插件兼容');
        await _ack(msg, false, data: 'camera.snap 暂未启用');
      case RcCmd.locationGet:
        await _sendLocation(msg, peer, logs);
      case RcCmd.volumeSet:
        await _setVolumes(msg, peer, logs);
    }
  }

  // ==================== v1.7：远程任务 CRUD（docs/14 §2.1） ====================

  /// 单次任务列表回传上限（防止对端拉爆 MQTT 报文）。
  static const maxRemoteTaskList = 200;

  /// 单次音源列表回传上限。
  static const maxRemoteAssetList = 300;

  /// 任务列表。
  ///
  /// `payload.full == true` 时每项为**完整线格式**（含 trigger/action 定义），
  /// 供远程任务编辑页直接渲染；否则保持 v1 轻量形状（向后兼容）。
  Future<void> _sendTaskList(RcMessage msg) async {
    final full = msg.payload['full'] as bool? ?? false;
    final list = await TaskRepository(_db!).listAll();
    final capped = list.take(maxRemoteTaskList).toList();
    await _send(RcMessage.now(RcEvt.tasks, {
      'for': msg.id,
      'full': full,
      'total': list.length,
      'tasks': [
        for (final t in capped)
          if (full)
            TaskWire.toWire(t)
          else
            {
              'id': t.id,
              'name': t.name,
              'enabled': t.enabled,
              'triggerType': t.triggerType.name,
              'actionType': t.actionType.name,
            }
      ],
    }));
  }

  /// 单条任务完整定义。
  Future<void> _sendTask(RcMessage msg) async {
    final id = msg.payload['taskId'] as String?;
    final t = id == null ? null : await TaskRepository(_db!).get(id);
    if (t == null) {
      await _ack(msg, false, data: '任务不存在');
      return;
    }
    await _send(RcMessage.now(RcEvt.task, {
      'for': msg.id,
      'task': TaskWire.toWire(t),
    }));
  }

  /// 新建/更新任务。
  ///
  /// 对端数据视为**不可信**：`TaskWire.fromWire` 白名单校验（枚举可解析、
  /// 数值夹紧、集合有上限）失败即回 `ok=false`，绝不落库。
  /// 成功 → 清理该任务旧 pending 计划 → 按新定义重新物化，否则新任务
  /// 永远不会到期（docs/14 §2.1）。
  Future<void> _upsertTask(
      RcMessage msg,
      PairedEndpoint peer,
      LogRepository logs,
      TaskRepository tasks,
      OccurrenceRepository occ) async {
    final raw = msg.payload['task'];
    final j = raw is Map ? raw.cast<String, dynamic>() : null;
    if (j == null) {
      await _ack(msg, false, data: '缺少 task 定义');
      return;
    }
    final task = TaskWire.fromWire(j);
    if (task == null) {
      await logs.append(
          source: 'remote',
          action: 'task.upsert',
          status: 'failed',
          message: 'by ${peer.name} · 定义校验失败');
      await _ack(msg, false, data: '任务定义非法');
      return;
    }

    final existed = await tasks.get(task.id) != null;
    await tasks.upsert(task);
    final dropped = await occ.deletePendingForTask(task.id);
    final planned = await _rematerialize(task, occ);
    await logs.append(
        source: 'remote',
        action: 'task.upsert',
        status: 'success',
        taskId: task.id,
        message: 'by ${peer.name} · ${existed ? '更新' : '新建'}'
            '「${task.name}」· 清理 $dropped 条旧计划 · 新计划 $planned 条');
    await _send(RcMessage.now(RcEvt.task, {
      'for': msg.id,
      'task': TaskWire.toWire(task),
    }));
    await _ack(msg, true,
        data: '${existed ? 'updated' : 'created'};planned=$planned');
  }

  /// 删除任务及其全部计划（含审计历史，与 UI 侧删除语义一致）。
  Future<void> _deleteTask(
      RcMessage msg,
      PairedEndpoint peer,
      LogRepository logs,
      TaskRepository tasks,
      OccurrenceRepository occ) async {
    final id = msg.payload['taskId'] as String?;
    if (id == null || id.isEmpty) {
      await _ack(msg, false, data: '缺少 taskId');
      return;
    }
    final existed = await tasks.get(id);
    await tasks.delete(id);
    await occ.deleteForTask(id);
    await logs.append(
        source: 'remote',
        action: 'task.delete',
        status: existed == null ? 'skipped' : 'success',
        taskId: id,
        message:
            'by ${peer.name}${existed == null ? '' : ' · ${existed.name}'}');
    await _ack(msg, existed != null, data: existed == null ? '任务不存在' : null);
  }

  /// 立即执行任务动作。
  ///
  /// 真实执行发生在**后台引擎隔离**（插件实例所在），此处只转交并等待结果；
  /// 引擎未运行时明确回失败，不静默成功（docs/14 §2.1）。
  Future<void> _runTaskNow(RcMessage msg, PairedEndpoint peer,
      LogRepository logs, TaskRepository tasks) async {
    final id = msg.payload['taskId'] as String?;
    if (id == null || id.isEmpty) {
      await _ack(msg, false, data: '缺少 taskId');
      return;
    }
    final task = await tasks.get(id);
    if (task == null) {
      await _ack(msg, false, data: '任务不存在');
      return;
    }
    final r = await BackgroundServiceManager.instance.runNow(id);
    await logs.append(
        source: 'remote',
        action: 'task.runNow',
        status: r.ok ? 'success' : 'failed',
        taskId: id,
        message: 'by ${peer.name} · ${r.message}');
    await _send(RcMessage.now(RcEvt.exec, {
      'for': msg.id,
      'taskId': id,
      'taskName': task.name,
      'ok': r.ok,
      'message': r.message,
      'fromName': _store!.deviceName,
    }));
    await _ack(msg, r.ok, data: r.message);
  }

  /// 端点音源库（供远程任务选音源）。
  Future<void> _sendAssets(RcMessage msg) async {
    final limit =
        ((msg.payload['limit'] as num?)?.toInt() ?? maxRemoteAssetList)
            .clamp(1, maxRemoteAssetList);
    final assets = await AssetRepository(_db!).listAll();
    await _send(RcMessage.now(RcEvt.assets, {
      'for': msg.id,
      'total': assets.length,
      'assets': [
        for (final a in assets.take(limit))
          {
            'id': a.id,
            'name': a.name,
            'durationMs': a.durationMs,
            'tags': a.tags,
          }
      ],
    }));
  }

  /// 端点预置音源分类（`audio_assets.tags` 形如 `预置/<分类>`）。
  Future<void> _sendPresets(RcMessage msg) async {
    final rows = await _db!.db.rawQuery(
        "SELECT DISTINCT tags FROM audio_assets WHERE tags LIKE '%预置%'");
    final cats = <String>{};
    for (final r in rows) {
      final tags = r['tags'] as String? ?? '';
      try {
        for (final t in (jsonDecode(tags) as List).cast<String>()) {
          if (t.startsWith('预置/')) cats.add(t.substring(3));
        }
      } on Object {
        // 标签列非 JSON（历史数据）→ 跳过
      }
    }
    final sorted = cats.toList()..sort();
    await _send(RcMessage.now(RcEvt.presets, {
      'for': msg.id,
      'categories': sorted,
    }));
  }

  /// 按当前定义重新物化未来计划（幂等提交）。
  Future<int> _rematerialize(Task task, OccurrenceRepository occ) async {
    if (!task.enabled) return 0;
    if (task.triggerType == TriggerType.soundTriggered) return 0;
    final entries = const ScheduleEngine().materialize(task, DateTime.now());
    if (entries.isEmpty) return 0;
    await occ.commitAll([
      for (final e in entries)
        PlannedOccurrence(
          id: e.occurrenceId,
          taskId: e.taskId,
          fireAt: e.fireAt,
          status: OccurrenceStatus.pending,
          volume: e.volume,
          durationMs: e.durationMs,
        ),
    ]);
    return entries.length;
  }

  /// 设备状态快照（v1.6）：电量/充电/版本/待执行计划数。
  Future<void> _sendDeviceStatus(RcMessage msg, PairedEndpoint peer) async {
    final occ = OccurrenceRepository(_db!);
    var level = -1;
    var charging = false;
    try {
      final st = await Battery().batteryState;
      charging = st == BatteryState.charging || st == BatteryState.full;
      level = await Battery().batteryLevel;
    } on Object {
      // 无电池平台
    }
    final next = await occ.pendingWithin(
        DateTime.now(), DateTime.now().add(const Duration(days: 7)),
        limit: 1);
    await _send(RcMessage.now(RcEvt.device, {
      'for': msg.id,
      'deviceName': _store!.deviceName,
      'batteryLevel': level,
      'charging': charging,
      'version': AppMeta.version,
      'pendingCount': await occ.pendingCountAfter(DateTime.now()),
      'nextFireAt':
          next.isEmpty ? null : next.first.fireAt.millisecondsSinceEpoch,
    }));
  }

  /// 守护定位回传（LOCATION 权限显式授权）。
  Future<void> _sendLocation(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.medium));
      await logs.append(
          source: 'remote',
          action: 'location',
          status: 'success',
          message: 'by ${peer.name} · ${pos.latitude},${pos.longitude}');
      await _send(RcMessage.now(RcEvt.location, {
        'for': msg.id,
        'lat': pos.latitude,
        'lng': pos.longitude,
        'acc': pos.accuracy,
        'fromName': _store!.deviceName,
      }));
    } on Object {
      await _send(RcMessage.now(RcEvt.location,
          {'for': msg.id, 'lat': null, 'lng': null, 'error': true}));
    }
  }

  /// 音量设置（媒体/闹钟 0..1）。
  ///
  /// 走原生桥 `volume.set`（v1.6.1 补齐，此前原生侧无该分支导致
  /// 命令恒返回失败回执——BUG-016）。仅影响媒体/闹钟流，不触碰铃声。
  Future<void> _setVolumes(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final media = (msg.payload['media'] as num?)?.toDouble();
    final alarm = (msg.payload['alarm'] as num?)?.toDouble();
    final ok = await NativeBridge.setVolume(media: media, alarm: alarm);
    await logs.append(
        source: 'remote',
        action: 'volume.set',
        status: ok ? 'success' : 'failed',
        message: 'by ${peer.name}');
    await _ack(msg, ok);
  }

  /// 被叫：收到 invite → 自动接通（设置开启）或弹来电界面（fullScreenIntent）。
  Future<void> _handleCallInvite(RcMessage msg, PairedEndpoint peer) async {
    final video = msg.payload['video'] as bool? ?? true;
    await NotificationService.instance.showEvent(
        title: '声盾 · 来电', body: '来自 ${peer.name}（${video ? '视频' : '语音'}）');
    await CallService.instance.onIncomingCall(msg.payload, peer, _store!,
        onManualRing: (callId, fromName, vid) {
      // 手动接听模式：亮屏来电页（v1.4 简化：也走自动接通页，UI 内可拒接）。
      unawaited(CallService.instance
          .acceptIncoming(msg.payload, peer, _store!, video: vid));
    });
    unawaited(_send(RcMessage.now(RcEvt.callState, {
      'callId': msg.payload['callId'],
      'state': 'ringing',
    })));
  }

  /// `sound.play`：解析选择器 → 播放 → 审计 → 回执。
  ///
  /// 决策链全部在 [performRemotePlay] 内（宿主机可断言）。此前这里直接读
  /// `msg.payload['category']` 并把解析失败**静默回落**到"任意一条音源"，
  /// 于是点名 `assetId` / `preset` 会被换成另一段声音而回执仍是 `ok=true`
  /// —— 见 BUG-048。现在"点名了却找不到"会如实回 `ok=false` + 原因。
  Future<void> _playRemote(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final r = await performRemotePlay(
      msg.payload,
      byId: _assetPathById,
      byTag: (tag) => _resolvePreset(tag),
      any: _anyAssetPath,
      play: playHandler,
    );
    await logs.append(
        source: 'remote',
        action: 'play',
        status: r.ok ? 'success' : 'failed',
        volume: r.volume,
        durationMs: r.durationMs,
        message: 'by ${peer.name} · ${r.reason}');
    await _ack(msg, r.ok, data: r.path == null ? r.reason : null);
  }

  Future<void> _runScript(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final script = RcScript.fromPayload(msg.payload);
    final err = RcScript.validate(script.steps);
    if (err != null) {
      await _ack(msg, false, data: err);
      return;
    }
    // 弹 heads-up：发送方/时间 + 立即执行（通知栏进度与终止按钮由执行器管理）。
    await NotificationService.instance.showEvent(
      title: '声盾 · 收到远程指令组',
      body: '来自 ${script.fromName} · ${_fmt(script.sentAt)}\n'
          '${script.name}（${script.steps.length} 步）—— 立即执行',
    );

    Future<void> runner(RcStep step) async {
      final cancel = RcScriptExecutor.instance.activeCancel;
      switch (step.kind) {
        case RcStepKind.delay:
          final sec = ((step.params['seconds'] as num?)?.toDouble() ?? 1)
              .clamp(0.5, 600);
          await (cancel?.sleep(Duration(milliseconds: (sec * 1000).round())) ??
              Future<void>.delayed(
                  Duration(milliseconds: (sec * 1000).round())));
        case RcStepKind.play:
          final category = step.params['presetCategory'] as String?;
          var path = await _resolvePreset(category);
          path ??= await _anyAssetPath();
          final vol = ((step.params['volume'] as num?)?.toDouble() ?? 0.9)
              .clamp(0.0, 1.0)
              .toDouble();
          final dur =
              ((step.params['durationSec'] as num?)?.toInt() ?? 10) * 1000;
          if (path != null && playHandler != null) {
            // 可中断播放：轮询终止令牌。
            unawaited(_interruptibleWatch(cancel));
            await playHandler!(path, vol, dur, loop: false);
          }
        case RcStepKind.tts:
          if (ttsHandler != null) {
            await ttsHandler!(step.params['text'] as String? ?? '',
                ((step.params['volume'] as num?)?.toDouble() ?? 0.8));
          }
        case RcStepKind.notify:
          await NotificationService.instance.showEvent(
              title: step.params['title'] as String? ?? '声盾',
              body: step.params['body'] as String? ?? '');
        case RcStepKind.vibrate:
          if (vibrateHandler != null) {
            await vibrateHandler!(const [0, 300, 200, 300]);
          }
        case RcStepKind.record:
          await _recordEvidence(
              seconds: (step.params['seconds'] as num?)?.toInt() ?? 30);
      }
    }

    await logs.append(
        source: 'remote',
        action: 'script.run',
        status: 'success',
        message:
            '${script.fromName} · ${script.name}（${script.steps.length} 步）');

    final done = await RcScriptExecutor.instance.run(script, runner: runner,
        onStep: (i, s) {
      unawaited(_send(RcMessage.now(RcEvt.scriptState, {
        'scriptId': script.scriptId,
        'state': 'running',
        'stepIndex': i,
      })));
    });
    unawaited(_send(RcMessage.now(RcEvt.scriptState, {
      'scriptId': script.scriptId,
      'state': done ? 'done' : 'stopped',
    })));
  }

  /// 终止监听哨兵：终止时立即停掉当前播放器（playHandler 内部循环也会轮询）。
  static Future<void> _interruptibleWatch(RcCancel? cancel) async {
    if (cancel == null) return;
    await cancel.future;
  }

  Future<void> _recordEvidence({required int seconds}) async {
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) return;
      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/evidence_rc_${DateTime.now().millisecondsSinceEpoch}.evidence.m4a';
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path);
      await Future<void>.delayed(Duration(seconds: seconds));
      await rec.stop();
      await LogRepository(_db!).append(
          source: 'remote',
          action: 'record',
          status: 'success',
          durationMs: seconds * 1000,
          message: path);
    } on Object {
      // ignore
    }
  }

  /// 对讲机接收：解密信封内的 AAC 音频落盘并自动播放。
  Future<void> _playPtt(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final audioB64 = msg.payload['audioB64'] as String?;
    final from = msg.payload['fromName'] as String? ?? peer.name;
    if (audioB64 == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/ptt_${const Uuid().v4()}.m4a';
      await File(path).writeAsBytes(base64Decode(audioB64), flush: true);
      await NotificationService.instance
          .showEvent(title: '声盾 · 对讲', body: '来自 $from 的语音');
      if (playHandler != null) {
        await playHandler!(path, 1.0, 0);
      }
      await logs.append(
          source: 'remote',
          action: 'ptt.play',
          status: 'success',
          message: 'from $from');
      unawaited(_send(RcMessage.now(RcEvt.pttAck, {
        'voiceId': msg.payload['voiceId'],
        'ok': true,
      })));
    } on Object {
      // ignore
    }
  }

  Future<void> _ack(RcMessage forMsg, bool ok, {Object? data}) async {
    await _send(RcMessage.now(RcEvt.ack, {
      'ok': ok,
      'for': forMsg.id,
      'forType': forMsg.type,
      if (data != null) 'data': data.toString(),
    }));
  }

  Future<void> _send(RcMessage msg) async {
    // 协助会话期间的回执必须**原路返回会合主题**：对端不是已配对设备，
    // 收不到 `{deviceId}/evt`，走下面那条路会静默丢弃（表现为"命令执行了
    // 但控制端毫无反应"）。通道由 Zone 承载，见 [assistReplyZone]。
    if (Zone.current[assistReplyZone] == true) {
      await RcAssistHost.instance.sendReply(msg);
      return;
    }

    final store = _store;
    final client = _client;
    if (store == null || client == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    final peers = store.paired();
    if (peers.isEmpty) return;
    // 补发方标识（端点自己的 deviceId），便于控制器侧展示来源。
    final out = msg.from.isEmpty
        ? RcMessage(
            id: msg.id,
            ts: msg.ts,
            type: msg.type,
            payload: msg.payload,
            from: store.deviceId,
          )
        : msg;
    final topic = 'sonicshield/v1/${store.deviceId}/evt';
    // 逐控制器密钥各发一份（端点↔控制器密钥独立）。
    for (final peer in peers) {
      final key = await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|evt');
      final wire = await RcCodec.encode(out, key, topic);
      final builder = MqttClientPayloadBuilder()..addString(wire);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
          retain: false);
    }
  }

  /// 控制器侧发送：把消息按目标端点的密钥发到其 cmd 主题。
  /// 未连接（或端点离线）时自动入 outbox，端点上线后冲刷（v1.3）。
  Future<bool> sendTo(PairedEndpoint endpoint, RcMessage msg, RemoteStore store,
      {bool enqueueOnFail = true}) async {
    // 统一补发方标识：接收端据此反查发送方名称并渲染回执（不参与鉴权）。
    final out = msg.from == store.deviceId
        ? msg
        : RcMessage(
            id: msg.id,
            ts: msg.ts,
            type: msg.type,
            payload: msg.payload,
            from: store.deviceId,
          );
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      if (enqueueOnFail) {
        final wireForLater = jsonEncode(out.toJson());
        await store.enqueue(wireForLater, endpoint.deviceId);
      }
      return false;
    }
    final topic = 'sonicshield/v1/${endpoint.deviceId}/cmd';
    final key =
        await RcCodec.deriveKey(endpoint.secret, '${endpoint.deviceId}|cmd');
    final wire = await RcCodec.encode(out, key, topic);
    final builder = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: false);
    return true;
  }

  /// 端点/连接恢复后冲刷该端点的暂存命令（按序重发）。
  Future<int> flushOutbox(RemoteStore store, PairedEndpoint endpoint) async {
    var sent = 0;
    for (final m in store.drainOutbox(endpoint.deviceId)) {
      final wire = m['wire'] as String?;
      if (wire == null) continue;
      final topic = 'sonicshield/v1/${endpoint.deviceId}/cmd';
      final key =
          await RcCodec.deriveKey(endpoint.secret, '${endpoint.deviceId}|cmd');
      final clear = await RcCodec.decode(wire, key, topic);
      if (clear == null) continue;
      final reEnc = await RcCodec.encode(clear, key, topic);
      final builder = MqttClientPayloadBuilder()..addString(reEnc);
      _client?.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
          retain: false);
      sent++;
    }
    return sent;
  }

  Future<String?> _anyAssetPath() async {
    final rows = await _db!.db
        .query('audio_assets', orderBy: 'created_at DESC', limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  /// 按 ID 精确取音源路径。
  ///
  /// BUG-048：`sound.play {assetId}` 此前**完全被忽略** ——
  /// 协议声明支持 `assetId`，端点却只看 `category`。
  Future<String?> _assetPathById(String id) async {
    final rows = await _db!.db.query('audio_assets',
        columns: ['path'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String?;
  }

  /// 按预置分类随机取一条（导入预置库时标签为 `预置/<分类>`）。
  ///
  /// 未注入 [resolvePresetHandler] 时回落到内置查询，保证 sound.play 与
  /// 指令组 play 步骤在未显式注入时依然可用（BUG-015 关联）。
  Future<String?> _resolvePreset(String? category) async {
    if (category == null || category.isEmpty) return null;
    if (resolvePresetHandler != null) return resolvePresetHandler!(category);
    final rows = await _db!.db.query('audio_assets',
        where: 'tags LIKE ? AND tags LIKE ?',
        whereArgs: ['%预置%', '%$category%'],
        orderBy: 'RANDOM()',
        limit: 1);
    return rows.isEmpty ? null : rows.first['path'] as String;
  }

  static String _fmt(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// [AssistTransport] 的 MQTT 实现：只负责"订阅 / 退订 / 发布字节"。
///
/// 定义在**同一文件内**是为了访问 [RcEndpointService] 的私有连接状态
/// （Dart 私有性按库划分）；它刻意不持有任何密钥 —— 密文由
/// [RcAssistHost] 加密后传入，密钥不出该模块。
class _MqttAssistTransport implements AssistTransport {
  _MqttAssistTransport(this._svc);

  final RcEndpointService _svc;

  @override
  Future<void> subscribe(String topic) async {
    final client = _svc._client;
    if (client == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    client.subscribe(topic, MqttQos.atLeastOnce);
  }

  @override
  Future<void> unsubscribe(String topic) async {
    _svc._client?.unsubscribe(topic);
  }

  @override
  Future<void> publishWire(String topic, String wire) async {
    final client = _svc._client;
    if (client == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    final builder = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: false);
  }
}
