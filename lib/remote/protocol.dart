import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// 声盾远程遥控协议 v1（docs/14）。
///
/// 传输：MQTT over **TLS 8883**（证书链强校验，不提供忽略证书的回调；
/// 见 `RcEndpointService._connect` 与 `RemoteStore.defaultBrokerPort`）。
/// 主题命名空间 `sonicshield/v1/{deviceId}/cmd|evt`。
/// 安全：配对秘密 → HKDF-SHA256 → AES-256-GCM 端到端加密；
/// 代理（MQTT broker）只见密文。AAD 绑定主题与设备 ID 防跨主题重放。
///
/// 消息信封（明文结构，加密后传输）：
/// {v:1, id, ts, type, payload}
///  - ts 单调毫秒；接收端拒绝 |now-ts| > 90s（防重放窗口）
///  - id 每消息随机，接收端缓存去重（防窗口内重放）
/// 远程遥控 broker 端口：**TLS 8883**（C-13 P0）。
///
/// ## 为什么这个常量放在本文件，而不是 `remote_store.dart`
///
/// `protocol.dart` **不依赖 Flutter**（只 import `dart:*` 与 `cryptography`）；
/// 而 `tool/rc_probe.dart`、`tool/rc_e2e_controller.dart` 是**纯 Dart 命令行
/// 工具**（`dart run tool/...`）。它们若去 import `remote_store.dart`，就会把
/// `shared_preferences`（→ Flutter）拖进依赖树，在 `dart run` 下直接编译不过。
/// 端到端工具是"修完还能验证"的前提，因此真源必须落在无 Flutter 依赖的一侧。
///
/// ⚠️ **明文 1883 已被封禁**：`lib/` + `tool/` + `integration_test/` 全量扫描
/// （剥注释后）不得再出现该端口，且每个 MQTT 构造点都必须 `secure = true` ——
/// 见 `test/rc_transport_lock_test.dart`。
const int rcBrokerPort = 8883;

class RcMessage {
  const RcMessage({
    required this.id,
    required this.ts,
    required this.type,
    this.payload = const {},
    this.from = '',
  });

  final String id;
  final int ts;
  final String type;
  final Map<String, dynamic> payload;
  final String from; // 发送方 deviceId（调试/展示用，不参与鉴权）

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'ts': ts,
        'type': type,
        'payload': payload,
        'from': from
      };

  /// 解析信封；**空/缺失 ID 一律 fail closed 返回 null**（P2-26）。
  ///
  /// ## 为什么空 ID 必须被协议入口拒绝
  ///
  /// 旧实现把缺失 ID 静默解析成 `''`，而去重链（[RcCodec.decode] 的
  /// `msg.id.isNotEmpty &&` 与 `reserveInboundId` 的空串早返回）对空 ID
  /// **不查重、不预占**。正常发送器（[RcMessage.now]）恒生成 12 位随机 ID，
  /// 所以这只会命中 malformed / 旧客户端报文 —— 但 QoS1 的**重投**会把同一条
  /// 空 ID 报文重复投来，而每次都会重新执行播放 / 立即运行 / 指令组等
  /// **非幂等副作用**（"去重表形同虚设"）。
  ///
  /// 因此判据收在唯一的解密入口：拿不到可用去重键，就**当作解不开**丢弃，
  /// 而不是放进业务链路。对应回归锁：`test/remote_crypto_test.dart` 的
  /// "空 ID fail closed" 组。
  static RcMessage? tryParse(Map<String, dynamic> j) {
    if (j['v'] != 1 || j['type'] is! String) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return RcMessage(
      id: id,
      ts: (j['ts'] as num?)?.toInt() ?? 0,
      type: j['type'] as String,
      payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      from: j['from'] as String? ?? '',
    );
  }

  static RcMessage now(String type,
          [Map<String, dynamic> payload = const {}]) =>
      RcMessage(
        id: _randomId(),
        ts: DateTime.now().millisecondsSinceEpoch,
        type: type,
        payload: payload,
      );

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

/// 从事件信封中取出 `payload`。
///
/// [RcEndpointService.events] 广播的是 `msg.toJson()` 展开后的信封
/// （`{v, id, ts, type, payload, from, peerId, peerName}`），端点回执的
/// 业务字段全部在 **`payload` 之内**。UI 侧曾直接读顶层字段
/// （如 `m['pendingCount']`）→ 恒为 null，回执面板永远显示空值（BUG-023）。
/// 统一走本函数取值。
Map<String, dynamic> rcPayloadOf(Map<String, dynamic> envelope) {
  final p = envelope['payload'];
  return p is Map ? p.cast<String, dynamic>() : const {};
}

