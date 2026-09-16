import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
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
import '../services/notification_service.dart';
import 'call_service.dart';
import 'protocol.dart';
import 'rc_script.dart';
import 'remote_store.dart';
import 'script_executor.dart';

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

  /// 解密成功的消息广播（控制器 UI 消费回执：rc.tasks/rc.status/rc.pong…）。
  final _rcEvtCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _rcEvtCtrl.stream;

  final _playerChannel = const MethodChannel('sonic_shield/native');

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
    await _connect();
  }

  Future<void> stop() async {
    _running = false;
    _hb?.cancel();
    RcScriptExecutor.instance.stop();
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
    client.onConnected = () =>
        client.subscribe('sonicshield/v1/$deviceId/cmd', MqttQos.atLeastOnce);

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
        await _handleRaw(topic, text);
      }
    });
    client.subscribe('sonicshield/v1/$deviceId/cmd', MqttQos.atLeastOnce);

    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 60), (t) {
      if (!_running ||
          _client?.connectionStatus?.state != MqttConnectionState.connected) {
        t.cancel();
        return;
      }
      unawaited(_send(RcMessage.now(RcEvt.heartbeat)));
    });
  }

  void _scheduleReconnect() {
    if (!_running) return;
    Timer(const Duration(seconds: 10), () {
      if (_running) _connect();
    });
  }

  Future<void> _handleRaw(String topic, String wire) async {
    final store = _store!;
    // 逐配对尝试解密；密钥隔离：每个端点↔控制器配对独立。
    for (final peer in store.paired()) {
      final key = await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|cmd');
      final msg = await RcCodec.decode(wire, key, topic, seenIds: _seen);
      if (msg == null) continue;
      _seen[msg.id] = DateTime.now().millisecondsSinceEpoch;
      _seen.removeWhere(
          (_, t) => DateTime.now().millisecondsSinceEpoch - t > 10 * 60 * 1000);
      await _dispatch(msg, peer);
      if (!_rcEvtCtrl.isClosed) {
        _rcEvtCtrl.add({
          ...msg.toJson(),
          'peerName': peer.name,
          'peerId': peer.deviceId,
        });
      }
      return;
    }
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
        final list = await tasks.listAll();
        await _send(RcMessage.now(RcEvt.tasks, {
          'tasks': [
            for (final t in list)
              {
                'id': t.id,
                'name': t.name,
                'enabled': t.enabled,
                'triggerType': t.triggerType.name,
                'actionType': t.actionType.name,
              }
          ],
        }));
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
  Future<void> _setVolumes(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    try {
      final media = (msg.payload['media'] as num?)?.toDouble();
      final alarm = (msg.payload['alarm'] as num?)?.toDouble();
      await _playerChannel.invokeMethod('volume.set', {
        if (media != null) 'media': media,
        if (alarm != null) 'alarm': alarm,
      });
      await logs.append(
          source: 'remote',
          action: 'volume.set',
          status: 'success',
          message: 'by ${peer.name}');
      await _ack(msg, true);
    } on Object {
      await _ack(msg, false);
    }
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

  Future<void> _playRemote(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final category = msg.payload['category'] as String?;
    final volume =
        ((msg.payload['volume'] as num?)?.toDouble() ?? 0.9).clamp(0.0, 1.0);
    final durationSec = (msg.payload['durationSec'] as num?)?.toInt() ?? 5;
    final loop = msg.payload['loop'] as bool? ?? false;
    var path = category != null && resolvePresetHandler != null
        ? await resolvePresetHandler!(category)
        : null;
    path ??= await _anyAssetPath();
    var ok = false;
    if (path != null && playHandler != null) {
      ok = await playHandler!(path, volume, durationSec * 1000, loop: loop);
    }
    await logs.append(
        source: 'remote',
        action: 'play',
        status: ok ? 'success' : 'failed',
        volume: volume,
        durationMs: durationSec * 1000,
        message: 'by ${peer.name}${category == null ? '' : ' · $category'}');
    await _ack(msg, ok);
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
          var path = category != null && resolvePresetHandler != null
              ? await resolvePresetHandler!(category)
              : null;
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
    final store = _store;
    final client = _client;
    if (store == null || client == null) return;
    if (client.connectionStatus?.state != MqttConnectionState.connected) return;
    final peers = store.paired();
    if (peers.isEmpty) return;
    final topic = 'sonicshield/v1/${store.deviceId}/evt';
    // 逐控制器密钥各发一份（端点↔控制器密钥独立）。
    for (final peer in peers) {
      final key = await RcCodec.deriveKey(peer.secret, '${peer.deviceId}|evt');
      final wire = await RcCodec.encode(msg, key, topic);
      final builder = MqttClientPayloadBuilder()..addString(wire);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
          retain: false);
    }
  }

  /// 控制器侧发送：把消息按目标端点的密钥发到其 cmd 主题。
  /// 未连接（或端点离线）时自动入 outbox，端点上线后冲刷（v1.3）。
  Future<bool> sendTo(PairedEndpoint endpoint, RcMessage msg, RemoteStore store,
      {bool enqueueOnFail = true}) async {
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      if (enqueueOnFail) {
        final wireForLater = jsonEncode(msg.toJson());
        await store.enqueue(wireForLater, endpoint.deviceId);
      }
      return false;
    }
    final topic = 'sonicshield/v1/${endpoint.deviceId}/cmd';
    final key =
        await RcCodec.deriveKey(endpoint.secret, '${endpoint.deviceId}|cmd');
    final wire = await RcCodec.encode(msg, key, topic);
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

  static String _fmt(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
