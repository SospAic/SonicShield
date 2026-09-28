import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../data/db/app_database.dart';
import '../data/repositories/log_repository.dart';
import '../data/repositories/occurrence_repository.dart';
import '../data/repositories/task_repository.dart';
import '../domain/models/action.dart';
import '../domain/models/task.dart';
import '../domain/models/trigger.dart';
import '../domain/scheduling/schedule_engine.dart';
import '../services/background_service_manager.dart';
import '../services/native_bridge.dart';
import '../services/notification_service.dart';
import 'call_lifecycle.dart';
import 'call_service.dart';
import 'assist.dart';
import 'assist_host.dart';
import 'assist_join.dart';
import 'guarded_dispatch.dart';
import 'kdf_salt_store.dart';
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
///
/// 传输：MQTT **TLS 8883 + 证书链强校验**（C-13 P0，见 [_connect]）。
/// 端到端加密挡的是"broker 看内容"，TLS 挡的是"链路上篡改/丢弃信封" ——
/// 两者不能互相替代：把 `script.stop` 从明文链路上丢掉，E2E 加密毫无办法。
class RcEndpointService {
  RcEndpointService._();
  static final RcEndpointService instance = RcEndpointService._();

  MqttClient? _client;
  RemoteStore? _store;
  AppDatabase? _db;
  bool _running = false;
  final _seen = <String, int>{};
  Timer? _hb;

  /// Q10：各发送方最近**被放行**命令的时间戳（滑窗限流的内存表）。
  ///
  /// 只存非停类命令；每端点上限 [maxCmdTsPerEndpoint] 条防涨，出窗即裁。
  /// 纯内存、不落库 —— 被拒的命令也不记入（否则每次拒绝都会把窗口往后推，
  /// 形成"越拒越久"的惩罚螺旋）。
  final Map<String, List<int>> _cmdTs = <String, List<int>>{};

  /// 当前在途**指令组**的发起方 deviceId（P1 撤销清场用）。null = 无在途。
  ///
  /// 为什么不从 `RcScript` 上取：`RcScript` 是**线协议模型**（`fromName` 只够
  /// 弹窗展示），把 deviceId 塞进去会改动线格式与 `toJson/fromJson`；
  /// 而"谁能停掉它"是**端点本机**的会话状态，放在服务里更内聚。
  ///
  /// 通话那一半**不需要**在这里另存：`CallService.peerDeviceId` 已经能回答
  /// "对端是谁"，且它随通话收尾一并清空（少一份会漂移的状态）。
  String? _activeScriptOwner;

  /// 本机配对码（共享秘密）：接收消息时用它派生解密密钥。
  String _ownCode = '';

  /// 每设备 KDF 随机盐的存取（Q1.B）。
  ///
  /// 生产路径在 [start] 里用 `SharedPreferences.getInstance()` 装配（与
  /// [RemoteStore] 同一份 prefs —— 但 `RemoteStore` 不暴露其 `_prefs`，
  /// 故这里自行取一份单例）。
  ///
  /// ⚠️ 端点服务是**单例**、宿主测试无法实例化 ⇒ 读取/生成盐的语义已抽到
  /// **顶层函数** `ensureSaltForDevice`（本文件末尾），由**行为锁**
  /// `test/salt_reuse_lock_test.dart` 覆盖。
  /// （第 36 轮删除了原先那个**零调用点**的 `injectSaltStore` 注入缝：
  /// 本类无法实例化 ⇒ 该缝永远不可能被测试用上，属死代码。）
  ///
  /// ⚠️ 盐按**对端 deviceId** 存储：端点侧在 `_handlePairRequest` 里按控制端
  /// deviceId 落盘，控制端在 `requestPairing` 收下发的盐时按端点 deviceId 落盘。
  /// 读取到 null（旧配对端点）时，调用方**必须**走 [RcCodec.deriveKey] 的无盐
  /// 旧路径（v1，逐字节不变）—— 绝不能传零盐/默认盐等替代品（那会让已配对
  /// 设备在升级后**静默失联**）。
  KdfSaltStore? _saltStore;

  /// 取得（必要时生成并持久化）与 [deviceId] 配对的盐；未装配盐存储返回 null。
  ///
  /// ⚠️ 语义**真源在顶层函数** `ensureSaltForDevice`（本文件末尾），这里只做转发。
  /// **为什么不在本方法里实现**：本类是**私有构造的单例**（`RcEndpointService._()`），
  /// 宿主测试**无法实例化**它 ⇒ 语义内联在这里就只剩"源码锁"可用，而源码锁锁不住
  /// 语义（把"取已存盐"与"生成新盐"写反了照样能过 —— 本文件已有过同类假绿通道）。
  /// 抽到顶层后，可以用真实盐存储做**行为**断言，见 `test/salt_reuse_lock_test.dart`。
  Future<List<int>?> _ensureSalt(String deviceId) =>
      ensureSaltForDevice(_saltStore, deviceId);

  /// 落盘对端随配对成功回执下发的盐（Q1.B）。
  ///
  /// 缺字段 / 非法 Base64 → **保持现状**：宁可用旧盐继续可用，也不要把一个
  /// 坏值写进去导致该端点全面失联（"降级到更不安全的一侧"的反面 ——
  /// 这里连降级都没有，是"不破坏已工作的状态"）。
  Future<void> _savePeerSalt(String deviceId, Object? rawB64) async {
    final store = _saltStore;
    if (store == null || deviceId.isEmpty) return;
    if (rawB64 is! String || rawB64.isEmpty) return;
    try {
      final salt = base64Decode(rawB64);
      if (salt.isEmpty) return;
      await store.saveSalt(deviceId, salt);
    } on Object {
      // 对端下发的 Base64 非法：不写坏值，也不打断配对结果（配对本身已成功）。
    }
  }

  /// 解密失败审计的限频器（R-2）。按**主题**限频：同一主题 10s 内只写一条。
  final DecodeFailThrottle _decodeFail = DecodeFailThrottle();

  /// 因**发送方已不在配对表**而拒绝命令时的审计限频器（P0 授权撤销）。
  ///
  /// 按**发送方**限频：被解除配对的控制端本机仍留着端点，它的
  /// `flushAllOutbox` 会在每次连接/心跳（60s）重放命令；不限频会把审计刷成
  /// 噪声，反而淹掉真正需要被看见的那一条（与 [_decodeFail] 同一考量，
  /// 复用同一个限频器类：它的行为是通用的「按 key 开窗」）。
  final DecodeFailThrottle _rejectFlood = DecodeFailThrottle();

  /// 解密成功的消息广播（控制器 UI 消费回执：rc.tasks/rc.status/rc.pong…）。
  final _rcEvtCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _rcEvtCtrl.stream;

  // 能力注入（由 UI/引擎层提供；端点不直接依赖播放单例）。
  Future<bool> Function(String path, double volume, int durationMs,
      {bool loop})? playHandler;
  Future<String?> Function(String presetCategory)? resolvePresetHandler;
  Future<void> Function(String text, double volume)? ttsHandler;
  Future<void> Function(List<int> pattern)? vibrateHandler;

  /// v1.9：参数化振动步骤（`mode` = random/continuous）的执行器。
  ///
  /// ⚠️ 与 [vibrateHandler] 分工明确：
  /// - [vibrateHandler] 只处理**固定节奏**（老语义，协议向后兼容）；
  /// - 本处理器处理随机/持续振动，转交引擎隔离的 `VibrateSession`。
  ///
  /// 未注入时随机/持续步骤**什么都不做并写 `skipped` 审计** ——
  /// 绝不退回固定节奏"敷衍一下"：那是对端要"持续振动 30 秒（强度 50–100%）"、
  /// 端点却震了两下就完了，属于"承诺了没做到还没留痕"（FR-34 / BUG-059 通则）。
  Future<RunNowResult> Function({
    required ActionConfig action,
    required String occurrenceId,
  })? vibrateActionHandler;

  /// 宿主测试接缝（第 36 轮续四新增；**不改任何既有方法的签名或行为**）。
  ///
  /// 入站链路 `_handleRaw → _dispatch` 的唯一生产调用者是真实 MQTT
  /// `client.updates` 监听器，宿主机连不上 broker，且全文件此前**无任何
  /// 注入缝** ⇒ 20 余个子处理器一条都驱动不到。这里只提供"直接注入依赖 +
  /// 直接驱动 _dispatch"的最小通道，让行为可被断言。
  ///
  /// ⚠️ 仅 `@visibleForTesting`：生产代码绝不调用；`guarded_dispatch_test.dart`
  /// 与 `unpair_revoke_test.dart` 的源码锁断言的是**既有调用点形状**
  /// （`await _dispatch(msg, _peerOf(msg))` / `_handleRaw` 方法体不含 `_dispatch(`），
  /// 本接缝的 `=> _dispatch(msg, peer)` 是箭头函数、不产生 `await _dispatch(` 文本，
  /// 不会令那些锁误判红。
  @visibleForTesting
  void debugBind({
    required RemoteStore store,
    required AppDatabase db,
    KdfSaltStore? saltStore,
  }) {
    _store = store;
    _db = db;
    _saltStore = saltStore;
  }

  /// 直接驱动一条已解码消息（绕过 topic 解析/解密/鉴权，等价于 broker 投递后
  /// 解密成功、准入与限流均通过的路径）。
  @visibleForTesting
  Future<void> debugDispatch(RcMessage msg, PairedEndpoint peer) =>
      _dispatch(msg, peer);

  /// 出站发送的宿主替身（第 45 轮新增；**不改 `sendTo` 的签名与默认行为**）。
  ///
  /// `sendTo` 的**成功**分支要求 `_client` 存在且
  /// `connectionStatus.state == connected` —— 宿主机连不上 broker，
  /// 于是"发出去之后"的整条链路在宿主上**结构性不可达**：通话信令的
  /// `sent == true` 分支、多路视频的建连中段、候选重放 …
  /// 这些此前只有源码锁兜底（`docs/17 §74` 判据第五代：
  /// **"源码锁是绿的" ≠ "那条业务路径被执行过"**）。
  ///
  /// 注入后 [sendTo] 在进入任何真实发送逻辑**之前**直接转交替身：
  /// * 替身为 `null`（生产恒为 null）⇒ 逐字节走原路径，行为不变；
  /// * 替身返回 `true` ⇒ 等价于"broker 已受理并投递"。
  ///
  /// ⚠️ 仅 `@visibleForTesting`（`analysis_options.yaml` 已把
  /// `invalid_use_of_visible_for_testing_member` 设为 error，生产调用会编译失败）。
  @visibleForTesting
  Future<bool> Function(PairedEndpoint endpoint, RcMessage msg,
      RemoteStore store, bool enqueueOnFail)? debugSendTo;

  /// 装配本机配对码（接收侧派生的输入之一）。
  ///
  /// 生产路径在 [start] 里从 `RemoteStore.ensurePairingCode()` 装配，而 [start]
  /// 紧接着就要去真连 broker —— 宿主机连不上 ⇒ 接收侧密钥**永远装配不出来**，
  /// 入站链路整段不可达。本缝只做赋值，**不改任何既有方法的行为**。
  @visibleForTesting
  void debugSetOwnCode(String code) {
    _ownCode = code;
  }

  /// 直接驱动一次**入站原始报文**（等价于 broker 投递到 `client.updates`
  /// 监听器的那一刻）。
  ///
  /// [debugDispatch] 绕过的是入站链路的**整条前端** —— 主题命名空间路由
  /// （协助会合 vs 配对遥控）、cmd 多盐候选试解、准入裁决、限流窗口与停类插队、
  /// `guardDispatch` 兜底、以及收尾广播。那一整段此前的唯一生产入口是真实 MQTT
  /// 监听器，宿主上只有源码锁（`docs/17 §74` 判据第五代：
  /// **"源码锁是绿的" ≠ "那条业务路径被执行过"**）。本缝让它能被**行为**驱动。
  ///
  /// ⚠️ 本缝是**箭头函数** ⇒「`_connect` 的入站监听器是唯一生产调用点」那条
  /// 形状锁（`guarded_dispatch_test.dart` 在监听器起点之后检索那句调用）不会
  /// 误判红 —— 箭头体里的调用形态与那句以 `await` 起头的语句**不同形**。
  ///
  /// 🔴 **本段注释刻意不写出 `_handleRaw` 的完整声明签名**（连类型前缀一起）。
  /// 原因：`test/support/source_text.dart` 的 `methodBody()` 用
  /// `src.indexOf(signature)` 定位 —— 它拿的是**原始源码**（这几处锁没有先
  /// `stripComments`）。注释里出现同一个字符串 ⇒ 定位到注释、切片"平衡但错误"，
  /// `DF-05` / `UR-10` / `WR-01` / `Q1-09` 会集体假红（**第四十七轮实测现场**）。
  /// 教训与 `source_text.dart` 文件头写的是同一条：**判源码文本前先剥注释**，
  /// 而"不剥注释"的调用点时，注释本身就成了毒。
  @visibleForTesting
  Future<void> debugHandleRaw(String topic, String wire) =>
      _handleRaw(topic, wire);

  /// MQTT 客户端工厂替身（第四十八轮新增）。
  ///
  /// 传输整层（连接/订阅/发送/补发/订阅接口）的运行前提是「有一个 MQTT
  /// 客户端、且状态为 connected」，而宿主连不上 broker ⇒ 这一桶
  /// 约 128 行此前**一行都没被执行过**，只有源码文本锁兜底。
  /// 第四十四轮立的判据第五代正是冲这个来的：
  /// **「源码锁是绿的」 ≠ 「那条业务路径被执行过」**。
  ///
  /// 之所以能做成替身（而不是像 `flutter_webrtc` / `just_audio` 那样
  /// 只能另找切入点）：`mqtt_client` 的客户端是**纯 Dart 类**，
  /// **不是平台通道**；`connect` / `publishMessage` / `subscribe` /
  /// `unsubscribe` / `disconnect` 与 getter `connectionStatus` / `updates`
  /// 全是可覆写的普通成员 ⇒ 子类覆写后跑的**是生产代码本身**。
  /// 替身见 `test/support/mqtt_client_stub.dart`。
  ///
  /// 为 `null`（生产恒为 null）⇒ 逐字节走原路径：端口来源、`secure`、
  /// 遗嘱、凭据门、ack 类级联**一个字段都不变**
  /// （`test/rc_transport_lock_test.dart` 与 `test/q35_endpoint_wiring_test.dart`
  /// 仍在锁着这些不变量）。
  ///
  /// ⚠️ 与第 47 轮同一个教训：本段注释**刻意不写出任何被测方法的完整声明
  /// 签名**（也不写出客户端工厂的全名 + 点号 + 方法名的连写形式）。
  /// 理由：若干文本锁用 `indexOf(签名)` 在**未剥注释**的源码上定位
  /// （`test/support/source_text.dart` 的注记），注释里出现同一字符串
  /// 会让定位命中注释、切片"平衡但错误" ⇒ **假红，不是回归**。
  @visibleForTesting
  MqttServerClient Function(String broker, String clientId, int port)?
      debugClientFactory;