// ---------------- 命令类型（控制器 → 端点） ----------------

abstract final class RcCmd {
  /// 配对**双向化**（v2.0，R-2）：控制端扫码/手输成功后，主动把**自己**登记到
  /// 端点侧，使配对成为"双向"而非"单方落盘"。
  ///
  /// payload（**必须携带这三项**）：
  /// `{deviceId: 控制端 16 位 ID, name: 控制端显示名, code: 控制端 8 位配对码}`
  ///
  /// ⚠️ **`code` 不是可选装饰**：端点回执的密钥是
  /// `deriveKey(控制端配对码, '{控制端ID}|evt')`（见 `endpoint_service._send`）。
  /// 不携带它，端点就没有可用密钥 → 回执永远发不出去 → 控制端只能等到超时。
  /// 这正是"端点执行了却毫无回音"的根因。
  ///
  /// 安全边界（`msg.from` 不可信，一切以 payload 为准）：
  /// - **能解密即证明对方持有本机配对码**（密钥按接收方身份派生，见类文档），
  ///   因此本命令不需要额外的口令校验；
  /// - 但**绝不允许覆盖已配对控制端的 secret** —— 同 deviceId 且配对码不符
  ///   必须**拒绝**，否则任一已配对控制器都能顶掉另一台的配对记录，
  ///   从而**劫持**发给它的全部回执（提权面）；
  /// - 协助会话下**一律拒绝**：`RcPermGate.requiredPerm` 未登记 → `denyAll`
  ///   （协助对端**未配对**，不得借它把自己变成已配对设备）。
  ///
  /// 回执：`rc.ack {ok, for, data}`。
  static const pairRequest = 'pair.request';

  // ⚠️ 回执载荷以**端点实现**为准（`RcEndpointService` 的对应 case）；
  // 这里的注释曾长期与实现不符（C-9 文档漂移），已按实测改正。
  static const ping = 'ping'; // → rc.pong {device, at}
  static const statusGet =
      'status.get'; // → rc.status {engine, pendingCount, nextFireAt, version}
  static const soundPlay =
      'sound.play'; // {preset|assetId|category, volume, durationSec, loop}
  static const taskList = 'task.list'; // → tasks [...]
  static const taskToggle = 'task.toggle'; // {taskId, enabled}
  static const taskSkipNext = 'task.skipNext'; // {taskId}
  static const guardSet = 'guard.set'; // {enabled}
  static const logsRecent = 'logs.recent'; // {limit}

  /// 指令组（宏）：端点收到后【立即执行】。
  /// payload: {scriptId, name, fromName, sentAt, steps: [...]}
  /// steps 元素：{kind: play|tts|notify|vibrate|record|delay, ...参数}
  static const scriptRun = 'script.run';

  /// 终止当前指令组执行（携带 scriptId；'*' 表示终止任意当前执行）。
  static const scriptStop = 'script.stop';

  /// 对讲机（v2 流式：边录边发，参考 Zello；v1 整段模式向后兼容）：
  /// - v2 分片：ptt.voice {voiceId, seq(0..N-1), last(bool), fromName,
  ///   audioB64(ADTS aac 分片，端到端加密信封内) | 省略表示该片无音频}
  ///   首片 `seq=0` 即让端点**边收边放**；末片 `last=true` 收尾（可无音频，
  ///   仅作终止信号 —— 取消/停录时也补发一帧 `last=true` 让端点收尾）。
  /// - v1 整段：ptt.voice {voiceId, durationMs, audioB64}（无 `seq` 字段）。
  /// 端点判据：payload 含 `seq` **且**已装配流式开缝 ⇒ 走 v2；否则回落 v1。
  static const pttVoice = 'ptt.voice';

  /// 视频通话（v1.4，WebRTC + MQTT 信令，docs/16）：
  /// call.invite {callId, video} → 被叫自动接通（可配置）
  /// call.answer {callId, sdp} / call.candidate {callId, candidate} / call.end {callId}
  static const callInvite = 'call.invite';
  static const callAnswer = 'call.answer';
  static const callCandidate = 'call.candidate';
  static const callEnd = 'call.end';

