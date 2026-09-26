/// 通话生命周期的**纯逻辑**（不依赖 WebRTC / Timer / 平台通道）。
///
/// ## 为什么单独抽出来
///
/// **BUG-050**：主叫侧**没有接听超时** —— 被叫未开自动接通时，主叫会
/// **无限等待**，且没有任何"未接"反馈。这段逻辑原先埋在 [CallService]
/// （依赖 flutter_webrtc 与真实信令）里，宿主机无法实例化
/// → **整整一个版本没有被任何用例覆盖过**。
///
/// 本项目对此的既定手法是：把判定链抽成**纯函数**再上锁
/// （`remote_playback.dart`、`guarded_dispatch.dart` 同范式）。
/// 抽出来之后，"什么时候算超时""`rc.call` 的 state 该怎么解释"
/// 就变成了宿主机可断言的量 —— 不需要设备、不需要 broker、不需要 WebRTC。
library;

// ---------------- 超时上限 ----------------

/// 主叫等待被叫**应答**（收到 SDP answer 或 `rc.call state=connected`）的上限。
///
/// 取 45s：够覆盖"手机在口袋里、人走过去接"的常见情形，
/// 又不至于让主叫对着"连接中…"干等到怀疑应用卡死。
const Duration callerAnswerTimeout = Duration(seconds: 45);

/// 被叫**振铃**（手动接听模式）上限。
///
/// 超时后由**端点侧**发出 `RcEvt.callMissed`，主叫据此结束等待 ——
/// 这样"没人接"这件事不需要主叫单方面猜。
const Duration calleeRingTimeout = Duration(seconds: 45);

/// 按角色取等待上限（毫秒）。
int waitLimitMs({required bool isCaller}) =>
    (isCaller ? callerAnswerTimeout : calleeRingTimeout).inMilliseconds;

/// 等待是否已超时。
bool waitTimedOut({required int elapsedMs, required Duration limit}) =>
    elapsedMs >= limit.inMilliseconds;

/// 本次超时是否**应当判定为"未接"**。
///
/// 只有在"还没接通"时超时才算未接。已接通后即便计时器残留触发，
/// **也不得**报未接 —— 否则用户会在通话进行中看到"对方无应答"。
bool timedOutMeansMissed({
  required bool answered,
  required int elapsedMs,
  required Duration limit,
}) =>
    !answered && waitTimedOut(elapsedMs: elapsedMs, limit: limit);

// ---------------- `rc.call` 状态镜像 ----------------

/// `rc.call` 事件里 `state` 字段的归一化解释。
enum RemoteCallState {
  /// 对端已振铃（收到 invite、尚未接听）。
  ringing,

  /// 对端已接通。
  connected,

  /// 对端已结束本次通话。
  ended,

  /// 无法识别的状态。
  unknown,
}

/// 解析 `rc.call` 的 `state`。
///
/// ⚠️ 未知值一律归 [RemoteCallState.unknown] 并**按"什么都不做"处理**：
/// 猜一个状态去改本地阶段，会让"对端说了一句我们没听懂的话"
/// 变成"本地状态被改坏"。协议演进时新增 state 值必须显式登记。
RemoteCallState parseRemoteCallState(Object? raw) => switch (raw) {
      'ringing' => RemoteCallState.ringing,
      'connected' => RemoteCallState.connected,
      'ended' => RemoteCallState.ended,
      _ => RemoteCallState.unknown,
    };

/// 收到该远端状态后，是否应当**取消"等待应答"计时**。
bool remoteStateStopsWaiting(RemoteCallState s) =>
    s == RemoteCallState.connected || s == RemoteCallState.ended;

/// 收到该远端状态后，是否应当**结束本地通话**。
bool remoteStateEndsCall(RemoteCallState s) => s == RemoteCallState.ended;

/// "连接中"阶段的文案。
///
/// 主叫收到对端 `rc.call state=ringing` 后应显示"对方振铃中…" ——
/// 修 BUG-050 前 `rc.call` **在 App 内无人消费**，主叫只能一直看到
/// "连接中…"，**无法区分"对方手机正在响"与"信令根本没送到"**。
/// 这两者的下一步动作完全不同（前者等，后者查网络），却显示同一句话。
String connectingText(RemoteCallState remote) =>
    remote == RemoteCallState.ringing ? '对方振铃中…' : '连接中…';

// ---------------- 被叫收到 invite 后该做什么 ----------------

/// 被叫侧收到 `rc.call.invite` 后的动作。
enum CalleeAction {
  /// 直接接通（用户**显式**开启了「自动接通」）。
  autoAccept,

  /// 振铃，等用户在界面上接听或拒接（**默认路径**）。
  ringUser,

  /// 本机正在通话中 → 回 `busy`，让主叫立刻得到反馈。
  rejectBusy,
}

