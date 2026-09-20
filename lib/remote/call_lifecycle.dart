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