  /// 设备完全控制（v1.6，仅限已配对设备，docs/16 §9）：
  /// device.status → rc.device {for, deviceName, batteryLevel, charging,
  ///                             version, pendingCount, nextFireAt}；
  /// camera.snap   → **恒** rc.ack{ok:false}（插件不兼容，v1.6 降级，
  ///                  **不产生** rc.photo，docs/16 §9 注记 / docs/22 §3 C-5）；
  /// location.get  → rc.location {for, lat, lng, acc}｜失败时
  ///                  {for, lat:null, lng:null, error:true}（C-1）；
  /// volume.set    → rc.ack
  static const deviceStatus = 'device.status';
  static const cameraSnap = 'camera.snap';
  static const locationGet = 'location.get';
  static const volumeSet = 'volume.set';

  /// `device.alert` → rc.ack。找回场景（Q9-B）：屏幕点亮 + 最大音量提示 + 通知横幅。
  /// payload：`message?`（锁屏提示文案，缺省用端点名）。需端点前台服务在跑；
  /// 原生未实现/被拒时如实 `ok=false`（不假成功）。
  static const deviceAlert = 'device.alert';

  /// 本机改名广播（FR-77，第八十四轮用户明文）：控制端改了**自己的**名字后，
  /// 主动把新名字推给**所有已绑定端点**，让它们在「我的设备」列表里同步更新。
  ///
  /// payload：`{name}`（控制端新显示名，非空，≤ 32 字符）。
  ///
  /// 语义与边界：
  /// - **只广播本机名，不广播别名**：别名是控制端的**私有视角**（只在本机显示），
  ///   绝不外泄（用户明文「别名只在本机显示」）；
  /// - 端点收到后**更新该控制端在自己的配对表里的 `name`**（真名来源），
  ///   下次 `rc.pong` / `rc.status` 回执里带的 `device`/`fromName` 即为新名；
  /// - 端点侧**不得**修改控制端的别名（端点侧根本没有别名概念）——
  ///   别名只存在于发起改名的控制端本地。
  ///
  /// 回执：`rc.ack {ok, for}`。
  static const deviceRename = 'device.rename';

  // ---- v1.7：远程任务 CRUD（与本机「自动化 → 任务」完整对齐，docs/14 §2.1）----

  /// 取单条任务完整定义：{taskId} → rc.task {task}
  static const taskGet = 'task.get';

  /// 新建/更新任务（按 id 幂等）：{task} → rc.ack
  /// 成功后端点**重新物化 occurrence**（否则新任务永不到期）。
  static const taskUpsert = 'task.upsert';

  /// 删除任务及其待执行计划：{taskId} → rc.ack
  static const taskDelete = 'task.delete';

  /// 立即执行任务动作（不等待计划时刻）：{taskId} → rc.ack + rc.exec
  static const taskRunNow = 'task.runNow';

  /// 端点音源库：{limit?} → rc.assets {assets}
  static const assetList = 'asset.list';

  /// 端点预置音源分类：{} → rc.presets {categories}
  static const presetList = 'preset.list';

  // ---- v1.9：振动（docs/20 §11.2）----

  /// 停止端点**全部**进行中的振动：{} → rc.ack {stopped}
  ///
  /// 与 D1「持续振动不设时长硬上限」配套：上限换来的是**任何时刻都能停**，
  /// 本地有「停止振动」按钮，远程有本命令。它是让"不设上限"站得住的那半边。
  /// ⚠️ 不携带 taskId：停止是全局的，避免"停错了对象"这类静默失效。
  static const vibrateStop = 'vibrate.stop';

  /// 远程**发起**振动（v2.x）：{} → rc.ack {ok, data?}
  ///
  /// payload：`{mode: fixed|random|continuous, ...参数}`
  /// - `fixed`（缺省）：**固定强度 + 固定时长** ——
  ///   `{durationSec: 1..maxDurationSec, intensity: 0..1}`
  /// - `random`：**随机强度 + 随机时长**的脉冲串 ——
  ///   `{durationSecMin/Max, amplitudeMin/Max, gapMsMin/Max?, pulseMsMin/Max?}`
  /// - `continuous`：区间浮动的持续振动 —— 与 `random` 同参数字段。
  ///
  /// ⚠️ 与指令组里的 `fixed` 步**语义刻意不同**（那里是固定"节奏"，
  /// 这里是固定"强度+时长"）—— 远程按钮要的是"震 5 秒、强度 60%"。
  /// 参数经 `rcVibrateStartConfig` **先夹紧再构造**，强制 `respectDnd=true`；
  /// 端点未接线参数化振动时**如实 `ok=false`**，不退回固定节奏（不静默降级）。
  /// 与 [vibrateStop] 是一对：停止是全局兜底，本命令是主动"震"。
  static const vibrateStart = 'vibrate.start';