  bool get isRunning => _running;

  Future<void> start(RemoteStore store, AppDatabase db) async {
    if (_running) return;
    _running = true;
    _store = store;
    _db = db;
    // Q1.B：装配每设备盐存储（注入过就沿用 —— 宿主测试的 seam）。
    _saltStore ??= KdfSaltStore(await SharedPreferences.getInstance());
    // 接收侧密钥依赖本机配对码（发送方用它加密），必须在连接前就绪。
    _ownCode = await store.ensurePairingCode();
    _wireAssist(store, db);
    _wireCall();
    await _connect();
  }

  /// 通话信令接线（BUG-050）。
  ///
  /// 被叫振铃超时后，由**端点**发出 `RcEvt.callMissed` —— 主叫据此立刻结束
  /// 等待，不必自己单方面等满 45s。"没人接"因此变成一条**明确的信令**，
  /// 而不是靠主叫猜（修 BUG-050 前 `RcEvt.callMissed` 是个**死常量**：
  /// 从不发出、无人消费）。
  ///
  /// 用回调注入而不是让 [CallService] 直接发：发送通道（[_send] + MQTT 客户端）
  /// 在端点手上，反向依赖会把通话模块与网络模块绑死。
  void _wireCall() {
    CallService.instance.onRingTimeout = (callId) async {
      await _send(RcMessage.now(RcEvt.callMissed, {'callId': callId}));
    };
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
    _activeScriptOwner = null;
    // 先终止协助会话（此刻 _client 仍在，才能发出 close 并退订会合主题）。
    await RcAssistHost.instance.close(reason: 'local', silent: true);
    await AssistJoinClient.instance.leave(silent: true);
    _client?.disconnect();
    _client = null;
  }

  /// 配对被撤销后的**在途作业清场**（P1，A3 §2「撤销」的另一半）。
  ///
  /// ## 为什么 `removePaired` 不够
  ///
  /// `RemoteStore.removePaired` 的注释写得很对：「只删列表**不足以**撤销授权」，
  /// 于是它把第二半交给了端点侧准入（`decideRcAdmission`）—— 但准入**只管
  /// 下一条命令**。撤销**之前**就已经在本机跑起来的作业，它一条也拦不住：
  ///
  /// - 一个 30 分钟的 `script.run`（可能正在播放声音 / 正在录音取证）会继续
  ///   跑到自然结束；
  /// - 一通 `call.invite` 视频通话会继续占着摄像头与麦克风。
  ///
  /// 而用户在「我的设备」里点「删除 / 取消配对」的语义是**立即断开**。
  /// 这就出现一个自相矛盾的现场：列表里已经没这台设备了，端点却还在执行
  /// 它下发的指令 —— 也正是"撤销后仍能造成影响"的形状。
  ///
  /// ## 行为
  ///
  /// 只清**该 deviceId 名下**的在途作业（其它已配对控制端的作业不受影响），
  /// 并且**如实写审计**。没有在途作业时什么都不做、也不写噪声日志。
  /// "该停哪一些"由纯判据 [decideRevokeCleanup] 决定（可穷举断言 / 可变异证伪），
  /// 这里只负责取当前状态 + 执行 + 记账。
  ///
  /// 幂等：可被重复调用（两处解除配对入口都会调）。
  Future<void> onPeerRevoked(String deviceId) async {
    if (deviceId.isEmpty) return;

    final plan = decideRevokeCleanup(
      revokedId: deviceId,
      scriptOwnerId: _activeScriptOwner,
      scriptRunning: RcScriptExecutor.instance.isRunning,
      callPeerId: CallService.instance.peerDeviceId,
      callActive: CallService.instance.inCall,
    );
    if (plan.isEmpty) return;

    if (plan.stopScript) {
      // `stop()` 同步落标志 + 立刻掐媒体（见 RcScriptExecutor 的三层停止），
      // 因此这里不需要 await 一个"正在停止"的中间态。
      RcScriptExecutor.instance.stop();
      _activeScriptOwner = null;
    }
    if (plan.hangUpCall) {
      // 通话的归属不另存状态：`CallService.peerDeviceId` 随通话收尾一并清空。
      // `_store` 在有通话时必然非空（服务已 start），但仍显式判空 ——
      // 这是 UI 按钮直接调用的路径，抛异常比"少挂一次"更糟。
      final store = _store;
      if (store != null) await CallService.instance.hangUp(store);
    }

    // `_db` 理论上必然非空（能停掉在途作业说明服务已 start），但这里是**UI 按钮
    // 直接调用的同步路径**：宁可少写一条审计，也不能让"删除设备"这个按钮抛异常。
    final db = _db;
    if (db == null) return;
    await LogRepository(db).append(
        source: 'remote',
        action: 'pair.revoke',
        status: 'success',
        message: '解除配对：已终止该设备的在途${plan.label}');
  }

  Future<void> _connect() async {
    final store = _store!;
    final deviceId = store.deviceId;
    if (deviceId.isEmpty) return;

    // ---- C-13（P0）：强制 TLS 8883，且**不**提供 onBadCertificate ----
    //
    // `mqtt_client` 在 `secure = true` 时走
    // `SecureSocket.connect(..., onBadCertificate: onBadCertificate)`；
    // 本工程**故意不传**该回调 —— Dart 在回调为 null 时对无效/自签证书
    // **直接握手失败**，这条路径天然是 fail-closed 的。若将来有人加一个
    // `=> true` 的回调来"图方便"，等于把中间人（篡改/丢弃信封）的后门
    // 装回来：`test/rc_transport_lock_test.dart` 会把 `onBadCertificate`
    // 的任何出现直接判红。
    //
    // 证书链校验用默认信任根（`SecurityContext.defaultContext`）。自建
    // broker 必须持有受信 CA 签发的证书（docs/14 §6）—— 不做指纹固定，
    // 也**不提供**"忽略证书"的开关。
    // Q2.B：端口取用户配置（`rc_broker_port`），未配置才回落 TLS 8883。
    // ⚠️ 端口**不是**"关 TLS"的开关：`secure = true` 仍然无条件、不可配置
    // （见上），自定义端口只是自建 broker 的监听端口不同。
    // 两处都写全 `?? RemoteStore.defaultBrokerPort`：端口的唯一真源仍是
    // `rcBrokerPort`（`test/rc_transport_lock_test.dart` TL-03/TL-12 锁着）。
    final client = _client = (debugClientFactory?.call(store.broker, deviceId,
                store.brokerPort ?? RemoteStore.defaultBrokerPort) ??
            MqttServerClient.withPort(store.broker, deviceId,
                store.brokerPort ?? RemoteStore.defaultBrokerPort))
          ..port = store.brokerPort ?? RemoteStore.defaultBrokerPort
          ..secure = true
          ..keepAlivePeriod = 30
          ..autoReconnect = true
          ..resubscribeOnAutoReconnect = true
          ..logging(on: false);
    // 连接建立（含自动重连）后：补订 + **冲刷离线暂存命令**。
    // 补发挂在"连接可用"这一刻，正是 UI 承诺的"端点上线后自动执行"。
    client.onConnected = () {
      unawaited(refreshSubscriptions());
      unawaited(flushAllOutbox(store));
    };

    final connectMsg = MqttConnectMessage()
        .withClientIdentifier(deviceId)
        .withWillTopic('sonicshield/v1/$deviceId/evt')
        .withWillMessage(
            jsonEncode({'type': RcEvt.offline, 'deviceId': deviceId}))
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();
    // ---- Q2.B：自建 broker 鉴权（可选）----
    //
    // `mqtt_client` 的凭据入口是 `MqttConnectMessage.authenticateAs(username,
    // password)`（已核对 pub 缓存 `mqtt_client-10.11.11` 源码：**没有**
    // `withCredentials` / `withUsername` / `withPassword` 这三个方法）。
    // 它按 `isNotEmpty` 置 `usernameFlag` / `passwordFlag`。
    //
    // ⚠️ **两者都非空**才调用：只填一个（例如有用户名无密码）不携带任何凭据
    // —— 半套凭据在 broker 侧通常直接拒连，且会让"未配置时默认行为逐字不变"
    // 这条承诺失效（未配置时不得改动 connect 报文）。
    final brokerUser = store.brokerUsername;
    final brokerPass = store.brokerPassword;
    if (brokerUser.isNotEmpty && brokerPass.isNotEmpty) {
      connectMsg.authenticateAs(brokerUser, brokerPass);
    }
    client.connectionMessage = connectMsg;

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
    // 首次连接走的是 connect() 而非 onConnected 回调（后者只在**重连**时触发），
    // 因此这里必须再补一次，否则"启动时就有暂存命令"的场景永远不补发。
    unawaited(flushAllOutbox(store));

    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 60), (t) {
      if (!_running ||
          _client?.connectionStatus?.state != MqttConnectionState.connected) {
        t.cancel();
        return;
      }
      // 心跳顺带补齐订阅：新增配对后无需重连即可收到对端回执（BUG-013）。
      unawaited(refreshSubscriptions());
      // 心跳顺带重试补发：`onConnected` 只在连接**状态跳变**时触发，
      // 而补发可能因为那一刻的瞬时失败（broker 限流等）没走完。
      unawaited(flushAllOutbox(store));
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

    // ---- Q1.B：命令主题的解密盐候选 ----
    //
    // 盐按**对端 deviceId** 存储（端点侧在 `_handlePairRequest` 里按控制端
    // deviceId 落盘），而命令主题 `{本机ID}/cmd` **不含发送方 ID** ——
    // 发送方身份要**解密之后**才可见，所以这里无法做单次精确查找。
    //
    // 于是把「null（未存盐的旧控制端，走 v1 无盐路径）+ 每个已配对控制端的
    // 存盐」作为候选逐一试解。AES-GCM 带认证，试错不会产生任何副作用
    // （decode 的 seenIds 只读、不写）。首项恒为 null ⇒ 全无存盐时与今天
    // **逐字节等价**（兼容铁律）。
    final salts = <List<int>?>[null];
    for (final p in store.paired()) {
      final s = _saltStore?.saltFor(p.deviceId);
      if (s != null) salts.add(s);
    }
    RcMessage? decoded;
    for (final salt in salts) {
      final key = await RcCodec.deriveKey(ownCode, '$ownId|cmd', salt: salt);
      decoded = await RcCodec.decode(wire, key, topic, seenIds: _seen);
      if (decoded != null) break;
    }
    final msg = decoded;
    if (msg == null) {
      // ⚠️ R-2：这里此前是**静默 return**。后果是配对码录错时两端都毫无提示 ——
      // 控制器等到超时，端点日志里**一条记录都没有**，用户完全分不清
      // "网络不通 / 端点离线 / 配对码错了"。
      // 限频（同主题 10s 一条）：错码命令会被 outbox 反复补发，
      // 不限频会把审计刷爆，反而淹掉真正需要被看见的那一条。
      await _auditDecodeFail(topic);
      return;
    }
    _rememberSeen(msg.id);
    // ---- 授权撤销兜底（P0，A3 §2「撤销」）----
    //
    // 旧准入**只有一条**：能用「本机配对码 + {本机ID}|cmd」解密成功。而配对码
    // 是全体控制端**共享**的、且没有轮换入口 —— 于是 `removePaired` 只把控制端
    // 移出本机列表，**拦不住它的任何命令**（`_peerOf` 查不到时还会构造占位对端
    // 继续 `_dispatch`）。这里补上第二条、也是真正在**执行之前**的判据：
    // 发送方必须**仍在**当前配对表里（判据见 decideRcAdmission）。
    final admission = decideRcAdmission(
      senderId: msg.from,
      type: msg.type,
      senderPaired: endpointById(store.paired(), msg.from) != null,
    );
    if (!admission.allowed) {
      // 拒绝必须**留痕**且**不得执行**：审计后直接 return，绝不落到 _dispatch。
      await _auditAdmissionReject(msg);
      return;
    }
    // ---- Q10：命令限流（判定在顶层纯函数 rateLimitFor，可穷举）----
    //
    // 「停」类命令（script.stop / vibrate.stop / call.end）**先于限流放行**：
    // 停止必须永远能插队 —— 窗口被刷满时连"叫停"都发不进来是安全底线问题。
    // 真实排队只发生在指令组步骤之间（执行器每步前查终止令牌，既有机制），
    // MQTT 命令本身到达即处理，故这里不做优先级队列，只做滑窗限流。
    if (!isStopCommand(msg.type)) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final verdict = rateLimitFor(
          msg.from, nowMs, _cmdTs[msg.from] ?? const <int>[]);
      if (!verdict.allowed) {
        await _auditRateLimited(msg, verdict.retryAfterMs);
        await _ack(msg, false, data: '限流');
        return;
      }
      _rememberCmdTs(msg.from, nowMs);
    }
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