/// 决定被叫的动作。
///
/// ## 为什么要有这个纯函数（BUG-056）
///
/// 修之前：`endpoint_service._handleCallInvite` 的 `onManualRing` 回调
/// **立刻调 `acceptIncoming`**（注释写着"v1.4 简化"）—— 于是
/// **「自动接通」开关关掉也照样自动接通**，那个开关等于不存在。
///
/// 这不只是"功能没做"，而是**隐私问题**：该开关是使用者唯一能表达
/// "别自动接我的电话"的地方（设置页文案：仅限已配对设备呼入时自动接通，
/// 用于家人守护）。开关失灵意味着**来电会被静默接通、摄像头/麦克风被打开**，
/// 而使用者以为自己已经关掉了。
///
/// 抽成纯函数的收益：这条判断（以及"默认必须是 `ringUser`"）可以在宿主机断言，
/// 不需要 WebRTC、不需要真机 —— 而它原先埋在一个**没人能实例化**的类里。
///
/// ⚠️ 默认分支必须是 [CalleeAction.ringUser]：把"读不到开关"或"将来新增分支"
/// 的兜底做成 `autoAccept`，就等于把"隐私开关默认关闭"这件事做反了。
CalleeAction calleeActionFor({
  required bool autoAnswer,
  required bool inCall,
}) {
  if (inCall) return CalleeAction.rejectBusy;
  return autoAnswer ? CalleeAction.autoAccept : CalleeAction.ringUser;
}

/// 振铃界面上「接听」按钮是否可用（只在真正振铃时可用）。
bool canAcceptNow(bool ringing) => ringing;

/// 来电提示文案（通知与界面共用，避免两处文案漂移）。
String incomingCallText({required String fromName, required bool video}) =>
    '来自 $fromName（${video ? '视频' : '语音'}）';

// ---------------- 发起呼叫的失败原因（BUG-D：点了按钮"什么都没发生"） ----------------

/// 发起呼叫被拦下的原因。
///
/// ## 为什么要有这个枚举（BUG-D）
///
/// 修之前 `CallScreen._call` 只做两件事：调 `startCall`，然后
/// **push 一个不存在的路由**。`startCall` 返回 null 时界面给的是
/// 一句话兜底："呼叫失败：请检查摄像头/麦克风权限或端点离线" ——
/// 把"已在通话中""权限被拒""相机被占用""端点离线"四种**下一步动作完全不同**
/// 的原因，压成了一句不可执行的话（与 BUG-062 同形状：失败必须可诊断）。
///
/// 更糟的是它只覆盖了 `startCall` 的失败；成功那条路上没有任何界面
/// （见 [CallStartBlock] 的调用方 `call_screen.dart`）。
enum CallStartBlock {
  /// 本机已在通话中（含振铃/连接中）。
  alreadyInCall,

  /// 麦克风未授予 —— 接起来也没有声音，等于假成功。
  micDenied,

  /// 视频呼叫但相机未授予。
  cameraDenied,

  /// 打不开摄像头/麦克风（被其它应用占用、硬件不可用…）。
  mediaFailed,

  /// SDP（Offer）生成失败或为空 —— 这种 invite 发出去也一定协商失败。
  offerFailed,

  /// 端点离线 / 本机网络不可用：实时信令**不能**走 outbox 补发。
  endpointOffline,
}

/// 失败文案。
///
/// ⚠️ 用 **switch 表达式**（必须穷尽）：新增一个 `CallStartBlock` 而忘了补文案
/// 会**编译报错**；写成带 `default` 的 switch 语句则会静默给出兜底文案
/// —— 那正是本项目反复出现的"静默降级"。
String callStartBlockText(CallStartBlock b) => switch (b) {
      CallStartBlock.alreadyInCall => '正在通话中：请先挂断当前通话再发起',
      CallStartBlock.micDenied => '需要麦克风权限才能通话（否则对方听不到你）',
      CallStartBlock.cameraDenied => '需要相机权限才能发起视频通话',
      CallStartBlock.mediaFailed =>
        '打不开摄像头/麦克风：可能被其它应用占用，请关闭后重试',
      CallStartBlock.offerFailed => '无法生成通话协商信息（SDP），请重试',
      CallStartBlock.endpointOffline =>
        '端点离线或本机网络不可用：请确认「远程遥控」已开启、对端在线',
    };

/// 发起前的权限判定：返回 null 表示**放行**。
///
/// 麦克风优先：没有麦克风的话视频再好也没有意义，先报最根本的那个
/// （与 `call_permission.dart` 的 `autoAnswerBlockFor` 同一优先级约定）。
///
/// ⚠️ 语音呼叫（`video == false`）**不得**因为相机被拒而拦下 ——
/// 那会把"能用"的功能报成不能用（成功被误报的反面：可用被误报为不可用）。
CallStartBlock? callStartBlockFor({
  required bool micGranted,
  required bool cameraGranted,
  required bool video,
}) {
  if (!micGranted) return CallStartBlock.micDenied;
  if (video && !cameraGranted) return CallStartBlock.cameraDenied;
  return null;
}