  // ---- v2.0：随机反击计划（JSON 计划的下发 / 查询 / 下线，docs/14 §2.2）----

  /// 下发并应用一份反击计划：{plan: <CounterPlan JSON>, planId?, replace?}
  /// → rc.ack {ok, data: 'tasks=<n>;replan=...'}。
  ///
  /// 计划结构见 `CounterPlan`（固定 schema `sonicshield.counterPlan/1`）；
  /// 端点侧走**同一** `CounterPlanService.apply` 通路（校验 → 物化 → 落库），
  /// 任务落在 `counter:{planId}:` 命名空间内，与手动任务完全隔离。
  /// `replace` 缺省 true（整族替换）；`planId` 缺省沿用端点已有 id。
  static const planApply = 'plan.apply';

  /// 查询端点当前反击计划：{} → rc.plan {plan, enabled, planId, taskCount}。
  static const planGet = 'plan.get';

  /// 下线端点反击计划（清空计划任务 + 置未启用）：{} → rc.ack {stopped}。
  static const planStop = 'plan.stop';

  // ---- v1.9：全局执行总开关（docs/20 §9）----

  /// 设置端点「全局执行总开关」：`{mode: 'auto'|'on'|'off'}` → rc.ack {mode}。
  ///
  /// 语义（真源 `RunPause`）：
  /// - `auto`（默认）= 法定休息日自动暂停：`[休息日前一天 20:00, 连续休息日
  ///   最后一天 21:00)` 窗口内所有任务默认跳过；
  /// - `on`  = 强制开启（忽略自动窗口，永不暂停）；
  /// - `off` = 强制关闭（始终暂停，仅放行任务级例外 `Task.forceRun`）。
  ///
  /// 与 [guardSet] 同属"允许远程写全局 pref"的既有先例：本开关是用户自己的
  /// 整体刹车，不含绕过他人护栏的提权面。⚠️ 与夜间豁免主开关不同 ——
  /// 后者是**单机护栏授权**，远程**绝不允许**写（QE-13/14 源码扫描锁死）。
  ///
  /// 需 `script` 权限位（`RcPermGate.requiredPerm` 登记）：切换整体刹车是有
  /// 副作用的全局操作，同 [scriptRun] 一档。
  static const runMasterSet = 'run.master.set';

  // ---- v2.1：远程桌面级控制（docs/25，看+控）----
  //
  // ⚠️ 纪律同 docs/24 阶段0：**此处只加常量与文档注释，不加发射方**。
  // 发射/处理随 P0→P3 分阶段实现；未实现的命令在端点侧**如实 `ok:false`**，
  // 不得静默成功（与本协议一以贯之的"不假成功"纪律一致）。
  //
  // 安全：输入注入是**高危能力**（可代用户操作任意 App）。全部命令：
  // ① 仅**已配对**控制端可用；② 需 `script` 权限位（`RcPermGate`）；
  // ③ 端点必须**显式授权**（画面 = MediaProjection 系统弹窗；输入 = 系统无障碍开关）；
  // ④ 会话停止后携旧 `castId` 的 `input.*` 一律拒（会话失效锁）。

  /// 请求开启控制会话（画面 + 输入）。
  /// payload：`{castId, kind:'view'|'control', maxW?, maxH?, fps?}` →
  /// `rc.ack` + 会话状态经 [RcEvt.screen] 镜像。
  ///
  /// `kind:'view'` = 仅看（等价 docs/24 投屏）；`kind:'control'` = 看 + 输入注入。
  /// 授权前置：画面须过 MediaProjection 弹窗；`kind:'control'` 还须端点已开启无障碍，
  /// 否则**如实 `ok:false`**（不静默降级为仅看）。
  static const screenCastRequest = 'screen.cast.request';

  /// 停止控制会话（画面与输入同时停）。
  /// payload：`{castId, reason?}` → `rc.ack`。
  static const screenCastStop = 'screen.cast.stop';

  /// 远程点击。payload：`{castId, x, y, durationMs?}`（**x/y 为归一化 0..1**）。
  /// 端点按当前屏幕实际像素换算 —— 控制端无需知道端点分辨率，旋转/分辨率变化不失效。
  static const inputTap = 'input.tap';

  /// 远程滑动/拖拽。payload：`{castId, x1, y1, x2, y2, durationMs}`（归一化 0..1）。
  static const inputSwipe = 'input.swipe';