    // ---- Q1.B：事件主题的解密盐候选 ----
    //
    // 发送方 deviceId 由主题给出（`{对端ID}/evt`），但**盐可能尚未落盘**：
    // 配对成功回执本身是**盐的引导报文**（发送方此刻还没有盐，故用 v1 发），
    // 也可能本机持有的是上一轮的旧盐（对端重装后重生成了盐）。因此同样以
    // [null, 该对端的存盐] 作候选试解：null 覆盖引导报文与旧端点，存盐覆盖
    // 本轮正常流量。首项恒为 null ⇒ 无存盐时与今天**逐字节等价**（v1）。
    RcMessage? decoded;
    for (final salt in <List<int>?>[null, _saltStore?.saltFor(peerId)]) {
      final key = await RcCodec.deriveKey(ownCode, '$ownId|evt', salt: salt);
      decoded = await RcCodec.decode(wire, key, topic, seenIds: _seen);
      if (decoded != null) break;
    }
    final msg = decoded;
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
      case RcCmd.pairRequest:
        await _handlePairRequest(msg, peer, logs);
      case RcCmd.ping:
        await _send(
            RcMessage.now(RcEvt.pong, {
              'device': _store!.deviceName,
              'at': DateTime.now().millisecondsSinceEpoch,
            }),
            targetPeerId: msg.from);
      case RcCmd.statusGet:
        final next = await occ.pendingWithin(
            DateTime.now(), DateTime.now().add(const Duration(days: 7)),
            limit: 1);
        await _send(
            RcMessage.now(RcEvt.status, {
              'engine': BackgroundServiceManager.instance.isRunning,
              'pendingCount': await occ.pendingCountAfter(DateTime.now()),
              'nextFireAt':
                  next.isEmpty ? null : next.first.fireAt.millisecondsSinceEpoch,
              'version': AppMeta.version,
            }),
            targetPeerId: msg.from);
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
        if (id == null || id.isEmpty) {
          // 缺 taskId 必须**显式失败**（对齐 taskDelete）：静默不回执会让
          // 控制器一直等到超时，而真实原因是"我发的命令少了参数"。
          await _ack(msg, false, data: '缺少 taskId');
          return;
        }
        // ---- D-7 残余面：动作级权限裁决 ----
        // 关闭任务（`enabled == false`）**永远放行**（关掉是更安全的一侧）；
        // 打开时才要求该任务动作所需的权限位齐备（判据见 [taskActionPermDeny]）。
        final toggleTask = await tasks.get(id);
        final toggleDeny =
            toggleTask == null ? null : _assistActionDeny(toggleTask, enabling: enabled);
        if (toggleDeny != null) {
          await logs.append(
              source: 'remote',
              action: 'task.toggle',
              status: 'skipped',
              taskId: id,
              message: 'by ${peer.name} · $toggleDeny');
          await _ack(msg, false, data: toggleDeny);
          return;
        }
        await tasks.setEnabled(id, enabled);
        await logs.append(
            source: 'remote',
            action: 'task.toggle',
            status: 'success',
            taskId: id,
            message: 'by ${peer.name}');
        await _ack(msg, true);
      case RcCmd.taskSkipNext:
        final id = msg.payload['taskId'] as String?;
        if (id == null || id.isEmpty) {
          await _ack(msg, false, data: '缺少 taskId');
          return;
        }
        final n = await occ.skipNextForTask(id);
        await logs.append(
            source: 'remote',
            action: 'task.skipNext',
            status: n > 0 ? 'success' : 'skipped',
            taskId: id,
            message: 'by ${peer.name}');
        await _ack(msg, n > 0, data: n > 0 ? null : '无可跳过的计划');
      case RcCmd.guardSet:
        await _setRemoteGuard(msg, peer, logs);
      case RcCmd.soundPlay:
        await _playRemote(msg, peer, logs);
      case RcCmd.vibrateStop:
        await _stopVibrate(msg, peer, logs);
      case RcCmd.logsRecent:
        final limit = (msg.payload['limit'] as num?)?.toInt() ?? 50;
        final rows = await logs.recent(limit: limit);
        await _send(
            RcMessage.now(RcEvt.logs, {
              'for': msg.id,
              'logs': [
                for (final r in rows)
                  {
                    't': r['created_at'],
                    'source': r['source'],
                    'action': r['action'],
                    'status': r['status'],
                  }
              ],
            }),
            targetPeerId: msg.from);
      case RcCmd.scriptRun:
        await _runScript(msg, peer, logs);
      case RcCmd.scriptStop:
        final sid = msg.payload['scriptId'] as String?;
        final matched = sid == null ||
            sid == '*' ||
            sid == RcScriptExecutor.instance.currentScriptId;
        if (matched) {
          RcScriptExecutor.instance.stop();
          await logs.append(
              source: 'remote',
              action: 'script.stop',
              status: 'success',
              message: 'by ${peer.name}');
          await _ack(msg, true);
        } else {
          // 不匹配时**不能回成功**：控制器会以为"已终止"，而端点上的指令组
          // 还在跑 —— 这正是"成功被误报"的同一形状。
          await logs.append(
              source: 'remote',
              action: 'script.stop',
              status: 'skipped',
              message: 'by ${peer.name} · 无匹配脚本（scriptId=$sid，'
                  '当前=${RcScriptExecutor.instance.currentScriptId ?? '无'}）');
          await _ack(msg, false, data: '无匹配脚本');
        }
      case RcCmd.pttVoice:
        await _playPtt(msg, peer, logs);
      case RcCmd.callInvite:
        await _handleCallInvite(msg, peer);
      case RcCmd.callAnswer:
        await CallService.instance.onAnswer(msg.payload);
      case RcCmd.callCandidate:
        await CallService.instance.onCandidate(msg.payload);
      case RcCmd.callEnd:
        await CallService.instance.onRemoteEnd(msg.payload);
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
      case RcCmd.deviceAlert:
        await _deviceAlert(msg, peer, logs);
      default:
        // ⚠️ 旧约定是"未知命令静默忽略"（docs/14）。但静默的代价是：控制器
        // 发了一条拼错的命令，端点**什么都不做也不回执**，控制器只能等到超时，
        // 完全分不清"没收到 / 不认识 / 执行失败"。默认拒绝 + 显式回执把三者
        // 区分开（docs/14 那一行已同步更新）。
        await logs.append(
            source: 'remote',
            action: msg.type,
            status: 'skipped',
            message: 'by ${peer.name} · 未知命令，未执行');
        await _ack(msg, false, data: '未知命令');
    }
  }

  // ==================== v2.0：配对双向化（R-2） ====================

  /// 控制端配对请求：把控制端登记进本机配对表，使配对**双向生效**。
  ///
  /// ## 为什么必须有这条命令
  ///
  /// 配对此前只有"本机落盘"这一半：A 扫了 B 的码 ⇒ A 的配对表里有 B，
  /// 而 **B 的配对表里没有 A**。于是 B 执行了 A 的命令，[_send] 却在
  /// `peers.isEmpty` 分支把回执直接丢弃 —— 表现就是"端点执行了却发不出回执"，
  /// 控制端只能等到超时。配对不是单向授权，是**双向信任**。
  ///
  /// ## 安全
  ///
  /// 1. **能解密即证明对方持有本机配对码**（密钥按接收方身份派生，见
  ///    [_handleRaw] 的密钥模型）—— 这就是准入条件，与"物理在场扫码"等价；
  /// 2. `msg.from` **不可信**（信封里由发送方自报），身份一律以 payload 为准，
  ///    两者不一致只留痕、不作鉴权依据；
  /// 3. **绝不覆盖已配对控制端的 secret**：同 deviceId 而配对码不符 ⇒ **拒绝**。
  ///    否则任一已配对控制器都能顶掉另一台的记录，从而**劫持**发给它的全部回执
  ///    （`RemoteStore.addPaired` 是同 deviceId 原位覆盖）；
  /// 4. **顺序不可交换**：`addPaired` 必须在回执**之前** —— 回执密钥取自
  ///    配对表，表里还没有这台控制端时 [_send] 会直接把回执丢掉。
  Future<void> _handlePairRequest(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final ctrlId = (msg.payload['deviceId'] as String?)?.trim() ?? '';
    final code = ((msg.payload['code'] as String?) ?? '').trim().toUpperCase();
    final name = (msg.payload['name'] as String?)?.trim() ?? '';
    // 长度即格式：deviceId 16 位、配对码 8 位（与 PairQrProtocol.parseUri 同口径）。
    if (ctrlId.length != 16 || code.length != 8) {
      await logs.append(
          source: 'remote',
          action: 'pair.request',
          status: 'failed',
          message: 'by ${peer.name} · 配对信息不完整'
              '（deviceId ${ctrlId.length} 位 / code ${code.length} 位）');
      await _ack(msg, false,
          data: '配对信息不完整：需要 deviceId(16 位) 与 code(8 位)');
      return;
    }

    final existing = endpointById(_store!.paired(), ctrlId);
    if (existing != null && existing.secret != code) {
      // 拒绝而不是覆盖 —— 覆盖等于把该控制端的回执密钥换掉，
      // 发件人从此可以**读走**本该只给它的回执（提权面）。
      await logs.append(
          source: 'remote',
          action: 'pair.request',
          status: 'failed',
          message: 'by ${peer.name} · 拒绝：$ctrlId 已配对但配对码不符'
              '（不得覆盖已配对秘密；若确为对端重装，请先在端点「远程中心」移除该配对）');
      await _ack(msg, false,
          data: '该设备已配对且配对码不符：如确为对端重装，请先在端点移除该配对');
      return;
    }

    await _store!.addPaired(PairedEndpoint(
      deviceId: ctrlId,
      name: name.isEmpty ? '控制器 ${ctrlId.substring(0, 6)}' : name,
      secret: code,
      pairedAt: DateTime.now(),
      // 重新配对不得抹掉本机给它起的备注名（备注是本机数据，与对端无关）。
      alias: existing?.alias,
    ));
    // 立刻补订它的 evt 主题：重连前也能收到它后续发出的事件（与 BUG-013 同类）。
    await refreshSubscriptions();
    // ---- Q1.B：每设备随机盐（首次配对生成、重复配对**复用已存盐**）----
    //
    // 绝不能每次重新生成：那会让控制端存下新盐、而本机（或对端）仍按旧盐
    // 派生 —— 双向密钥不一致，表现为**静默失联**（配对成功、之后所有命令与
    // 回执都解不开）。复用规则在 [_ensureSalt] 里（单一真源）。
    final salt = await _ensureSalt(ctrlId);
    await logs.append(
        source: 'remote',
        action: 'pair.request',
        status: 'success',
        message: 'by ${name.isEmpty ? ctrlId : name} · 已登记为已配对控制端'
            '${existing != null ? '（重新确认）' : ''}'
            '${msg.from.isNotEmpty && msg.from != ctrlId ? ' · ⚠ 信封 from=${msg.from} 与 payload 不符' : ''}');
    // ⚠️ 必须在 addPaired 之后（回执密钥取自配对表）。
    // 定向发给 `ctrlId` 而不是信封里的 `msg.from`：身份以 payload 为准。
    await _send(
      RcMessage.now(RcEvt.ack, {
        'ok': true,
        'for': msg.id,
        'forType': msg.type,
        'data': '已配对',
        if (salt != null) 'kdfsalt': base64Encode(salt),
      }),
      targetPeerId: ctrlId,
      // ⚠️ 这条回执是**盐的引导报文**：控制端此刻还没有盐，若用盐加密，
      // 它永远解不开 ⇒ 永远拿不到盐（先有鸡还是先有蛋）。因此显式走 v1。
      withSalt: false,
    );
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
    await _send(
        RcMessage.now(RcEvt.tasks, {
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
        }),
        // R-6：任务列表是**响应式回执**，只回发起方 ——
        // 否则同一端点的另一台控制器会收到"别人的任务清单"。
        targetPeerId: msg.from);
  }

  /// 单条任务完整定义。
  Future<void> _sendTask(RcMessage msg) async {
    final id = msg.payload['taskId'] as String?;
    final t = id == null ? null : await TaskRepository(_db!).get(id);
    if (t == null) {
      await _ack(msg, false, data: '任务不存在');
      return;
    }
    await _send(
        RcMessage.now(RcEvt.task, {
          'for': msg.id,
          'task': TaskWire.toWire(t),
        }),
        targetPeerId: msg.from);
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

    final prev = await tasks.get(task.id);
    final existed = prev != null;
    await tasks.upsert(task);
    final dropped = await occ.deletePendingForTask(task.id);
    final planned = await _rematerialize(task, occ);
    // 远程更新会**清掉**该任务在本机的夜间豁免（入站 `quietExempt` 一律被丢弃，
    // docs/20 §8.2 约束 1）。这是安全方向，但**不得静默** —— 用户会看到
    // "夜间提醒突然不响了"，必须有一条能对上的日志。
    final exemptCleared = (prev?.quietExempt ?? false) && !task.quietExempt;
    // 入站振动一律强制「遵循系统勿扰」（docs/20 §10.3 第 4 条）。
    // 对端若试图关掉它，必须留痕 —— 否则用户只会发现"怎么半夜还会震"。
    final dndForced = TaskWire.inboundDndDowngrade(j['action']);
    await logs.append(
        source: 'remote',
        action: 'task.upsert',
        status: 'success',
        taskId: task.id,
        message: 'by ${peer.name} · ${existed ? '更新' : '新建'}'
            '「${task.name}」· 清理 $dropped 条旧计划 · 新计划 $planned 条'
            '${exemptCleared ? ' · 夜间豁免已被本次远程更新清除' : ''}'
            '${dndForced ? ' · 对端请求关闭「遵循勿扰」已被拒绝（远程不得绕过本机护栏）' : ''}');
    await _send(
        RcMessage.now(RcEvt.task, {
          'for': msg.id,
          'task': TaskWire.toWire(task),
        }),
        targetPeerId: msg.from);
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

  /// 协助会话下的**任务动作级**裁决（D-7）；返回 null = 放行。
  ///
  /// 只在协助会话下裁决：**配对通道没有权限位**（配对 = 全权），无条件读协助
  /// 权限会把已配对设备的 `task.runNow` / `task.toggle` 整体拒掉。判据是
  /// [assistReplyZone]（`RcAssistHost._onBusiness` 用 `runZoned` 注入，Zone 随
  /// 异步链传播）—— 与 `runner` 的步骤级裁决同法。
  ///
  /// `required` 由任务动作定义递归推导（[TaskWire.requiredPermBitsForTaskAction]，
  /// 能吃 `composite` / `randomFrom` 嵌套），`granted` 取本机会话的权限位
  /// （[RcPermGate.hasPerm]）。决策本身在纯函数 [taskActionPermDeny] 里 ——
  /// 宿主可穷举断言的那一半。
  String? _assistActionDeny(Task task, {required bool enabling}) {
    if (Zone.current[assistReplyZone] != true) return null;
    final perms = RcAssistHost.instance.session?.perms ?? AssistPerms.none;
    return taskActionPermDeny(
      TaskWire.requiredPermBitsForTaskAction(task.action.toJson()),
      (bit) => RcPermGate.hasPerm(perms, bit),
      enabling: enabling,
    );
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
    // ---- D-7 残余面：动作级权限裁决（协助会话）----
    //
    // `task.runNow` 在命令级只映射到 `script` 位；只放行 `script` 位的协助方
    // 可对**既有** `recordEvidence` 任务触发录音，绕开
    // `RcPermGate.requiredStepPerm(record) == denyAll` 与 docs/22 §9 采集红线。
    // `task.upsert` 已在 `RcAssistHost._taskPayloadDeny` 拦住（第 34 轮 X1），
    // 但 `runNow` 只带 taskId，宿主层无从得知动作类型 —— 必须在**装配任务
    // 之后**、**执行之前**裁决（判据见顶层纯函数 [taskActionPermDeny]）。
    final deny = _assistActionDeny(task, enabling: true);
    if (deny != null) {
      await logs.append(
          source: 'remote',
          action: 'task.runNow',
          status: 'skipped',
          taskId: id,
          message: 'by ${peer.name} · $deny');
      await _ack(msg, false, data: deny);
      return; // 绝不能执行 —— 采集红线
    }
    final r = await BackgroundServiceManager.instance.runNow(id);
    await logs.append(
        source: 'remote',
        action: 'task.runNow',
        status: r.ok ? 'success' : 'failed',
        taskId: id,
        message: 'by ${peer.name} · ${r.message}');
    await _send(
        RcMessage.now(RcEvt.exec, {
          'for': msg.id,
          'taskId': id,
          'taskName': task.name,
          'ok': r.ok,
          'message': r.message,
          'fromName': _store!.deviceName,
        }),
        // R-6：执行通知是**响应式回执**，只回发起方。
        targetPeerId: msg.from);
    await _ack(msg, r.ok, data: r.message);
  }

  /// 端点音源库（供远程任务选音源）。
  Future<void> _sendAssets(RcMessage msg) async {
    final limit =
        ((msg.payload['limit'] as num?)?.toInt() ?? maxRemoteAssetList)
            .clamp(1, maxRemoteAssetList);
    final assets = await AssetRepository(_db!).listAll();
    await _send(
        RcMessage.now(RcEvt.assets, {
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
        }),
        targetPeerId: msg.from);
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
    await _send(
        RcMessage.now(RcEvt.presets, {
          'for': msg.id,
          'categories': sorted,
        }),
        targetPeerId: msg.from);
  }

  /// 按当前定义重新物化未来计划（幂等提交）。
  Future<int> _rematerialize(Task task, OccurrenceRepository occ) async {
    if (!task.enabled) return 0;
    if (task.triggerType == TriggerType.soundTriggered) return 0;
    // 夜间独立豁免主开关（v1.9）：**必须一并带上**。
    // 若这里退回 `const ScheduleEngine()`（主开关恒 false），
    // 则任何一次远程任务更新都会把该任务已豁免的夜间计划**静默清掉** ——
    // 表现为"远程改了下任务，夜间提醒就没了"，且没有任何提示。
    // 注意：豁免的**钥匙仍在本地**（主开关是本地设置、任务级字段入站被丢弃），
    // 这里只是不把本地已授权的状态弄丢。
    //
    // 免打扰窗口同理（BUG-070）：重物化必须与 `replan()` 用**同一个窗口**，
    // 否则"远程改一次任务"就会让该任务的免打扰判定与全局不一致。
    final prefs = await SharedPreferences.getInstance();
    final window = normalizeQuietWindow(
      prefs.getInt(PrefsKeys.quietStartHour),
      prefs.getInt(PrefsKeys.quietEndHour),
    );
    final allowExempt = prefs.getBool(PrefsKeys.quietExemptMaster) ?? false;
    final entries = ScheduleEngine(
      quietStartHour: window.start,
      quietEndHour: window.end,
      allowQuietExempt: allowExempt,
    ).materialize(task, DateTime.now());
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
          quietExempt: e.quietExempted,
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
    await _send(
        RcMessage.now(RcEvt.device, {
          'for': msg.id,
          'deviceName': _store!.deviceName,
          'batteryLevel': level,
          'charging': charging,
          'version': AppMeta.version,
          'pendingCount': await occ.pendingCountAfter(DateTime.now()),
          'nextFireAt':
              next.isEmpty ? null : next.first.fireAt.millisecondsSinceEpoch,
        }),
        targetPeerId: msg.from);
  }

  /// 守护定位回传（LOCATION 权限**显式授权**）。
  ///
  /// ## C-1（P0）：命令、UI、文档都在，但清单里**没有**声明定位权限
  ///
  /// 这是"看起来能用、实际恒失败"的典型形状：`Geolocator.getCurrentPosition`
  /// 会直接抛 `PermissionDeniedException`，而失败原因在端点上只留下一句笼统的
  /// "定位失败"，用户分不清是"没授权 / 系统定位关了 / 取不到位置"。
  ///
  /// 现在把"取一次位置"抽成 [acquireLocationOnce] —— 一个**不依赖任何插件实例**
  /// 的纯流程，于是它的每一条分支都能在宿主上被穷举断言（此前这段逻辑埋在
  /// 服务私有方法里，只能靠真机取证）。这里只剩"记账 + 回执"的胶水。
  ///
  /// `location` 是危险权限，必须由端点上的人在系统弹窗里点"允许"；
  /// 控制端能做的只是**请求**，不能替端点做决定（docs/08 隐蔽采集红线）。
  ///
  /// 回归锁：`test/rc_location_gate_test.dart`。
  Future<void> _sendLocation(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final probe = await acquireLocationOnce(
      permissionGate: locationPermissionGate,
      serviceEnabled: locationServiceEnabled,
      fix: locationFix,
    );

    final pos = probe.position;
    if (pos == null) {
      // Q4（A+C）：permissionDenied / serviceDisabled 追加**可执行**的前台引导。
      // 后台定位不做（政策红线 + FGS 类型位属后续决策），现状诚实失败。
      final guide =
          probe.failure == RcLocationFailure.permissionDenied ||
                  probe.failure == RcLocationFailure.serviceDisabled
              ? ' · 请点亮屏幕后在前台重试，并在系统设置中允许定位'
              : '';
      await logs.append(
          source: 'remote',
          action: 'location',
          status: 'failed',
          message: 'by ${peer.name} · ${probe.detail}$guide');
      await _send(
          RcMessage.now(RcEvt.location, {
            'for': msg.id,
            'lat': null,
            'lng': null,
            'error': true,
            // 此前失败回执只有 error:true，控制端看不到原因与下一步。
            'data': '${probe.detail}$guide',
          }),
          targetPeerId: msg.from);
      return;
    }

    await logs.append(
        source: 'remote',
        action: 'location',
        status: 'success',
        message: 'by ${peer.name} · ${pos.latitude},${pos.longitude}');
    await _send(
        RcMessage.now(RcEvt.location, {
          'for': msg.id,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'acc': pos.accuracy,
          'fromName': _store!.deviceName,
        }),
        // R-6：定位是**最敏感**的回执，绝不能广播给其它控制器。
        targetPeerId: msg.from);
  }

  // ---- 定位能力 seam（C-1）----
  //
  // 三个 seam 都是**为了宿主测试**能断言"权限被拒时不该调用 Geolocator"
  // 这类顺序性约束（`flutter test` 里没有平台插件，真调用只会抛
  // MissingPluginException，掩盖掉真正的分支逻辑）。生产路径用的就是默认实现，
  // 分支逻辑本身在 [acquireLocationOnce] 里（那里无需插件即可穷举）。

  /// 运行时定位权限申请。默认走 `permission_handler`。
  ///
  /// 被拒返回 false；**永久拒绝**同样返回 false 且**不再弹框**（系统已静默
  /// 拒绝，重复 request 只会立刻返回 denied，反而掩盖真实状态）。
  Future<bool> Function() locationPermissionGate = _systemLocationPermission;

  /// 系统定位服务是否开启。
  Future<bool> Function() locationServiceEnabled =
      Geolocator.isLocationServiceEnabled;

  /// 取一次当前位置（默认 medium 精度）。
  Future<Position> Function() locationFix = _systemLocationFix;

  static Future<bool> _systemLocationPermission() async {
    var p = await Permission.locationWhenInUse.status;
    if (p.isGranted) return true;
    if (p.isPermanentlyDenied) return false;
    p = await Permission.locationWhenInUse.request();
    return p.isGranted;
  }

  static Future<Position> _systemLocationFix() =>
      Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.medium));

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

  /// 远程 `device.alert`（Q9-B 找回动作）：屏幕点亮 + 最大音量提示 + 通知横幅。
  ///
  /// 回执**按原生真实结果**：`NativeBridge.alert` 返回 false（平台不支持 /
  /// 被拒 / 原生未实现）时如实 `ok=false`，不假成功 —— 与 `guard.set` 同一条
  /// 「按真实结果回执」的教训（成功误报比失败更贵）。
  Future<void> _deviceAlert(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final message =
        (msg.payload['message'] as String?)?.trim() ?? '这是本机的守护告警';
    final ok = await NativeBridge.alert(message: message);
    await logs.append(
        source: 'remote',
        action: RcCmd.deviceAlert,
        status: ok ? 'success' : 'failed',
        message: ok
            ? 'by ${peer.name} · 找回告警已展示'
            : 'by ${peer.name} · 原生未确认告警展示（平台不支持或被拒）');
    await _ack(msg, ok, data: ok ? null : '原生未确认告警展示');
  }

  /// 远程 `guard.set`：**按引擎的真实结果回执**。
  ///
  /// ⚠️ 旧实现只写 `prefs['guard_enabled']` 然后无条件 `ack(ok=true)`。
  /// 而该 pref **仅在引擎启动时读一次**（`background_engine` 里
  /// `var guardEnabled = prefs.getBool('guard_enabled')`），引擎正在运行时
  /// 下发这个 pref **守卫纹丝不动**，回执却是"成功" —— 对端以为守卫已开，
  /// 端点实际上什么都没变（成功被误报）。
  ///
  /// ⚠️ 本地正确路径（`guard_screen` → `toggleGuard`）还做了两件远程**做不到**
  /// 的事，必须在失败原因里明说，否则对端只会看到一句含糊的失败：
  /// 1. `Permission.microphone.request()` —— 权限弹窗只能在端点前台由使用者点；
  /// 2. `NativeBridge.startMicService()` —— 麦克风类型前台服务通行证。
  Future<void> _setRemoteGuard(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final enabled = msg.payload['enabled'] as bool? ?? false;
    final mgr = BackgroundServiceManager.instance;
    final engineRunning = mgr.isRunning;
    var observed = false;
    if (engineRunning) {
      // fire-and-forget 的 invoke：返回不代表生效，必须等状态回投。
      await mgr.setGuard(enabled);
      observed = await mgr.waitForGuardActive(enabled);
    }
    final outcome = decideGuardSet(
      enabled: enabled,
      engineRunning: engineRunning,
      observed: observed,
      guardError: mgr.guardError,
    );
    await logs.append(
        source: 'remote',
        action: 'guard.set',
        status: outcome.ok ? 'success' : 'failed',
        message: 'by ${peer.name} · ${outcome.reason}');
    await _ack(msg, outcome.ok, data: outcome.ok ? null : outcome.reason);
  }

  /// 被叫：收到 invite → 按 `calleeActionFor` 决定自动接通 / 振铃等用户 / 回占线。
  ///
  /// ⚠️ **BUG-056**：这里原先把 `onManualRing` 实现成**立刻 `acceptIncoming`**
  /// （注释写着"v1.4 简化"）—— 于是「自动接通」开关**关掉也照样接通**，
  /// 那个开关等于不存在。它不只是"功能没做完"，而是**隐私问题**：
  /// 该开关是使用者唯一能表达"别自动接我的电话"的地方（设置页文案：
  /// 仅限已配对设备呼入时自动接通，用于家人守护）。开关失灵意味着
  /// **来电被静默接通、摄像头/麦克风被打开**，而使用者以为自己已经关掉了。
  ///
  /// 现在这里只负责"通知有人打来"。接/拒由用户在界面上点击完成
  /// （`CallService.acceptPending` / `declinePending`），界面由
  /// `CallOverlayHost` 常驻监听 `CallService.phase` 弹出 —— **与当前在哪个路由无关**。
  Future<void> _handleCallInvite(RcMessage msg, PairedEndpoint peer) async {
    final video = msg.payload['video'] as bool? ?? true;
    final fromName = msg.payload['fromName'] as String? ?? peer.name;
    await NotificationService.instance.showEvent(
        title: '声盾 · 来电',
        body: incomingCallText(fromName: fromName, video: video));
    final ringing =
        await CallService.instance.onIncomingCall(msg.payload, peer, _store!);
    if (!ringing) return; // 占线已回 busy，不必再报 ringing
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
    await _ack(msg, r.ok, data: r.ok ? null : r.reason);
  }

  /// 远程 `vibrate.stop`：停止端点**全部**进行中的振动。
  ///
  /// ⚠️ 这里**刻意不回** "停了几项"：活跃振动表在**引擎隔离**里，主 isolate
  /// 读不到真实计数。回一个 `stopped=0` 是最糟的选择 —— 它看起来像成功，
  /// 而用户真正想确认的"按下去有没有用"完全没被回答（典型的静默降级）。
  /// 真实计数由引擎侧的 `vibrateStop` 监听写在审计里（它在隔离内，数字是准的）。
  Future<void> _stopVibrate(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    await BackgroundServiceManager.instance.stopVibrate(reason: '远程停止');
    await logs.append(
        source: 'remote',
        action: 'vibrate.stop',
        status: 'success',
        message: 'by ${peer.name} · 已请求停止全部进行中的振动'
            '（实际停止条数见引擎审计）');
    await _ack(msg, true);
  }

  Future<void> _runScript(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final script = RcScript.fromPayload(msg.payload);
    final err = RcScript.validate(script.steps);
    if (err != null) {
      await _ack(msg, false, data: err);
      return;
    }

    // ---- R-4①：**已有指令组在执行时必须先拒绝，再谈审计与回执** ----
    //
    // 旧顺序是「先写 success 审计 → 调 `RcScriptExecutor.run()`」，而 `run()`
    // 在已有执行时**直接返回 false**（一次一组）。于是第二条指令组被报成
    // `state:'stopped'` —— 控制端看到"被终止了"，实际是"**压根没开始**"，
    // 而且端点审计里还躺着一条 success。两处都在说谎。
    if (RcScriptExecutor.instance.isRunning) {
      final running = RcScriptExecutor.instance.currentScriptId ?? '未知';
      await logs.append(
          source: 'remote',
          action: 'script.run',
          status: 'skipped',
          message: 'by ${peer.name} · 拒绝：已有指令组在执行（$running）');
      await _ack(msg, false, data: '已有指令组在执行');
      return;
    }

    // 弹 heads-up：发送方/时间 + 立即执行（通知栏进度与终止按钮由执行器管理）。
    await NotificationService.instance.showEvent(
      title: '声盾 · 收到远程指令组',
      body: '来自 ${script.fromName} · ${_fmt(script.sentAt)}\n'
          '${script.name}（${script.steps.length} 步）—— 立即执行',
    );

    // 步序计数器：`runner` 的签名不带下标，而振动步的**波动种子**要能复现
    // （"同一次执行 → 同一条曲线"），必须有一个稳定且唯一的 occurrenceId 来源。
    // 执行器是顺序的，故一个自增计数器即可。
    var stepSeq = 0;

    /// R-4②：本次执行里**被跳过/没做成**的步骤。
    ///
    /// 权限拒绝、振动无处理器、录音无权限、播放无音源 —— 这些此前要么只有审计、
    /// 要么彻底静默。终态只回 `state:done` 时，"跑完 6 步"与"跑完 6 步但 3 步
    /// 什么都没做"在控制端**看起来一模一样**。累积到这里，随终态一并回传。
    final stepNotes = <String>[];

    Future<void> runner(RcStep step) async {
      final cancel = RcScriptExecutor.instance.activeCancel;
      final stepIndex = stepSeq++;
      // ---- 协助会话下的**步骤级**权限裁决（docs/18 §10）----
      //
      // 命令级门控（`RcPermGate.requiredPerm`）只把 `script.run` 映射到 `script`
      // 位 —— 若不做步骤级裁决，端点只放行 `script` 位、对端就能借 `script.run`
      // 完成**录音取证**（`denyAll`）、TTS 喊话、播放、振动，与设计承诺直接矛盾。
      //
      // ⚠️ 本 runner 同时服务**配对通道**（配对 = 全权，没有权限位）。判据用
      // [_send] 已在用的 `assistReplyZone`：只有协助会话的业务命令才会带着它
      // （`RcAssistHost._onBusiness` 用 `runZoned` 注入，Zone 随异步链传播）。
      if (Zone.current[assistReplyZone] == true) {
        final perms = RcAssistHost.instance.session?.perms ?? AssistPerms.none;
        final verdict = gateRcScriptStep(step.kind, perms: perms);
        if (!verdict.allowed) {
          stepNotes.add(
              '步骤 ${stepIndex + 1}（${step.kind.name}）被拒绝：${verdict.reason}');
          await logs.append(
              source: 'remote',
              action: 'script.run',
              status: 'skipped',
              message: '步骤 ${stepIndex + 1}（${step.kind.name}）被拒绝：${verdict.reason}');
          return;
        }
      }
      switch (step.kind) {
        case RcStepKind.delay:
          final sec = ((step.params['seconds'] as num?)?.toDouble() ?? 1)
              .clamp(0.5, 600);
          await (cancel?.sleep(Duration(milliseconds: (sec * 1000).round())) ??
              Future<void>.delayed(
                  Duration(milliseconds: (sec * 1000).round())));
        case RcStepKind.play:
          final category = step.params['presetCategory'] as String?;
          // R2①：终止已到 —— 不再解析音源、不起播（落到既有 skipped 记账分支，
          // 不做"既不执行也不记账"的静默跳过）。
          var aborted = cancel?.cancelled ?? false;
          var path = aborted ? null : await _resolvePreset(category);
          if (!aborted) {
            path ??= await _anyAssetPath();
            // R2②：解析 `await` 期间可能被终止 —— 起播前再检查一次，
            // 关闭"已终止却仍起播"的窗口。
            aborted = cancel?.cancelled ?? false;
          }
          final vol = ((step.params['volume'] as num?)?.toDouble() ?? 0.9)
              .clamp(0.0, 1.0)
              .toDouble();
          final dur =
              ((step.params['durationSec'] as num?)?.toInt() ?? 10) * 1000;
          if (path != null && playHandler != null && !aborted) {
            await playHandler!(path, vol, dur, loop: false);
          } else {
            // 对端要"播放"，端点什么都没放 —— 必须随终态回传（R-4②）。
            // `aborted`：终止已到，解析/起播都不做，但**同样记账为 skipped**。
            final why = aborted
                ? '指令组已终止'
                : path == null
                    ? (category == null || category.isEmpty
                        ? '端点音源库为空'
                        : '端点无「$category」分类的音源')
                    : '端点未装配播放能力';
            stepNotes.add('步骤 ${stepIndex + 1}（play）未执行：$why');
            await logs.append(
                source: 'remote',
                action: 'script.run',
                status: 'skipped',
                message: '步骤 ${stepIndex + 1}（play）未执行：$why');
          }
        case RcStepKind.tts:
          if (ttsHandler != null) {
            await ttsHandler!(step.params['text'] as String? ?? '',
                ((step.params['volume'] as num?)?.toDouble() ?? 0.8));
          } else {
            stepNotes.add('步骤 ${stepIndex + 1}（tts）未执行：端点未装配语音播报能力');
            await logs.append(
                source: 'remote',
                action: 'script.run',
                status: 'skipped',
                message: '步骤 ${stepIndex + 1}（tts）未执行：端点未装配语音播报能力');
          }
        case RcStepKind.notify:
          await NotificationService.instance.showEvent(
              title: step.params['title'] as String? ?? '声盾',
              body: step.params['body'] as String? ?? '');
        case RcStepKind.vibrate:
          await _runVibrateStep(step, script, stepIndex, logs, stepNotes);
        case RcStepKind.record:
          await _recordEvidence(
              seconds: (step.params['seconds'] as num?)?.toInt() ?? 30,
              stepIndex: stepIndex,
              stepNotes: stepNotes,
              cancel: cancel);
      }
    }

    await logs.append(
        source: 'remote',
        action: 'script.run',
        status: 'success',
        message:
            '${script.fromName} · ${script.name}（${script.steps.length} 步）');

    // 记录发起方：`onPeerRevoked` 靠它判断"这个在途指令组是不是被撤销那台发的"。
    // 必须在 `run()` **之前**落，否则存在一个窗口期 —— 指令组已在跑、owner 还是
    // null，此时解除配对会漏掉它（正是要修的那个形状）。
    _activeScriptOwner = peer.deviceId;
    final done = await RcScriptExecutor.instance.run(script, runner: runner,
        onStep: (i, s) {
      unawaited(_send(RcMessage.now(RcEvt.scriptState, {
        'scriptId': script.scriptId,
        'state': 'running',
        'stepIndex': i,
      })));
    });
    // 结束即清空（含"被终止"的情况）：留着一个已结束的 owner 会让下一次
    // 撤销误停到别人的作业上。
    _activeScriptOwner = null;
    unawaited(_send(
        RcMessage.now(
            RcEvt.scriptState, rcScriptStatePayload(script.scriptId,
                done: done, skipped: stepNotes))));
  }

  /// 执行指令组里的一个振动步骤（v1.9，docs/20 §10.1）。
  ///
  /// 两条路径**必须分开**，不允许"随机/持续不支持就退回固定节奏"：
  /// - `fixed`（含老控制器发的 `{}`）→ [vibrateHandler]，行为与 v1.8 一字不差；
  /// - `random` / `continuous` → [vibrateActionHandler] 转交引擎隔离。
  ///
  /// 后者未接线时写 `skipped` 审计并**什么都不做**。理由：对端要的是
  /// "持续振动 30 秒（强度 50–100%）"，端点震两下就结束是**承诺了没做到**，
  /// 而且用户看不出区别（FR-34 口径修正 / BUG-059 通则）。
  ///
  /// [stepNotes]（R-4②）：跳过的步骤要随终态一并回给控制端 ——
  /// 只写审计的话，控制端看到的仍是 `state:done`，与"真的震了"无法区分。
  Future<void> _runVibrateStep(RcStep step, RcScript script, int stepIndex,
      LogRepository logs, List<String> stepNotes) async {
    final mode = step.vibrateMode;
    final occurrenceId = 'rcscript:${script.scriptId}:$stepIndex';
    final route = routeRcVibrateStep(
      mode,
      hasLegacyHandler: vibrateHandler != null,
      hasActionHandler: vibrateActionHandler != null,
    );

    switch (route) {
      case RcVibrateRoute.legacyFixed:
        final cfg = step.vibrateConfig();
        final pattern =
            cfg is VibrateAction ? cfg.patternMs : const [0, 300, 200, 300];
        await vibrateHandler!(pattern);

      case RcVibrateRoute.actionHandler:
        final cfg = step.vibrateConfig();
        final r = await vibrateActionHandler!(
            action: cfg, occurrenceId: occurrenceId);
        if (!r.ok) {
          stepNotes.add('步骤 ${stepIndex + 1}（vibrate）未执行：${r.message}');
        }
        await logs.append(
            source: 'remote',
            action: 'script.run',
            status: r.ok ? 'success' : 'skipped',
            message: '${cfg.kind}（${mode.name}）· ${r.message} · $occurrenceId');

      case RcVibrateRoute.skip:
        // 关键分支：**随机/持续振动在缺少处理器时只能什么都不做**。
        // 退回固定节奏是静默降级（对端要 30 秒持续，端点震两下就完了）。
        final why = mode == RcVibrateMode.fixed
            ? '端点未注入振动处理器'
            : '端点未接线参数化振动（mode=${mode.name}）';
        stepNotes.add('步骤 ${stepIndex + 1}（vibrate）未执行：$why');
        await logs.append(
            source: 'remote',
            action: 'script.run',
            status: 'skipped',
            message: '振动步骤被跳过：$why，不退回固定节奏以免静默降级（$occurrenceId）');
    }
  }

  /// 录音取证。
  ///
  /// [stepNotes]（R-4③）：没录成的原因**不单独发 ack**，而是写进指令组终态的
  /// `skipped` 列表 —— 一条指令组只该有一个终态回执，让控制端去处理
  /// "回执有两种形状"只会把简单的事弄复杂。
  ///
  /// [cancel]（R1，docs/08 红线）：录音窗口必须能被终止令牌打断。此前这里是
  /// `await Future.delayed(seconds)` —— 令牌完全不参与，用户点了「终止执行」后
  /// **麦克风仍在录音、文件仍在写入**（未授权的隐蔽采集）。现在把等待交给可中断
  /// 的 [runRecordWindow]，并保证"停止"一定被请求、且停不掉时不报成功。
  Future<void> _recordEvidence({
    required int seconds,
    int stepIndex = 0,
    List<String>? stepNotes,
    RcCancel? cancel,
  }) async {
    final rec = AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        // 静默 return 是"录音取证没做成、却连一条日志都没有"的根因。
        // 协助会话下本步骤已被步骤级裁决拒掉；配对通道走到这里说明是**权限**
        // 问题（远程无法弹权限窗），必须留痕。
        stepNotes?.add(
            '步骤 ${stepIndex + 1}（record）未执行：麦克风权限未授予（需端点在前台授权）');
        await LogRepository(_db!).append(
            source: 'remote',
            action: 'record',
            status: 'failed',
            durationMs: seconds * 1000,
            message: '录音取证未执行：麦克风权限未授予（需端点在前台授权）');
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/evidence_rc_${DateTime.now().millisecondsSinceEpoch}.evidence.m4a';
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path);
      // R1：录音窗口可被终止令牌打断（见 [runRecordWindow] 的三种终态）。
      // `stop` 包一层 async 闭包：`rec.stop()` 的返回类型不保证是 `Future<void>`。
      final outcome = await runRecordWindow(
        Duration(seconds: seconds),
        cancel: cancel,
        stop: () async {
          await rec.stop();
        },
      );
      if (!outcome.stopConfirmed) {
        // 最严重的形状：请求了停止但没获确认，文件可能仍在写入。必须可见。
        stepNotes?.add('步骤 ${stepIndex + 1}（record）${outcome.message}');
        await LogRepository(_db!).append(
            source: 'remote',
            action: 'record',
            status: 'failed',
            durationMs: seconds * 1000,
            message: outcome.message);
      } else if (!outcome.ok) {
        // 收到终止且已停掉 —— 不算成功，沿用既有状态值 skipped。
        stepNotes?.add('步骤 ${stepIndex + 1}（record）${outcome.message}');
        await LogRepository(_db!).append(
            source: 'remote',
            action: 'record',
            status: 'skipped',
            durationMs: seconds * 1000,
            message: outcome.message);
      } else {
        await LogRepository(_db!).append(
            source: 'remote',
            action: 'record',
            status: 'success',
            durationMs: seconds * 1000,
            message: path);
      }
    } on Object catch (e) {
      stepNotes?.add('步骤 ${stepIndex + 1}（record）失败：$e');
      await LogRepository(_db!).append(
          source: 'remote',
          action: 'record',
          status: 'failed',
          durationMs: seconds * 1000,
          message: '录音取证失败：$e');
    }
  }

  /// 对讲机接收：解密信封内的 AAC 音频落盘并自动播放。
  ///
  /// ⚠️ 三条失败路径此前**全部静默**（缺 `audioB64` 直接 return、`on Object`
  /// 吞异常、`playHandler == null` 仍回成功）—— 对端松开对讲后**永远收不到
  /// `rc.ptt` 回执**，界面上只能看到"发送成功但对方没反应"，分不清是网络、
  /// 端点没装配播放能力，还是音频根本坏了。现在每条路径都回执 + 审计。
  Future<void> _playPtt(
      RcMessage msg, PairedEndpoint peer, LogRepository logs) async {
    final audioB64 = msg.payload['audioB64'] as String?;
    final from = msg.payload['fromName'] as String? ?? peer.name;
    if (audioB64 == null || audioB64.isEmpty) {
      await _pttFailed(msg, logs, from, '缺少 audioB64');
      return;
    }
    final play = playHandler;
    if (play == null) {
      await _pttFailed(msg, logs, from, '端点未装配播放能力');
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/ptt_${const Uuid().v4()}.m4a';
      await File(path).writeAsBytes(base64Decode(audioB64), flush: true);
      await NotificationService.instance
          .showEvent(title: '声盾 · 对讲', body: '来自 $from 的语音');
      final ok = await play(path, 1.0, 0);
      if (!ok) {
        await _pttFailed(msg, logs, from, '播放器未接受该音频');
        return;
      }
      await logs.append(
          source: 'remote',
          action: 'ptt.play',
          status: 'success',
          message: 'from $from');
      unawaited(_send(
          RcMessage.now(RcEvt.pttAck, {
            'voiceId': msg.payload['voiceId'],
            'ok': true,
          }),
          targetPeerId: msg.from));
    } on Object catch (e) {
      await _pttFailed(msg, logs, from, '$e');
    }
  }

  /// 对讲失败的统一出口：**审计 + `rc.ptt{ok:false, reason}`**。
  Future<void> _pttFailed(RcMessage msg, LogRepository logs, String from,
      String why) async {
    await logs.append(
        source: 'remote',
        action: 'ptt.play',
        status: 'failed',
        message: 'from $from · $why');
    unawaited(_send(
        RcMessage.now(RcEvt.pttAck, {
          'voiceId': msg.payload['voiceId'],
          'ok': false,
          'reason': why,
        }),
        targetPeerId: msg.from));
  }

  /// 通用回执：**定向**发回命令发起方（R-6，避免跨控制器泄露）。
  Future<void> _ack(RcMessage forMsg, bool ok, {Object? data}) async {
    await _send(
      RcMessage.now(RcEvt.ack, {
        'ok': ok,
        'for': forMsg.id,
        'forType': forMsg.type,
        if (data != null) 'data': data.toString(),
      }),
      targetPeerId: forMsg.from,
    );
  }

  /// 发送一条事件（端点 → 控制端）。
  ///
  /// [targetPeerId] **定向投递**（R-6）：非空时只发给该控制端。
  ///
  /// ## 为什么必须能定向
  ///
  /// 旧实现 `for (final peer in peers)` 把**同一条**事件逐个加密广播给
  /// **所有**已配对端点。A、B 两台控制器配对同一端点时，A 发 `task.list`
  /// ⇒ **B 也收到 A 的任务列表**；`rc.location`（实时定位）、`rc.logs`
  /// （端点审计）、`rc.exec`（执行通知）同理 —— 这是**跨控制器的隐私泄露**，
  /// 且完全静默（两端都"工作正常"）。
  ///
  /// 约定：**响应式回执**（`_ack` / tasks / task / assets / presets /
  /// device / location / logs / exec / ptt / pong / status）传
  /// `targetPeerId: msg.from`；**广播型事件**（`rc.heartbeat` / `rc.offline` /
  /// `rc.call` 状态 / `rc.script` 进度）保持 `null`（广播）。
  ///
  /// ⚠️ `targetPeerId` 为**空串**时退回广播：发送方没标识自己
  /// （`tool/rc_probe.dart` 探针即是 —— `RcMessage.now` 不填 `from`），
  /// 无法定向；此时**不能**丢弃，否则探针整体失联（它已在配对表里）。
  ///
  /// [withSalt]（Q1.B）：默认 `true` —— 按**对端 deviceId** 取每设备盐派生
  /// 消息密钥（无存盐 → null → v1 旧路径，逐字节不变）。**唯一**传 `false` 的
  /// 地方是配对成功回执：它是**盐的引导报文**，接收方此刻还没有盐，
  /// 用盐加密它会让接收方永远解不开（先有鸡还是先有蛋）。
  Future<void> _send(RcMessage msg, {String? targetPeerId, bool withSalt = true}) async {
    // 协助会话期间的回执必须**原路返回会合主题**：对端不是已配对设备，
    // 收不到 `{deviceId}/evt`，走下面那条路会静默丢弃（表现为"命令执行了
    // 但控制端毫无反应"）。通道由 Zone 承载，见 [assistReplyZone]。
    if (Zone.current[assistReplyZone] == true) {
      await RcAssistHost.instance.sendReply(msg);
      return;
    }

    final store = _store;
    final client = _client;
    if (store == null || client == null) {
      await _auditSendDrop(msg, '端点服务未启动');
      return;
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      await _auditSendDrop(msg, 'MQTT 未连接');
      return;
    }
    final paired = store.paired();
    if (paired.isEmpty) {
      await _auditSendDrop(msg, '无已配对端点');
      return;
    }
    final peers = resolveRcDelivery(paired, targetPeerId);
    if (peers == null) {
      // 点名了却找不到 ⇒ 显式留痕，绝不"退而求其次广播给所有人"
      // （那正是本函数要消灭的跨控制器泄露）。
      await _auditSendDrop(msg, '目标控制端不在配对表：$targetPeerId');
      return;
    }
    // `peers` 在此必非空：`paired` 非空时 resolveRcDelivery 只会返回它的
    // 子集或 null（见其契约），故不再多写一条不可达的兜底分支。
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
      // Q1.B：盐按**对端 deviceId** 存储；无存盐 → null → v1 旧路径。
      final salt = withSalt ? _saltStore?.saltFor(peer.deviceId) : null;
      final key = await RcCodec.deriveKey(
          peer.secret, '${peer.deviceId}|evt', salt: salt);
      final wire = await RcCodec.encode(out, key, topic);
      final builder = MqttClientPayloadBuilder()..addString(wire);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
          retain: false);
    }
  }

  /// 解密失败（`decode == null`）的**限频审计**（R-2）。
  ///
  /// 此前 `_handleRaw` 在这里**静默 return**：配对码录错时两端都毫无提示 ——
  /// 控制端等到超时，端点日志里一条记录都没有，用户完全分不清
  /// "网络不通 / 端点离线 / 配对码错了"。
  ///
  /// ⚠️ 只在**命令主题**（`{本机ID}/cmd`）上审计，**不**在 `{对端ID}/evt` 上：
  /// 广播型事件是"每个已配对端点各一份密文"发到同一个 evt 主题的，
  /// 端点侧解不开**别人**那一份是**正常现象**，在那里记会变成每 60s 一条的噪声。
  ///
  /// ⚠️ 必须限频：错码命令会被 outbox 反复补发，不限频会把审计刷爆，
  /// 反而淹掉真正需要被看见的那一条（同主题 10s 一条）。
  Future<void> _auditDecodeFail(String topic) async {
    final db = _db;
    if (db == null) return;
    if (!_decodeFail.allow(topic, DateTime.now().millisecondsSinceEpoch)) {
      return;
    }
    try {
      await LogRepository(db).append(
          source: 'remote',
          action: 'decode.fail',
          status: 'failed',
          message: '密钥不匹配（配对码可能录错）· 主题 $topic');
    } on Object {
      // 审计本身失败不再递归挣扎。
    }
  }

  /// 入站命令因**发送方已不在配对表**而被拒绝时的审计（P0 授权撤销）。
  ///
  /// 为什么**只审计、不回执**：回执要发到 `{发送方ID}/evt`，其密钥取自
  /// **本机配对表**（[_send] 的 `resolveRcDelivery` / `peer.secret`）。发送方
  /// 已不在表里 ⇒ 没有可用密钥 ⇒ 强行回执只会落进"目标控制端不在配对表"的
  /// 丢弃分支。因此这里把"谁在撤销配对后仍试图下发命令"如实写进端点审计，
  /// 由本地使用者从日志里看见（**绝不静默吞**）。
  ///
  /// 限频（同一发送方 10s 一条）：理由见 [_rejectFlood]。
  Future<void> _auditAdmissionReject(RcMessage msg) async {
    final db = _db;
    if (db == null) return;
    if (!_rejectFlood.allow(
        msg.from, DateTime.now().millisecondsSinceEpoch)) {
      return;
    }
    final who = msg.from.length > 6 ? msg.from.substring(0, 6) : msg.from;
    try {
      await LogRepository(db).append(
          source: 'remote',
          action: msg.type,
          status: 'rejected',
          message: '拒绝执行：发送方 $who 已不在配对表'
              '（配对已解除或从未配对）—— 授权已撤销');
    } on Object {
      // 审计本身失败不再递归挣扎。
    }
  }

  /// 记录一条被放行的命令时间戳（Q10 滑窗限流的内存侧，见 [_cmdTs]）。
  void _rememberCmdTs(String deviceId, int nowMs) {
    final list = _cmdTs.putIfAbsent(deviceId, () => <int>[])..add(nowMs);
    // 先裁出窗的，再按硬上限截断，保证表不无限增长。
    list.removeWhere((t) => t <= nowMs - rcRateLimitWindowMs);
    while (list.length > maxCmdTsPerEndpoint) {
      list.removeAt(0);
    }
  }

  /// 命令被限流时的审计（Q10）：`skipped` + 必含「限流」字样。
  Future<void> _auditRateLimited(RcMessage msg, int retryAfterMs) async {
    final db = _db;
    if (db == null) return;
    try {
      await LogRepository(db).append(
          source: 'remote',
          action: msg.type,
          status: 'skipped',
          message: 'by ${_peerName(msg.from)} · 限流：'
              '${rcRateLimitWindowMs ~/ 1000} 秒窗口内命令超过 '
              '$rcRateLimitMaxPerWindow 条，约 $retryAfterMs 毫秒后可重试');
    } on Object {
      // 审计本身失败不再递归挣扎。
    }
  }

  /// 出站消息被丢弃时的审计（**"回执丢失无痕"的根因之一**）。
  ///
  /// 此前 `_send` 在未连接 / 无配对端点时**静默 return**：命令确实执行了，
  /// 对端却永远收不到回执，而端点日志里**连一条记录都没有** —— 排查时毫无线索。
  ///
  /// ⚠️ 心跳（[RcEvt.heartbeat]）**刻意不记**：它是 60s 一次的纯存活信号，
  /// 无配对端点时每次都写一条会把审计刷成噪声（1440 条/天），
  /// 反而淹掉真正需要被看见的回执丢失。
  Future<void> _auditSendDrop(RcMessage msg, String why) async {
    if (msg.type == RcEvt.heartbeat) return;
    final db = _db;
    if (db == null) return;
    try {
      await LogRepository(db).append(
          source: 'remote',
          action: msg.type,
          status: 'skipped',
          message: '出站消息未发出：$why');
    } on Object {
      // 审计本身失败不再递归挣扎。
    }
  }

  /// 控制器侧发送：把消息按目标端点的密钥发到其 cmd 主题。
  /// 未连接（或端点离线）时自动入 outbox，端点上线后冲刷（v1.3）。
  ///
  /// [withSalt]（Q1.B）：默认 `true` —— 按**对端 deviceId** 取每设备盐派生
  /// （无存盐 → null → v1 旧路径）。**唯一**传 `false` 的是配对请求：它是
  /// **盐的引导报文**，此刻对端可能还没有盐（或持有上一轮的旧盐），必须走 v1
  /// 才能被解开。
  Future<bool> sendTo(PairedEndpoint endpoint, RcMessage msg, RemoteStore store,
      {bool enqueueOnFail = true, bool withSalt = true}) async {
    // 宿主替身（仅测试注入）：非空时直接给出"是否已投递"，不再碰客户端。
    final override = debugSendTo;
    if (override != null) return override(endpoint, msg, store, enqueueOnFail);
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
    final topic = 'sonicshield/v1/${endpoint.deviceId}/cmd';
    // Q1.B：盐按对端 deviceId 存储；无存盐 → null → v1 旧路径（逐字节不变）。
    final key = await RcCodec.deriveKey(
        endpoint.secret, '${endpoint.deviceId}|cmd',
        salt: withSalt ? _saltStore?.saltFor(endpoint.deviceId) : null);
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      if (enqueueOnFail) {
        // ⚠️ 暂存必须是**密文**，不能是明文 JSON。
        //
        // 旧实现存的是把 `out.toJson()` 直接序列化出来的**明文 JSON 串**，
        // 而补发走的是 `flushOutbox` → `prepareOutboxReplay` → `RcCodec.decode`
        // （**要密文**）。两边从来没对上过，后果有两条：
        // 1. **离线补发功能整条死掉**：每一条暂存命令都解不开，被当成
        //    "密钥已变更"丢弃 —— 而 UI 上写着"端点上线后自动执行"，
        //    审计还把人引向"密钥变了"这个错误结论（BUG-053 同族形状：
        //    "两半分别写、从未合拢"）。
        // 2. **机密性回退**：暂存内容是明文，躺在 SharedPreferences 里，
        //    与"端到端加密、broker 不可见内容"的承诺不符 ——
        //    拿得到设备的人不需要任何密钥就能读出被操控端下发的全部命令。
        //
        // 现在与在线路径用**同一段** topic/key/encode，保证存进去的就是
        // 补发时能解开的形态。
        final wireForLater = await RcCodec.encode(out, key, topic);
        await store.enqueue(wireForLater, endpoint.deviceId);
      }
      return false;
    }
    final wire = await RcCodec.encode(out, key, topic);
    final builder = MqttClientPayloadBuilder()..addString(wire);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: false);
    return true;
  }

  /// 控制端：发送配对请求并**等待对端确认**（R-2）。
  ///
  /// 控制端扫码/手输后只做了"本机落盘"这一半 —— 对端配对表里没有本机，
  /// 于是它**执行了却发不出回执**（`_send` 的 `peers.isEmpty` 分支直接丢弃）。
  /// 本方法补上另一半：把本机身份 + **本机配对码**发给对端。
  ///
  /// ⚠️ `code` 必须携带：对端回执的密钥是
  /// `deriveKey(本机配对码, '{本机ID}|evt')`（见 [_send]）。不发码，
  /// 对端就没有可用密钥，回执**永远发不出去** —— 这正是本缺陷的根因。
  ///
  /// ⚠️ `enqueueOnFail: false`：配对请求是**一次性的在线握手**，
  /// 暂存到 outbox 等对端上线再补发毫无意义（那时早已超时，且补发的
  /// 回执没人听）。失败要**当场告诉用户**。
  ///
  /// 返回的 [PairConfirmOutcome.message] 必须原样呈现给用户 ——
  /// 8 秒内没有回音是**明确结论**（"对方还没把你加进配对表"），
  /// 不是"再等等"，更不是静默。
  Future<PairConfirmOutcome> requestPairing(
    PairedEndpoint endpoint,
    RemoteStore store,
    RcMessage request, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // ⚠️ 配对请求是**盐的引导报文**（对端此刻可能还没有盐，或本机持有上一轮
    // 的旧盐）—— 必须走 v1，否则"对端重装后本机仍持旧盐"时配对请求根本解不开。
    final sent = await sendTo(endpoint, request, store,
        enqueueOnFail: false, withSalt: false);
    if (!sent) {
      return const PairConfirmOutcome(false,
          '已在本机配对；但未能通知对端（本机端点服务未开启或 MQTT 未连接）'
          '—— 请开启「远程遥控」开关后重试，或在对端也扫一次本机二维码');
    }
    final ack = await _awaitAck(request.id, timeout);
    if (ack == null) {
      return const PairConfirmOutcome(false,
          '对方尚未确认配对：请在对端也扫一次本机二维码（配对需双向）');
    }
    final ok = ack['ok'] == true;
    // ---- Q1.B：落盘对端随配对成功回执下发的每设备盐 ----
    //
    // 只在**配对成功**（`ok`）时落盘，且**原样**使用对端下发的盐：本机此后
    // 发给该端点的全部消息（`sendTo` / `flushOutbox`）都用它派生，对端则用
    // 同一份盐解密。缺字段 / 非法 Base64 一律**不动已有盐**（见 [_savePeerSalt]）。
    if (ok) await _savePeerSalt(endpoint.deviceId, ack['kdfsalt']);
    final data = ack['data']?.toString() ?? '';
    return PairConfirmOutcome(
        ok, ok ? '对端已确认配对' : (data.isEmpty ? '对端拒绝了配对请求' : data));
  }

  /// 等待 `for == [forId]` 的 `rc.ack`；超时返回 null。
  ///
  /// 直接听 [events]（已解密并广播的事件流）而不是再开一路 MQTT：
  /// 回执的解密、去重、时间窗校验都已由 `_handlePeerEvent` 完成。
  Future<Map<String, dynamic>?> _awaitAck(
      String forId, Duration timeout) async {
    final completer = Completer<Map<String, dynamic>?>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    Timer? timer;
    void finish(Map<String, dynamic>? v) {
      if (!completer.isCompleted) completer.complete(v);
    }

    sub = events.listen((m) {
      if (m['type'] != RcEvt.ack) return;
      final p = rcPayloadOf(m);
      if (p['for'] != forId) return;
      finish(p);
    });
    timer = Timer(timeout, () => finish(null));
    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      timer.cancel();
    }
  }

  /// 端点/连接恢复后冲刷该端点的暂存命令（按序重发）。
  ///
  /// ⚠️ 两条硬要求，缺一条"端点上线后自动执行"就是空话：
  /// 1. **只读 + 成功后删**：绝不使用 `drainOutbox`（取走即删）—— 补发中途
  ///    断线 / 密文损坏 / 进程被杀都会让命令**永久消失**，而 UI 上写着"会自动执行"。
  /// 2. **重盖时间戳与 ID**（[prepareOutboxReplay]）：原样重发会被接收端的
  ///    ±90s 时间窗与 ID 去重直接丢掉 —— 失败点只是从"没补发"挪到"补发了被丢"。
  ///
  /// 返回**实际交给 MQTT 客户端**的条数（无法重放的坏条目会被丢弃并计入审计，
  /// 否则它会永久卡住队列后面的每一条命令）。
  Future<int> flushOutbox(RemoteStore store, PairedEndpoint endpoint) async {
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      return 0;
    }
    final topic = 'sonicshield/v1/${endpoint.deviceId}/cmd';
    // Q1.B：与 [sendTo] 用**同一份盐**（同一 deviceId）—— 否则补发的密文与
    // 在线路径的密钥不一致，接收端一律解不开（补发功能整条失效）。
    final key = await RcCodec.deriveKey(
        endpoint.secret, '${endpoint.deviceId}|cmd',
        salt: _saltStore?.saltFor(endpoint.deviceId));
    var sent = 0;
    final done = <Map<String, dynamic>>[];
    for (final m in store.outboxFor(endpoint.deviceId)) {
      final wire = m['wire'] as String?;
      if (wire == null) {
        done.add(m); // 坏条目（缺 wire）：留着只会卡队列
        continue;
      }
      final reEnc = await prepareOutboxReplay(wire, key, topic);
      if (reEnc == null) {
        done.add(m); // 解不开 = 永远发不出，丢弃并留痕
        await _auditOutboxDrop(endpoint, '暂存命令无法解密（密钥已变更？）');
        continue;
      }
      final builder = MqttClientPayloadBuilder()..addString(reEnc);
      client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
          retain: false);
      done.add(m);
      sent++;
    }
    await store.removeOutbox(endpoint.deviceId, done);
    return sent;
  }

  /// 连接建立 / 心跳时冲刷**全部**已配对端点的暂存命令。
  ///
  /// 这是 `flushOutbox` 的**唯一生产调用点** —— 修 P0-3 前它零调用点，
  /// 于是 `sendTo` 里 `store.enqueue` 存下的命令**永远不会被补发**。
  Future<int> flushAllOutbox(RemoteStore store) async {
    var sent = 0;
    for (final p in store.paired()) {
      if (p.deviceId.isEmpty) continue;
      sent += await flushOutbox(store, p);
    }
    return sent;
  }

  /// 暂存命令被丢弃的审计（丢弃必须留痕，否则"命令没执行"无从追查）。
  Future<void> _auditOutboxDrop(PairedEndpoint endpoint, String why) async {
    final db = _db;
    if (db == null) return;
    try {
      await LogRepository(db).append(
          source: 'remote',
          action: 'outbox.drop',
          status: 'failed',
          message: '${endpoint.displayName} · $why');
    } on Object {
      // 审计失败不再递归挣扎。
    }
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

// ==================== 可测的纯裁决（端点服务内部逻辑的外提） ====================
//
// 下面几个函数从 [RcEndpointService] 的私有方法里抽出：它们的输入是
// 「已经读到的外部状态」，输出是「该怎么回执 / 该不该执行」——
// 与 MQTT、数据库、插件实例全都无关，因此可以在 host 单测里**穷举组合**
// 来锁死行为。端点服务的接线部分由 `test/endpoint_*_test.dart` 的
// 源码契约锁兜住（私有方法无法在宿主机实例化，这是本项目既有做法）。

/// 解析一条出站事件的**投递集合**（R-6，纯函数 → 可穷举断言）。
///
/// 返回：
/// - `null`：**无法投递**（点名了某控制端但它不在配对表）→ 调用方必须留痕并
///   放弃发送。**不得**退化成"广播给所有人" —— 那正是跨控制器泄露本身；
/// - 空列表：无已配对端点（由调用方按"无已配对端点"留痕）；
/// - 非空列表：实际要逐份加密的目标。`paired` 非空时必定非空（只会是它的子集）。
///
/// ⚠️ `targetPeerId` 为**空串**时按广播处理：发送方未标识自己
/// （`tool/rc_probe.dart` 探针不填 `from`），无法定向；丢弃会让探针整体失联。
/// `null`（调用方明确要求广播）与空串在此**同义**，这是有意为之。
List<PairedEndpoint>? resolveRcDelivery(
    List<PairedEndpoint> paired, String? targetPeerId) {
  if (paired.isEmpty) return const <PairedEndpoint>[];
  if (targetPeerId == null || targetPeerId.isEmpty) return paired;
  final only = endpointById(paired, targetPeerId);
  return only == null ? null : <PairedEndpoint>[only];
}

/// 入站配对遥控命令的**准入裁决**（纯函数 → 可在宿主机穷举断言）。
///
/// ## 为什么必须有它（P0：解除配对后授权未撤销）
///
/// 修复前，`/cmd` 的准入**只有一条**：「能用本机配对码 + `{本机ID}|cmd`
/// 解密成功」。而配对码是**全体已配对控制端共享**的、且**无轮换入口**
/// （`ensurePairingCode` 只在长度≠8 时生成一次）。于是 `removePaired(id)` 只把
/// 该控制端移出本机列表，**拦不住它的任何命令** —— 「配对移出了列表，但对方
/// 仍能控制本机」。更糟的是 `_peerOf` 在列表里查不到时还会**构造占位对端**
/// 继续 `_dispatch`，等于默认放行。
///
/// 现在补上真正在**执行之前**的判据：发送方必须**仍在**当前配对表里。
///
/// ## 判据（顺序即优先级）
///
/// 1. `pair.request` → [RcAdmission.allowPairing]：它正是"把控制端登记进本机
///    配对表"的握手；若连它也拒，解除配对后将**永远无法重新配对**（在配对码
///    无轮换入口的前提下，这是唯一恢复路径）。
/// 2. `senderId` 为空 → [RcAdmission.allowUnidentified]：无法识别发送方
///    （`tool/rc_probe.dart` 探针不填 `from`；旧控制端亦可能不填）。
/// 3. `senderPaired` 为真 → [RcAdmission.allowPaired]。
/// 4. 其余 → [RcAdmission.rejectUnpaired]：**点名了发送方却不在表里**
///    （从未配对，或**已被解除配对**）→ 拒绝（fail-closed）。
///
/// 判据**无状态**：同一输入恒得同一裁决（幂等），且判决某一发送方**不会**
/// 改变其它发送方的裁决 —— 故"解除配对一台"不影响其它已配对端点。
///
/// ## 已知缺口（诚实标注，不在本修复范围内）
///
/// `msg.from` 是信封里由发送方**自报**的字段（`protocol.dart` 的
/// `RcMessage.from` 注释「不参与鉴权」）。它**在密文之内**，故持有配对码者
/// 可写入任意值 —— 包括空串或某个**仍**在配对表里的 ID，从而绕过本判据。
/// 根治需**按设备独立密钥**（每人一码、可单独轮换），而那会改变
/// 「按接收方身份派生 + 双方互扫」这一**不可改决策**（HANDOVER §4.6）。
/// 本修复只做**准入判定层**加固：让"诚实但已被解除配对"的控制端**立刻
/// 失效**、且每次尝试留痕；伪造 `from` 的旁路需另案（密钥模型级）处理。
RcAdmission decideRcAdmission({
  required String senderId,
  required String type,
  required bool senderPaired,
}) {
  if (type == RcCmd.pairRequest) return RcAdmission.allowPairing;
  if (senderId.isEmpty) return RcAdmission.allowUnidentified;
  if (senderPaired) return RcAdmission.allowPaired;
  return RcAdmission.rejectUnpaired;
}

/// [decideRcAdmission] 的裁决结果（值即语义，供审计与测试断言）。
enum RcAdmission {
  /// 配对握手：无条件放行（登记控制端）。
  allowPairing,

  /// 发送方未标识自身：放行（已知缺口，见 [decideRcAdmission] 文档）。
  allowUnidentified,

  /// 发送方在当前配对表内：放行。
  allowPaired,

  /// 发送方已不在配对表（从未配对或**已被解除配对**）：**拒绝执行**。
  rejectUnpaired;

  /// 是否放行。**唯一**决定"要不要 `_dispatch`"的判据。
  bool get allowed => this != RcAdmission.rejectUnpaired;
}

/// 解密失败审计的**限频器**（R-2）：同一主题 [windowMs] 内只放行一条。
///
/// 抽成独立类是为了能在宿主机上直接断言"10s 内只写一条" ——
/// 端点服务本身依赖 MQTT/数据库/插件实例，宿主无法实例化。
class DecodeFailThrottle {
  DecodeFailThrottle({this.windowMs = 10000});

  final int windowMs;
  final Map<String, int> _lastAt = <String, int>{};

  /// 该主题此刻是否应当写审计；返回 true 时同时记下本次时刻。
  ///
  /// ⚠️ 用 `containsKey` 而不是 `?? 0` 判"没记过"：后者把"从未见过"与
  /// "见过（时刻为 0）"混为一谈 —— 依赖调用方传入的时间戳足够大才能正确工作，
  /// 而这种隐式前提正是单元测试里第一个被踩到的坑。
  bool allow(String topic, int nowMs) {
    final last = _lastAt[topic];
    if (last != null && nowMs - last < windowMs) return false;
    _lastAt[topic] = nowMs;
    return true;
  }
}

/// 指令组**终态**事件载荷（R-4，纯函数）。
///
/// `skipped` 列出**被跳过/未执行**的步骤（权限拒绝、振动无处理器、
/// 录音无权限、播放无音源…），随 `state` 一并回给控制端。
///
/// ⚠️ 为什么必须带上它：`state:done` 只说明"跑完了"，不说明"每一步都做了"。
/// 端点跳过 3 步与全部做完，在控制端**看起来完全一样** ——
/// 这正是"成功被误报"的同一形状。`skipped` 恒定存在（可为空列表），
/// 让消费端不必区分"字段缺失"与"没有跳过"。
Map<String, dynamic> rcScriptStatePayload(
  String scriptId, {
  required bool done,
  List<String> skipped = const <String>[],
}) =>
    {
      'scriptId': scriptId,
      'state': done ? 'done' : 'stopped',
      'skipped': skipped,
    };

/// 配对请求的结局（R-2，控制端 UI 据此提示，**绝不静默**）。
///
/// `message` 是**可直接展示**的中文结论：成功、对端明确拒绝、
/// 8 秒内没有回音、或本机根本没发出去 —— 四种情形对用户而言
/// 需要完全不同的下一步动作，合并成一句"配对失败"就是新的静默失败。
class PairConfirmOutcome {
  const PairConfirmOutcome(this.confirmed, this.message);

  final bool confirmed;
  final String message;
}

/// 远程 `guard.set` 的裁决结果。
class GuardSetOutcome {
  const GuardSetOutcome(this.ok, this.reason);

  final bool ok;

  /// 可直接回给对端的原因（成功时是一句确认语）。
  final String reason;
}

/// 由「引擎是否在跑 + 是否观察到期望状态」推导 `guard.set` 回执。
///
/// ⚠️ 三种失败必须给出**互不相同**的指引，合并成一句就是新的静默失败：
/// - 引擎没跑 → 远程**不能**替端点开引擎（那是端点的本地设置）；
/// - 引擎明确报了启动失败原因 → 多半是麦克风权限，而远程**无法弹权限窗**；
/// - 等不到回音 → 引擎无响应（卡住 / 被杀）。
GuardSetOutcome decideGuardSet({
  required bool enabled,
  required bool engineRunning,
  required bool observed,
  String? guardError,
}) {
  if (!engineRunning) {
    return GuardSetOutcome(
      false,
      enabled
          ? '后台引擎未运行：需端点在「守护」页开启引擎；开启守卫还需端点在前台授予麦克风权限'
          : '后台引擎未运行：需端点在「守护」页开启引擎',
    );
  }
  if (observed) {
    return GuardSetOutcome(true, enabled ? '守卫已开启' : '守卫已关闭');
  }
  final e = guardError;
  if (enabled && e != null && e.isNotEmpty) {
    return GuardSetOutcome(
        false, '守卫启动失败：$e（远程无法申请麦克风权限，需端点在前台授权）');
  }
  return const GuardSetOutcome(false, '引擎无响应：未能确认守卫状态');
}

/// 协助会话下**指令组步骤**的权限裁决。
class RcStepVerdict {
  const RcStepVerdict(this.allowed, this.reason);

  final bool allowed;
  final String reason;
}

/// 指令组步骤在当前协助权限下是否可执行。
///
/// ⚠️ **必须显式处理 `need == null`**：`RcPermGate.hasPerm(perms, null)` 会落到
/// `_ => false` 分支，把只读步骤（`delay` / `notify`）误判为拒绝 ——
/// 那样一个只有 `script` 位的对端连"等 5 秒"都做不到。
///
/// `record`（录音取证）返回 [RcPermGate.denyAll]：它不是任何权限位，
/// 因此**任何** [AssistPerms] 都放行不了它 —— 协助会话下一律拒绝（docs/18 §10）。
RcStepVerdict gateRcScriptStep(RcStepKind kind, {required AssistPerms perms}) {
  final need = RcPermGate.requiredStepPerm(kind);
  if (need == null) return const RcStepVerdict(true, '');
  if (RcPermGate.hasPerm(perms, need)) return const RcStepVerdict(true, '');
  return RcStepVerdict(
    false,
    need == RcPermGate.denyAll
        ? '该步骤类型在协助会话下一律拒绝（未登记权限位）'
        : '权限「${AssistPerms.labels[need] ?? need}」未放行',
  );
}

/// D-7 残余面：任务**动作级**权限裁决（纯函数 → 宿主可穷举断言）。
///
/// 返回 null = 放行；否则为**可直接回给对端**的拒绝原因。
///
/// ## 为什么必须有它
///
/// 命令级门控（[RcPermGate.requiredPerm]）只把 `task.runNow` / `task.toggle`
/// 映射到 `script` 位。若不在**动作层**再看一眼，只放行 `script` 位的协助方
/// 可对**既有** `recordEvidence` 任务触发录音（`task.runNow`）或把它打开
/// （`task.toggle{enabled:true}`），绕开
/// `RcPermGate.requiredStepPerm(record) == denyAll` 与 docs/22 §9 采集红线。
///
/// `task.upsert` 已在 `RcAssistHost._taskPayloadDeny` 于**载荷层**拦住（第 34
/// 轮 X1）；`task.runNow` 只带 `taskId`、`task.toggle` 只带 `taskId + enabled`，
/// 宿主层**无从得知**目标任务的动作类型 —— 必须在端点服务**装配任务之后**、
/// **执行之前**用本函数裁决（接线见 `_assistActionDeny` → `_runTaskNow` /
/// `taskToggle`）。
///
/// ## 关闭任务永远放行（铁律）
///
/// `enabling == false`（关任务）**无条件**放行：关掉是**更安全**的一侧。
/// 安全选项的失败路径**不得**降级到更不安全的一侧 —— 若因"缺权限"而拒绝
/// 关闭，等于把越权打开的任务锁死在使用者无法关闭的状态。
///
/// ## 判据非恒真
///
/// - `required` 为空（动作不需要额外权限位）→ 放行；
/// - `required` 有缺位 → 拒绝（[TaskWire.firstMissingPermBit]）。
String? taskActionPermDeny(
  Set<String> required,
  bool Function(String) granted, {
  required bool enabling,
}) {
  if (!enabling) return null;
  final missing = TaskWire.firstMissingPermBit(required, granted);
  if (missing == null) return null;
  return '任务动作需要权限「${AssistPerms.labels[missing] ?? missing}」，未放行';
}

/// 把 outbox 里的一条暂存线格式**重放就绪**：解密（**忽略时间窗**）→
/// 换新时间戳与新 ID → 重新加密。返回 null 表示该条目无法重放（密文损坏 /
/// 密钥不符）→ 调用方应丢弃它，否则它会**永久卡住整个队列**。
///
/// ⚠️ 为什么必须重盖时间戳与 ID：`RcCodec.decode` 有 ±90s 时间窗，且接收端
/// 按 ID 去重。一条两小时前入 outbox 的命令，若原样重发，接收端会**因为超窗
/// 而拒收**（或因为 ID 已见过而判重放）—— 那样"端点上线后自动执行"仍然是
/// 一句空话，只是失败点从"没人补发"挪到了"补发了但被丢"。
/// 重放是**此刻的发送行为**，信封就该是此刻的。
Future<String?> prepareOutboxReplay(
    String wire, List<int> key, String topic) async {
  // 窗口放到极大：这里要的是"把当年那条命令解出来"，不是"验证它还新"。
  final stale = await RcCodec.decode(wire, key, topic,
      maxSkewMs: const Duration(days: 3650).inMilliseconds);
  if (stale == null) return null;
  final fresh = RcMessage(
    id: RcMessage.now(stale.type).id,
    ts: DateTime.now().millisecondsSinceEpoch,
    type: stale.type,
    payload: stale.payload,
    from: stale.from,
  );
  return RcCodec.encode(fresh, key, topic);
}

// ══════════════════════════════════════════════════════════════════════
// 第三十四轮：C-1 / P1 的**顶层判据**
// ══════════════════════════════════════════════════════════════════════
//
// 项目通则：**判据与接线分离**。凡是"该不该做 / 该做哪一些"的决策，都抽成
// 不依赖插件实例的纯函数放在这里（同 `decideRcAdmission` / `gateRcScriptStep`），
// 于是宿主测试能穷举断言 + 变异证伪；服务方法里只留
// "取状态 → 调判据 → 执行 → 记账"。
//
// 这不是为了覆盖率好看：本轮两个改动（定位三步闸门、撤销清场）此前都会埋在
// 私有方法里、依赖 geolocator/DB/MQTT 实例，**只能靠真机取证**；抽出来之后
// 每一条分支都能在 `flutter test` 里被钉住。

/// 配对撤销时**该清掉哪些在途作业**的判据（P1）。
///
/// ## 为什么必须逐项归属，而不是"有在途就全停"
///
/// 一台设备可以同时被**多个**控制端配对。撤销其中一台时，若写成
/// "停掉所有在途作业"，就会**误伤**另一台仍在授权中的控制端 ——
/// 它下发的指令组会被莫名终止（使用者看到"没人点它，它自己停了"）。
/// 撤销必须是**逐发送方**、**无状态**的（与 `decideRcAdmission` 同一纪律）。
///
/// ⚠️ `scriptOwnerId` / `callPeerId` 为 null 时**一律不停**：
/// "不知道是谁在跑的" ≠ "就是它"。宁可漏停一次（下一轮命令会被准入拒掉），
/// 也不能误停另一个授权控制端的作业。
class RcRevokePlan {
  const RcRevokePlan({required this.stopScript, required this.hangUpCall});

  /// 终止在途指令组。
  final bool stopScript;

  /// 挂断在途通话。
  final bool hangUpCall;

  /// 无事可做 —— 调用方据此**不写**审计，避免把日志刷成噪声。
  bool get isEmpty => !stopScript && !hangUpCall;

  /// 审计文案里"停掉了什么"。
  String get label => [if (stopScript) '指令组', if (hangUpCall) '通话'].join('、');
}

/// 决定撤销 [revokedId] 时要清掉哪些在途作业。
RcRevokePlan decideRevokeCleanup({
  required String revokedId,
  required String? scriptOwnerId,
  required bool scriptRunning,
  required String? callPeerId,
  required bool callActive,
}) {
  final hit = revokedId.isNotEmpty;
  return RcRevokePlan(
    stopScript:
        hit && scriptRunning && scriptOwnerId != null && scriptOwnerId == revokedId,
    hangUpCall: hit && callActive && callPeerId != null && callPeerId == revokedId,
  );
}

/// 定位获取失败的原因（C-1）。
///
/// 三种原因的**用户指引互不相同** —— 合并成一句"定位失败"就是新的静默失败
/// （同 `guardSetVerdict` 的纪律）：
/// - 没授权 → 要去系统**弹窗/settings** 里允许定位；
/// - GPS 关着 → 要去系统设置里**打开定位服务**（此时权限可能已是 granted）；
/// - 都正常却取不到 → 无信号 / 超时 / 平台异常，重试或换个环境。
enum RcLocationFailure {
  /// 权限未授予（端点上没人点"允许"，或已被永久拒绝）。
  permissionDenied,

  /// 系统定位服务（GPS 总开关）关闭。
  serviceDisabled,

  /// 权限与服务都正常，但取位置本身失败（无信号 / 超时 / 平台异常）。
  fixFailed,
}

/// 一次定位探测的结果：要么带坐标，要么带**可展示的原因**。
class RcLocationProbe {
  const RcLocationProbe.ok(Position this.position)
      : failure = null,
        detail = '';

  const RcLocationProbe.failed(RcLocationFailure this.failure, this.detail)
      : position = null;

  final Position? position;
  final RcLocationFailure? failure;
  final String detail;

  bool get ok => position != null;
}

/// 「取一次位置」的三步闸门（C-1）。
///
/// 三步**都不做任何绕过**：
/// 1. 运行时权限（危险权限，必须端点上的人点"允许"）；
/// 2. 系统定位服务开关；
/// 3. 取一次位置。
///
/// **顺序是语义要求**：先权限、后服务。反过来的话，权限被拒时用户会先被
/// 引导去"打开 GPS"，打开了还是不行 —— 白折腾一轮，而且真正的原因
/// （没授权）反而被掩盖。
Future<RcLocationProbe> acquireLocationOnce({
  required Future<bool> Function() permissionGate,
  required Future<bool> Function() serviceEnabled,
  required Future<Position> Function() fix,
}) async {
  try {
    if (!await permissionGate()) {
      return const RcLocationProbe.failed(RcLocationFailure.permissionDenied,
          '定位权限未授予（需端点在系统弹窗中允许定位）');
    }
    if (!await serviceEnabled()) {
      return const RcLocationProbe.failed(RcLocationFailure.serviceDisabled,
          '系统定位服务已关闭（需端点在系统设置中开启定位）');
    }
    return RcLocationProbe.ok(await fix());
  } on Object catch (e) {
    return RcLocationProbe.failed(RcLocationFailure.fixFailed,
        '定位失败：$e（需端点授予定位权限并开启定位服务）');
  }
}

// ══════════════════════════════════════════════════════════════════════
// Q10：命令限流 + 停类优先（判据与接线分离，宿主可穷举断言）
// ══════════════════════════════════════════════════════════════════════

/// Q10 限流窗口默认长度（毫秒）：60s 窗。
const rcRateLimitWindowMs = 60 * 1000;

/// Q10 限流窗口内默认允许条数：30 条。
const rcRateLimitMaxPerWindow = 30;

/// 单端点时间戳内存表硬上限（防涨；出窗即裁后通常远小于此值）。
const maxCmdTsPerEndpoint = 200;

/// 滑窗限流的裁决结果（Q10）。
class RateLimitVerdict {
  const RateLimitVerdict.allow()
      : allowed = true,
        retryAfterMs = 0;
  const RateLimitVerdict.reject(this.retryAfterMs) : allowed = false;

  /// 是否放行本条命令。
  final bool allowed;

  /// 拒绝时建议等待的毫秒数（恒 > 0；放行时为 0）。
  final int retryAfterMs;
}

/// 滑动窗口限流判定（Q10，纯函数 → 可穷举断言）。
///
/// [recentTs] 是该发送方**已被放行**命令的时间戳（毫秒）。调用方在**放行前**
/// 调用本函数：窗口 `(nowMs - windowMs, nowMs]` 内已有 [maxPerWindow] 条
/// ⇒ 本条是第 max+1 条，拒绝；否则放行。默认 60s 窗 30 条。
///
/// 纯函数：不改 [recentTs]、不落库、不依赖实例状态。[deviceId] 只是桶标识
/// （判定本身只依赖时间戳），供调用方按端点分表使用。拒绝时给出
/// [RateLimitVerdict.retryAfterMs]（窗口内最早一条滑出窗口所需的时间），
/// 让控制端能提示"何时可重试"。被拒的命令**不记入** [recentTs]：
/// 否则每次拒绝都会把窗口往后推，形成"越拒越久"的惩罚螺旋。
RateLimitVerdict rateLimitFor(
  String deviceId,
  int nowMs,
  List<int> recentTs, {
  int windowMs = rcRateLimitWindowMs,
  int maxPerWindow = rcRateLimitMaxPerWindow,
}) {
  final cutoff = nowMs - windowMs;
  var oldest = -1;
  var count = 0;
  for (final t in recentTs) {
    if (t <= cutoff || t > nowMs) continue;
    count++;
    if (oldest < 0 || t < oldest) oldest = t;
  }
  if (count < maxPerWindow) return const RateLimitVerdict.allow();
  return RateLimitVerdict.reject(oldest + windowMs - nowMs);
}

/// 「停」类命令判定（Q10 停类优先，纯函数）。
///
/// `script.stop` / `vibrate.stop` / `call.end` 是安全底线：**永远**要在
/// 限流判定之前放行 —— 否则窗口被刷满时，连"叫停"都发不进来。
/// 真实排队只发生在指令组步骤之间（[RcScriptExecutor.run] 每步前检查终止
/// 令牌，既有机制，不再重造），MQTT 命令本身到达即处理，无需优先级队列。
bool isStopCommand(String type) =>
    type == RcCmd.scriptStop ||
    type == RcCmd.vibrateStop ||
    type == RcCmd.callEnd;

/// 取得（必要时生成并持久化）与 [deviceId] 关联的盐；未装配盐存储时返回 null。
///
/// ★ **复用优先**：该设备已有盐时必须**原样返回**，绝不重新生成 ——
/// 重复配对时重新生成会让控制端存下新盐、而本机（或对端）仍按旧盐派生，
/// 两端密钥不一致，表现为**静默失联**（配对成功，之后所有命令与回执都解不开）。
/// 这是本函数存在的唯一理由，也是 `test/salt_reuse_lock_test.dart` 锁住的东西。
///
/// ⚠️ **为什么是顶层函数**：`RcEndpointService` 是私有构造的单例
/// （`RcEndpointService._()`），宿主测试**无法实例化** ⇒ 逻辑内联在 `_ensureSalt`
/// 里就只能被**源码锁**覆盖，而源码锁锁不住语义（把"取已存盐"与"生成新盐"
/// 写反了照样能过）。抽到顶层后可传入真实/替身盐存储做**行为**断言。
///
/// 边界（刻意收窄）：存储未装配、或 [deviceId] 为空 ⇒ 返回 null。调用方**必须**
/// 据此回落到**无盐的 v1 派生路径**，绝不能传零盐/默认盐等替代品 ——
/// 那会让已配对设备在升级后**静默失联**。
Future<List<int>?> ensureSaltForDevice(
    KdfSaltStore? store, String deviceId) async {
  if (store == null || deviceId.isEmpty) return null;
  final salt = store.saltFor(deviceId) ?? KdfSaltStore.newSalt();
  await store.saveSalt(deviceId, salt);
  return salt;
}