// ---------------- ICE candidate 的到达时序（BUG-D：候选被丢弃） ----------------

/// 收到的 ICE candidate 是否**可以立刻**喂给 PeerConnection。
///
/// ## 为什么要有这个判定（BUG-D 的核心真因之一）
///
/// WebRTC 的硬要求：`addCandidate` 必须在 `setRemoteDescription` **之后**。
/// 修之前 `onCandidate` 的守卫是 `if (payload['callId'] != _callId || _pc == null) return;`
/// —— 于是**凡是早到的候选一律被静默丢弃**，而"早到"在两条路径上都是常态：
///
/// - **被叫（手动接听）**：`_pc` 要到用户点「接听」时才创建。主叫的候选在
///   **振铃期间**就已经到达 ⇒ 全部被丢。而 ICE gathering 通常几秒内就结束，
///   等用户接听时**不会再有候选补发** ⇒ ICE 永远凑不齐 ⇒ 表现为
///   "接通了但没画面、没声音"（用户口中的"无效果"）。
/// - **主叫**：被叫的候选在 `call.answer` 之前发出（`setLocalDescription(answer)`
///   先于发信令），因此也会早于 remote description 到达。
///
/// 规则：**能喂则喂；不能喂就先缓存、稍后重放 —— 绝不丢弃。**
bool candidateDeliverable({
  required bool pcReady,
  required bool remoteDescriptionSet,
}) =>
    pcReady && remoteDescriptionSet;

/// 早到候选的缓存上限。
///
/// 取 64：正常机型一次 gathering 通常 <20 条，留足余量；上限的意义只是
/// 防止对端异常刷屏把内存顶爆（**不是**正常路径）。
const int maxBufferedCandidates = 64;

// ---------------- 结束原因（用户可见文案的唯一来源） ----------------

/// 通话结束原因。
enum CallEndReason {
  /// 正常结束（已接通后本端主动挂断）。
  answered,

  /// 未接 —— 等待应答超时。
  missed,

  /// **对方**拒接（由对端 `call.end reason=rejected` 推出）。
  rejected,

  /// **本端**拒接（本机用户点了"拒接"）。
  ///
  /// ⚠️ 必须与 [rejected] 分开：两者文案不同。
  /// 拒接的人自己看到"对方已拒接"会以为被拒的是自己。
  declined,

  /// 对方占线。
  busy,

  /// 对方挂断（或语义不明的结束信令）。
  remoteEnded,

  /// 本端主动挂断（尚未接通时取消呼叫）。
  hangup,

  /// 媒体/连接失败。
  failed,
}

/// 把结束原因映射成给用户看的一句话。
String callEndText(CallEndReason r) => switch (r) {
      CallEndReason.answered => '通话结束',
      CallEndReason.missed => '对方无应答',
      CallEndReason.rejected => '对方已拒接',
      CallEndReason.declined => '已拒接',
      CallEndReason.busy => '对方正在通话中',
      CallEndReason.remoteEnded => '对方已挂断',
      CallEndReason.hangup => '已挂断',
      CallEndReason.failed => '连接失败',
    };

/// 由 `call.end` 信令里的 `reason` 字段推出结束原因。
///
/// ⚠️ 未知 reason **不得**默认成 [CallEndReason.hangup]（那会把"占线"
/// 显示成"已挂断"，用户会以为是对方主动挂了）；一律归
/// [CallEndReason.remoteEnded]，文案保持中性。
CallEndReason endReasonFromSignal(Object? raw) => switch (raw) {
      'rejected' => CallEndReason.rejected,
      'busy' => CallEndReason.busy,
      'media' => CallEndReason.failed,
      'missed' => CallEndReason.missed,
      'hangup' => CallEndReason.remoteEnded,
      _ => CallEndReason.remoteEnded,
    };

/// 通话结束后是否应当**主动告知用户**。
///
/// 本端主动挂断/拒接不需要再弹一次（用户自己刚点的按钮，再弹就是噪音）；
/// 其余（未接/被拒/占线/对方挂断/失败）**必须**说 ——
/// BUG-050 的原始症状就是"主叫等到天荒地老后**无声无息退回上一页**"，
/// 用户既不知道是没人接，也不知道是不是应用坏了。
///
/// ⚠️ 用**穷尽 switch 表达式**而不是 `default: true/false`：
/// 将来新增一个 [CallEndReason] 会**编译报错**，强迫作者显式决定
/// 它该不该弹。安全默认值（这里若写成 `_ => false`）正是本项目
/// 反复出现的"静默降级"来源。
bool shouldNotifyEnd(CallEndReason r) => switch (r) {
      CallEndReason.missed ||
      CallEndReason.rejected ||
      CallEndReason.busy ||
      CallEndReason.remoteEnded ||
      CallEndReason.failed =>
        true,
      CallEndReason.answered ||
      CallEndReason.hangup ||
      CallEndReason.declined =>
        false,
    };