  /// 远程按键。payload：`{castId, keyCode}`。
  /// ⚠️ 仅无障碍（`performGlobalAction`）可表达的**导航类**（返回/Home/最近任务）；
  /// 电源/音量等系统级按键无障碍**做不到**，需 Shizuku（P1 可选），此处如实不承诺。
  static const inputKey = 'input.key';

  /// 远程文本输入。payload：`{castId, text}`。
  /// 端点侧优先对**已聚焦**输入框走无障碍 `ACTION_SET_TEXT`；不可用时如实失败。
  static const inputText = 'input.text';
}

// ---------------- 事件类型（端点 → 控制器） ----------------

abstract final class RcEvt {
  static const pong = 'rc.pong';
  static const status = 'rc.status';
  static const tasks = 'rc.tasks';
  static const logs = 'rc.logs';
  static const ack = 'rc.ack'; // 通用回执 {ok, for: cmdId, data}
  static const heartbeat = 'rc.heartbeat'; // 周期 60s
  static const exec =
      'rc.exec'; // 动作执行通知 {for?, taskId, taskName, ok, message, fromName}
  static const offline = 'rc.offline'; // LWT 由 broker 代发（明文哨兵，无敏感内容）
  static const scriptState =
      'rc.script'; // {scriptId, state: running|done|stopped, stepIndex}
  static const pttAck = 'rc.ptt'; // {voiceId, ok, playedMs}
  static const callState =
      'rc.call'; // 通话状态镜像 {callId, state: ringing|connected|ended}
  static const device = 'rc.device'; // 设备状态快照（载荷见 deviceStatus）
  static const photo =
      'rc.photo'; // 拍照回传 {photoB64} —— **当前无发射方**（camera.snap 恒降级，C-5）
  static const location =
      'rc.location'; // 定位回传 {for, lat, lng, acc}｜失败 {for, error:true}
  static const callMissed = 'rc.call.missed'; // 未接（被叫进程不在线时由控制器判定）

  /// 对端设备改名通知（FR-77，第八十四轮）：`{for, peerId, name}`。
  ///
  /// 端点收到控制端的 `device.rename` 后，除回 `rc.ack` 外，还向**其它**已配对
  /// 控制端（或该控制端自己的镜像）广播本事件，使各端列表即时刷新。
  static const deviceRenamed = 'rc.deviceRenamed';

  // ---- v1.7：远程任务 CRUD 回执 ----
  static const task = 'rc.task'; // 单条任务完整定义 {for, task}
  static const assets =
      'rc.assets'; // 音源库 {for, assets:[{id,name,durationMs,tags}]}
  static const presets = 'rc.presets'; // 预置分类 {for, categories:[...]}
  static const plan = 'rc.plan'; // 反击计划快照 {for, plan, enabled, planId, taskCount}

  // ---- v2.1：远程桌面级控制回执（docs/25）----

  /// 控制会话状态机镜像（与 [callState] 同形）。
  /// payload：`{for, castId, state: requesting|streaming|stopped|denied, kind}`。
  static const screen = 'rc.screen';

  /// 单条输入注入回执。payload：`{for, castId, ok, message?}`。
  ///
  /// **刻意不并入通用 [ack]**：注入是高频、逐条回执的，混进命令级 ack 会让
  /// 送达账本（[RcDeliveryLedger]）把"每一条 tap"当成一条命令，语义与容量都不对。
  static const inputAck = 'rc.inputAck';
}

// ---------------- 加密编解码 ----------------

final class RcCodec {
  RcCodec._();

  static final Hkdf _alg = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// v2 前置拉伸（Q1.B）：PBKDF2-HMAC-SHA256，`cryptography` 包默认实例
  /// 纯 Dart 实现（VM/移动端可用；Argon2id 虽在 `DartCryptography` 中存在，
  /// 但 PBKDF2 成本可预期且与本仓库 `ExportCrypto` 同族，选 PBKDF2）。
  static final Pbkdf2 _stretch = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  );
  static final AesGcm _aes = AesGcm.with256bits();

  /// 由配对秘密派生消息密钥。
  /// [context]：`{endpointId}|cmd` 或 `{endpointId}|evt`——端点与控制器
  /// 双方都能派生同方向密钥（每个配对、每个方向独立密钥）。
  ///
  /// [salt]：每设备随机盐（Q1.B）。**兼容铁律**：
  /// - 无盐（null 或空）→ 原始 v1 路径（纯 HKDF），已配对端点继续可用；
  /// - 有盐 → 先 PBKDF2 前置拉伸，再把盐并入 HKDF salt 参数（v2）。
  /// 双方必须持有同一份盐：端点在配对登记时生成下发，控制端在配对成功
  /// 事件时落盘（见 `KdfSaltStore`）。
  static Future<List<int>> deriveKey(
    String secret,
    String context, {
    List<int>? salt,
  }) async {
    List<int> ikm = utf8.encode(secret);
    List<int> hkdfSalt = utf8.encode('sonicshield-rc-v1|$context');
    if (salt != null && salt.isNotEmpty) {
      final stretched = await _stretch.deriveKey(
        secretKey: SecretKey(utf8.encode(secret)),
        nonce: salt,
      );
      ikm = await stretched.extractBytes();
      // ⚠️ `utf8.encode` 返回**不可变** Uint8List，不能 `..addAll`（运行时炸
      // "Cannot add to a fixed-length list"）—— 必须新建可增长列表拼接。
      hkdfSalt = <int>[
        ...utf8.encode('sonicshield-rc-v2|$context'),
        ...salt,
      ];
    }
    final sk = await _alg.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: hkdfSalt,
      info: utf8.encode('sonicshield'),
    );
    return sk.extractBytes();
  }

  /// 加密：AES-256-GCM，AAD = topic（v1 简化：防跨主题移植密文）。
  static Future<String> encode(
    RcMessage msg,
    List<int> key,
    String topic,
  ) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(msg.toJson())),
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode(topic),
    );
    final blob = <String, String>{
      'n': base64Encode(nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    };
    return base64Encode(utf8.encode(jsonEncode(blob)));
  }

  /// 解密；时间窗与去重校验由 [seenIds]/[maxSkewMs] 承担。
  static Future<RcMessage?> decode(
    String wire,
    List<int> key,
    String topic, {
    Map<String, int> seenIds = const {},
    int maxSkewMs = 90000,
  }) async {
    try {
      final blob = (jsonDecode(utf8.decode(base64Decode(wire))) as Map)
          .cast<String, String>();
      final box = SecretBox(
        base64Decode(blob['c']!),
        nonce: base64Decode(blob['n']!),
        mac: Mac(base64Decode(blob['m']!)),
      );
      final clear = await _aes.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode(topic),
      );
      final msg = RcMessage.tryParse(
          (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
      if (msg == null) return null;
      final skew = (DateTime.now().millisecondsSinceEpoch - msg.ts).abs();
      if (skew > maxSkewMs) return null; // 重放/时钟漂移保护
      // P2-26：能走到这里说明 ID 必非空（tryParse 已拒绝空 ID），故去重恒生效。
      if (seenIds.containsKey(msg.id)) return null;
      return msg;
    } on Object {
      return null; // 解密失败（密钥不符/篡改）→ 静默丢弃
    }
  }

  /// 入站去重的**原子登记**（P1-17）：把"查重"与"预占"并进**同一个无 await
  /// 的同步段**。
  ///
  /// ## 为什么不能拆成两步
  /// 入站链路要**解密之后**才拿得到消息 ID（cmd 主题连发送方都不在主题里）。
  /// 旧实现把判断拆在 `decode`（只读查重，`:336`）与调用方的 `_rememberSeen`
  /// （后写）两处，中间隔着 `await` —— 异步 stream 回调并不因前一回调返回
  /// Future 就天然串行，于是同一条 QoS1 命令在第一次处理完成前重投/并发到达时，
  /// **两次都能通过查重**，播放/立即运行/指令组等副作用重复执行。
  ///
  /// 本函数把两者合进一个同步段：单 isolate 下同步段对同 isolate 的一切重入
  /// 是原子的（与引擎 `replanning` / `executing` 守卫成立的前提同源）。
  ///
  /// 返回 `true` = 首次见到（已预占，可继续执行副作用）；`false` = 重复
  /// （不得执行任何副作用）。空 ID 不参与去重、恒返回 `true`（协议入口另有
  /// P2-26 的"拒绝空 ID"把关，这里不把空串污染进去）。
  static bool reserveInboundId(
    Map<String, int> seen,
    String id,
    int nowMs, {
    int windowMs = 10 * 60 * 1000,
  }) {
    if (id.isEmpty) return true;
    if (seen.containsKey(id)) return false;
    seen[id] = nowMs;
    seen.removeWhere((_, t) => nowMs - t > windowMs);
    return true;
  }

  /// 生成配对码：8 位 Base32（Crockford 风格去易混字符），≈40bit 熵。
  static String generatePairingCode() {
    const chars = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
    final r = Random.secure();
    final raw = List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
    return '${raw.substring(0, 4)}-${raw.substring(4)}';
  }

  /// 配对码轮换（Q1.B）：生成与 [current] 同格式、**不与旧码相同**的新配对码。
  /// 纯函数：不做落盘/网络操作；持久化与 UI 入口由调用方负责。
  /// 比较时剥除 `-` 分隔符，杜绝新旧码仅分隔符位置不同的假轮换。
  static String rotatedPairingCode(String current) {
    const chars = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
    final r = Random.secure();
    String gen() {
      final raw =
          List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
      return '${raw.substring(0, 4)}-${raw.substring(4)}';
    }

    final old = current.replaceAll('-', '');
    var next = gen();
    while (next.replaceAll('-', '') == old) {
      next = gen();
    }
    return next;
  }

  /// 生成 32 字节每设备随机盐（Q1.B）。Base64 落盘由 `KdfSaltStore` 负责。
  static List<int> newSalt() =>
      List.generate(32, (_) => Random.secure().nextInt(256));

  /// 设备 ID：16 位小写十六进制。
  static String generateDeviceId() =>
      List.generate(16, (_) => '0123456789abcdef'[Random.secure().nextInt(16)])
          .join();
}

// ══════════════════════════════════════════════════════════════════════
// P2-20：出站命令的送达状态账本（判据与接线分离）
// ══════════════════════════════════════════════════════════════════════
//
// 旧实现 `sendTo` 在 `publishMessage` 之后**立刻 return true**，把
// "MQTT 客户端受理了"当成"对端执行完了" —— UI 于是把四种语义混为一谈：
// "写进本地 outbox" / "publish 已受理" / "broker QoS ack" / "端点最终回执"。
// 这正是"UI 成功语义偏乐观"的根因：弱网下 publish 成功、端点却从没收到。
//
// 这里把状态显式分档，并把"关联"（correlation）做实：每条命令以自身
// [RcMessage.id] 为 requestId，端点回执以 `payload['for'] == requestId` 对齐。
// 账本为**纯内存、无副作用**，宿主测试可直接穷举"迟到/重放/无关的 ack
// 不得让任何命令通过"这一反例判据。

/// 一条出站命令的送达状态（P2-20）。
enum RcDeliveryState {
  /// 未连接 ⇒ 只写进本地 outbox，等端点上线补发（**尚未离开本机**）。
  queued,

  /// 已交给 MQTT 客户端发布（**不等** broker QoS ack，更不等端点回执）。
  published,

  /// 收到端点最终回执且成功（`rc.ack {for, ok: true}`）。
  acked,

  /// 端点明确回执失败（`ok: false`）。
  failed,

  /// 超过期限仍无回执（由 [RcDeliveryLedger.expire] 扫描得到）。
  expired,
}

/// 出站命令等待端点回执的期限（P2-20）：超时即标记 `expired`，
/// 让"UI 一直转圈"变成"明确结论"。
const int rcDeliveryAckTimeoutMs = 30 * 1000;

/// 一条出站命令的送达记录（P2-20）。
class RcDelivery {
  const RcDelivery({
    required this.requestId,
    required this.targetId,
    required this.createdAtMs,
    required this.state,
    this.expiresAtMs,
  });

  /// 关联键（correlation）：与端点回执 `payload['for']` 对齐。
  final String requestId;

  /// 目标端点 deviceId。
  final String targetId;

  final int createdAtMs;

  /// 等待回执的截止时刻；null = 无期限。
  final int? expiresAtMs;

  final RcDeliveryState state;

  /// 是否为终态（此后不再被任何回执翻转）。
  bool get isTerminal =>
      state == RcDeliveryState.acked ||
      state == RcDeliveryState.failed ||
      state == RcDeliveryState.expired;

  RcDelivery copyWith({RcDeliveryState? state}) => RcDelivery(
        requestId: requestId,
        targetId: targetId,
        createdAtMs: createdAtMs,
        expiresAtMs: expiresAtMs,
        state: state ?? this.state,
      );
}

/// 出站命令的**送达账本**（P2-20）：把"sendTo 返回 true"与"端点最终回执"分开。
///
/// * 迟到/重放的 ack（requestId 未知或记录已终态）**不得**让任何命令通过；
/// * 过期命令被 [expire] 扫成 `expired`，此后 ack 不再翻转它。
class RcDeliveryLedger {
  RcDeliveryLedger({this.maxEntries = 256});

  /// 上限：超限淘汰**最旧**一条（内存账本，不参与持久化）。
  final int maxEntries;
  final Map<String, RcDelivery> _byId = <String, RcDelivery>{};
  final List<String> _order = <String>[];

  int get length => _byId.length;

  RcDelivery? stateOf(String requestId) => _byId[requestId];

  /// 登记一次出站。[published] 为 true ⇒ 已 publish；false ⇒ 仅入 outbox。
  RcDelivery record(
    String requestId,
    String targetId, {
    required bool published,
    required int nowMs,
    int? ttlMs,
  }) {
    final r = RcDelivery(
      requestId: requestId,
      targetId: targetId,
      createdAtMs: nowMs,
      expiresAtMs: ttlMs == null || ttlMs <= 0 ? null : nowMs + ttlMs,
      state: published ? RcDeliveryState.published : RcDeliveryState.queued,
    );
    if (_byId.containsKey(requestId)) _order.remove(requestId);
    _byId[requestId] = r;
    _order.add(requestId);
    while (_order.length > maxEntries) {
      _byId.remove(_order.removeAt(0));
    }
    return r;
  }

  /// 接收一条端点回执：返回**被更新的记录**；以下情况一律返回 `null`
  /// （迟到/重放/无关的 ack **不得**让新命令通过 —— P2-20 的反例判据）：
  /// * requestId 未知（从未登记 / 已被淘汰）；
  /// * 记录已终态（重复 ack）；
  /// * 记录已过期（即使 `expire` 还没扫到）。
  RcDelivery? acceptAck(
    String requestId, {
    required bool ok,
    required int nowMs,
  }) {
    final cur = _byId[requestId];
    if (cur == null || cur.isTerminal) return null;
    if (cur.expiresAtMs != null && nowMs > cur.expiresAtMs!) {
      final expired = cur.copyWith(state: RcDeliveryState.expired);
      _byId[requestId] = expired;
      return expired;
    }
    final next = cur.copyWith(
        state: ok ? RcDeliveryState.acked : RcDeliveryState.failed);
    _byId[requestId] = next;
    return next;
  }

  /// 扫描过期记录，返回本次**新过期**的那些。
  List<RcDelivery> expire(int nowMs) {
    final out = <RcDelivery>[];
    for (final id in _order) {
      final cur = _byId[id];
      if (cur == null || cur.isTerminal) continue;
      if (cur.expiresAtMs != null && nowMs > cur.expiresAtMs!) {
        final expired = cur.copyWith(state: RcDeliveryState.expired);
        _byId[id] = expired;
        out.add(expired);
      }
    }
    return out;
  }
}

/// 扫码配对 URI（v1.5）：
/// sonicshield://pair/{deviceId(16位)}/{name(urlencoded)}/{code(8位)}
abstract final class PairQrProtocol {
  static const prefix = 'sonicshield://pair/';

  /// 解析对端配对二维码；格式不符（ID/码长度、前缀）返回 null。
  ///
  /// ⚠️ **BUG-075（第四十轮修）**：`deviceId` 与 `code` **都必须归一化到小写**。
  /// 此前只归一化了码（剥连字符 + 转大写），ID 原样保留 —— 而
  /// `_hex16` 明确接受大写、手输框的提示语又写"0-9 与 a-f"，
  /// 于是用户手抄成大写时：本机落盘成功、二维码/结果卡片都说"已配对"，
  /// 但 `deviceId` 是 **MQTT 主题段**（`sonicshield/v1/{deviceId}/cmd`，
  /// 大小写敏感）且是密钥派生的输入（`deriveKey(code, '{deviceId}|cmd')`）——
  /// 对端实际主题是小写（`generateDeviceId()` 恒小写，见上），
  /// 结果就是**命令永远发不出去、回执永远解不开**，且全程无任何报错。
  /// 归一化放在协议层（项目既定的"归一化只有协议层一处实现"），
  /// 使扫码与手输两条路径同时受益。
  static ({String deviceId, String name, String code})? parseUri(String uri) {
    if (!uri.startsWith(prefix)) return null;
    final parts = uri.substring(prefix.length).split('/');
    if (parts.length < 3) return null;
    final id = parts[0].toLowerCase();
    final name = Uri.decodeComponent(parts[1]);
    final code = parts[2].replaceAll('-', '').toUpperCase();
    if (id.length != 16 || code.length != 8) return null;
    return (deviceId: id, name: name, code: code);
  }
}
