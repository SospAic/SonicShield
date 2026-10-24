import 'dart:math';

enum ActionType {
  playAudio, // 播放音频（核心）
  soundscape, // 声景混音（多轨叠加，v1.3）
  tts, // TTS 喊话（如固定提示语）
  notify, // 仅通知
  recordEvidence, // 录音取证（本地保存，带清晰标注）
  vibrate, // 震动（固定节奏；v1.x 起，向后兼容不动）
  randomVibrate, // 随机振动：一次触发内随机脉冲串（v1.9，docs/20 §4.2）
  continuousVibrate, // 持续振动：一段时长内连续 + 随机振幅（v1.9，docs/20 §4.3）
  randomFrom, // 动作集：加权随机选一执行（v1.8）
  composite, // 组合：主动作 + 可选的「先通知」
  ;

  String get label => switch (this) {
        ActionType.playAudio => '播放音频',
        ActionType.soundscape => '声景混音',
        ActionType.tts => '语音喊话',
        ActionType.notify => '发送通知',
        ActionType.recordEvidence => '录音取证',
        ActionType.vibrate => '震动（固定节奏）',
        ActionType.randomVibrate => '随机振动',
        ActionType.continuousVibrate => '持续振动',
        ActionType.composite => '组合动作',
        ActionType.randomFrom => '随机指令集',
      };

  /// 是否属于「震动」族（UI 分组、能力提示、统计归类共用）。
  ///
  /// ⚠️ 用**显式穷尽**而不是 `== vibrate || ...` 的散列判断：
  /// 新增震动子类型时编译器会在这里报错，逼人做出分类决策。
  bool get isVibrateFamily => switch (this) {
        ActionType.vibrate ||
        ActionType.randomVibrate ||
        ActionType.continuousVibrate =>
          true,
        ActionType.playAudio ||
        ActionType.soundscape ||
        ActionType.tts ||
        ActionType.notify ||
        ActionType.recordEvidence ||
        ActionType.randomFrom ||
        ActionType.composite =>
          false,
      };
}

/// 音频输出通道。
enum AudioChannel {
  media, // 媒体音量；遵循勿扰/静音
  alarm; // 闹钟通道；穿透勿扰与媒体静音（合规提示见文档）

  String get label => switch (this) {
        AudioChannel.media => '媒体通道',
        AudioChannel.alarm => '闹钟通道(穿透勿扰)',
      };
}

/// 动作参数**运行时**夹紧工具（BUG-123）。
///
/// ## 为什么 `assert` 不够
/// 本文件的区间约束全部写在构造函数 `assert` 里，而 **release 构建会整段剥离
/// assert**。`action_json` 有两个来源，**都不是可信输入**：
/// 1. 本机 sqlite（旧版本写过、手工改过、从备份 JSON 导入过 —— 见
///    `settings_screen` 的导入路径，那里**不经过** `TaskWire` 的线协议校验）；
/// 2. 控制端的 `task.upsert`（这条路径已有 `TaskWire._sanitizeActionMap`，
///    但那是**另一个出口**，两条路必须各自安全）。
///
/// 少了这一层，`RandomVibrateAction(pulseOnMsMin: 500, pulseOnMsMax: 100)` 在
/// release 下会被照单全收，物化期 `min + rng.nextInt(max - min + 1)` 于是拿到
/// **负数上界** ⇒ `RangeError` 抛出 ⇒ 引擎 tick 整体崩掉，表现为"整个调度
/// 静默死掉、任何任务都不再触发"，而用户看到的只是"不响了"。
///
/// ## 归一化策略：夹紧 + 交换，**不抛错**
/// 与 `TaskWire` 的"结构不可接受就拒绝整条任务"不同，这里是**本地已落库**
/// 的配置：拒绝等于让用户丢任务。区间方向填反了（10–3）语义上仍是同一个
/// 区间，**交换**即可；越界值夹到边界。唯一无法归一的是"结构缺失"
/// （如动作集一个候选都没有），那种情况由各自的 `fromJson` 单独兜底。
int _clampInt(Object? v, int def, int lo, int hi) {
  final n = v is num ? v.toInt() : def;
  if (n < lo) return lo;
  if (n > hi) return hi;
  return n;
}

double _clampDouble(Object? v, double def, double lo, double hi) {
  final n = v is num ? v.toDouble() : def;
  if (n.isNaN) return def; // NaN 与任何值比较都是 false ⇒ 必须单独挡
  if (n < lo) return lo;
  if (n > hi) return hi;
  return n;
}

/// 夹紧一对整数区间：各自夹进 `[lo, hi]`，再保证 `min <= max`（颠倒则交换）。
({int min, int max}) _rangeInt(
    Object? a, Object? b, int defMin, int defMax, int lo, int hi) {
  var mn = _clampInt(a, defMin, lo, hi);
  var mx = _clampInt(b, defMax, lo, hi);
  if (mn > mx) {
    final t = mn;
    mn = mx;
    mx = t;
  }
  return (min: mn, max: mx);
}

/// 夹紧一对浮点区间（语义同 [_rangeInt]）。
({double min, double max}) _rangeDouble(
    Object? a, Object? b, double defMin, double defMax, double lo, double hi) {
  var mn = _clampDouble(a, defMin, lo, hi);
  var mx = _clampDouble(b, defMax, lo, hi);
  if (mn > mx) {
    final t = mn;
    mn = mx;
    mx = t;
  }
  return (min: mn, max: mx);
}

/// 动作时长类字段的粗上界（24h）。
///
/// 与 `VibrateLimits.maxDurationSec` 同量级，只用来拒绝畸形值
/// （例如误填 999999 小时），**不是产品限制**。
const int _maxActionDurationSec = 86400;

/// 动作配置（sealed）。
sealed class ActionConfig {
  const ActionConfig();

  Map<String, dynamic> toJson();

  /// 与 `toJson()['kind']` **逐字一致**的稳定标识（审计/统计/日志筛选用）。
  ///
  /// 为什么单独给一个 getter 而不是让调用方读 `toJson()['kind']`：
  /// 后者每次都要构造一个 Map，且类型是 `dynamic` —— 审计字段拼错不会被编译器拦住。
  /// 这里是**穷尽 switch**：新增子类忘记登记会直接编译报错。
  String get kind => switch (this) {
        PlayAudioAction() => 'play',
        TtsAction() => 'tts',
        NotifyAction() => 'notify',
        RecordEvidenceAction() => 'record',
        VibrateAction() => 'vibrate',
        RandomVibrateAction() => 'randomVibrate',
        ContinuousVibrateAction() => 'continuousVibrate',
        ActionSetAction() => 'randomFrom',
        CompositeAction() => 'composite',
        SoundscapeAction() => 'soundscape',
      };

  static ActionConfig fromJson(Map<String, dynamic> j) => switch (j['kind']) {
        'play' => PlayAudioAction.fromJson(j),
        'tts' => TtsAction.fromJson(j),
        'notify' => NotifyAction.fromJson(j),
        'record' => RecordEvidenceAction.fromJson(j),
        'vibrate' => VibrateAction.fromJson(j),
        'randomVibrate' => RandomVibrateAction.fromJson(j),
        'continuousVibrate' => ContinuousVibrateAction.fromJson(j),
        'randomFrom' => ActionSetAction.fromJson(j),
        'composite' => CompositeAction.fromJson(j),
        'soundscape' => SoundscapeAction.fromJson(j),
        _ => throw ArgumentError('未知动作类型: ${j['kind']}'),
      };
}

/// 播放音频：随机挑选音源 + 随机时长 + 随机音量。
/// v1.1 新增：渐强唤醒（rampUpSec）与循环填充（loopFill）。
class PlayAudioAction extends ActionConfig {
  const PlayAudioAction({
    this.volumeMin = 0.6, // 0..1 系统流音量下限
    this.volumeMax = 1.0,
    this.durationSecMin = 3,
    this.durationSecMax = 15,
    this.fadeInSec = 0,
    this.fadeOutSec = 0,
    this.channel = AudioChannel.media,
    // 音频**继续**跟随勿扰（R93 只放开振动）：静音/勿扰时不该炸响，
    // 被系统压掉正是预期行为，不构成静默失败（用户要的就是"别响"）。
    this.respectDnd = true,
    this.rampUpSec = 0, // 渐强唤醒：音量从 5% 线性爬升到目标值的时长（0=关闭）
    this.loopFill = false, // 短音效循环填充到随机时长（Sleep 式声景）
  })  : assert(volumeMin >= 0 && volumeMin <= 1),
        assert(volumeMax >= 0 && volumeMax <= 1),
        assert(volumeMin <= volumeMax),
        assert(durationSecMin <= durationSecMax);

  final double volumeMin;
  final double volumeMax;
  final int durationSecMin;
  final int durationSecMax;
  final int fadeInSec;
  final int fadeOutSec;
  final AudioChannel channel;
  final bool respectDnd;
  final int rampUpSec;
  final bool loopFill;

  factory PlayAudioAction.fromJson(Map<String, dynamic> j) {
    // BUG-123：区间方向/越界必须在**这里**归一 —— release 下构造函数 assert
    // 已被剥离，而 `durationSecMin > durationSecMax` 会让物化期
    // `rng.nextInt(max - min + 1)` 拿到负数上界直接抛 `RangeError`。
    final vol = _rangeDouble(j['volumeMin'], j['volumeMax'], 0.6, 1.0, 0, 1);
    final dur = _rangeInt(
        j['durationSecMin'], j['durationSecMax'], 3, 15, 1, _maxActionDurationSec);
    return PlayAudioAction(
      volumeMin: vol.min,
      volumeMax: vol.max,
      durationSecMin: dur.min,
      durationSecMax: dur.max,
      fadeInSec: _clampInt(j['fadeInSec'], 0, 0, 600),
      fadeOutSec: _clampInt(j['fadeOutSec'], 0, 0, 600),
      channel: (j['channel'] as String?) == 'alarm'
          ? AudioChannel.alarm
          : AudioChannel.media,
      respectDnd: j['respectDnd'] as bool? ?? true,
      rampUpSec: _clampInt(j['rampUpSec'], 0, 0, 3600),
      loopFill: j['loopFill'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'play',
        'volumeMin': volumeMin,
        'volumeMax': volumeMax,
        'durationSecMin': durationSecMin,
        'durationSecMax': durationSecMax,
        'fadeInSec': fadeInSec,
        'fadeOutSec': fadeOutSec,
        'channel': channel == AudioChannel.alarm ? 'alarm' : 'media',
        'respectDnd': respectDnd,
        'rampUpSec': rampUpSec,
        'loopFill': loopFill,
      };
}

class TtsAction extends ActionConfig {
  const TtsAction(
      {required this.text,
      this.volume = 0.8,
      this.channel = AudioChannel.media,
      this.voiceId = ''});

  final String text;
  final double volume;
  final AudioChannel channel;

  /// 音色 id（v2.0，见 `TtsVoices`）。空串 = 系统默认音色（向后兼容旧数据）。
  final String voiceId;

  factory TtsAction.fromJson(Map<String, dynamic> j) => TtsAction(
        text: j['text'] as String? ?? '',
        // BUG-123：音量越界会让 `AudioPlayer.setVolume` 抛错（音量必须 0..1）。
        volume: _clampDouble(j['volume'], 0.8, 0, 1),
        channel: (j['channel'] as String?) == 'alarm'
            ? AudioChannel.alarm
            : AudioChannel.media,
        voiceId: j['voiceId'] as String? ?? '',
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'tts',
        'text': text,
        'volume': volume,
        'channel': channel.name,
        'voiceId': voiceId,
      };
}

class NotifyAction extends ActionConfig {
  const NotifyAction(
      {required this.title, required this.body, this.silent = false});

  final String title;
  final String body;
  final bool silent;

  factory NotifyAction.fromJson(Map<String, dynamic> j) => NotifyAction(
        title: j['title'] as String? ?? '声盾',
        body: j['body'] as String? ?? '',
        silent: j['silent'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'notify', 'title': title, 'body': body, 'silent': silent};
}

/// 录音取证：录制指定秒数，保存到应用私有目录（*.evidence.m4a，不外传）。
class RecordEvidenceAction extends ActionConfig {
  const RecordEvidenceAction({this.seconds = 60});

  final int seconds;

  /// BUG-123：`seconds <= 0` 会让录音器**立刻结束却报成功**（或直接抛错），
  /// 取证文件变成 0 字节 —— 用户以为录到了，实际什么都没有。
  factory RecordEvidenceAction.fromJson(Map<String, dynamic> j) =>
      RecordEvidenceAction(seconds: _clampInt(j['seconds'], 60, 1, 1800));

  @override
  Map<String, dynamic> toJson() => {'kind': 'record', 'seconds': seconds};
}

class VibrateAction extends ActionConfig {
  const VibrateAction({this.patternMs = const [0, 300, 200, 300]});

  final List<int> patternMs;

  /// BUG-123：两处都得兜。
  /// - `(e as num)` 遇到非数字元素直接抛 `TypeError` ⇒ 整条任务读不出来；
  /// - 负数/超大单步时长会被原生 `vibrate(pattern)` 原样接收（release 下
  ///   `assert` 已剥离），表现为"点了没反应"或系统日志刷错。
  factory VibrateAction.fromJson(Map<String, dynamic> j) {
    final raw = j['patternMs'];
    final cleaned = <int>[
      if (raw is List)
        for (final e in raw)
          if (e is num) e.toInt().clamp(0, VibrateLimits.maxPatternStepMs),
    ];
    return VibrateAction(
      patternMs: cleaned.isEmpty
          ? const [0, 300, 200, 300]
          : (cleaned.length > VibrateLimits.maxPatternSteps
              ? cleaned.sublist(0, VibrateLimits.maxPatternSteps)
              : cleaned),
    );
  }

  @override
  Map<String, dynamic> toJson() => {'kind': 'vibrate', 'patternMs': patternMs};
}

/// 振动参数的**结构健全性上界**（docs/20 §11.3）。
///
/// ⚠️ 这是「配置不可自相矛盾」的健全性边界，**不是产品护栏** ——
/// 用户拍板 D1「持续振动不设时长硬上限」，所以这里取 24 小时这个
/// 与 `TaskWire.maxCooldownSec` 同量级的粗上界，只用于拒绝畸形配置
/// （例如误填 999999 小时导致分片表爆掉），不用于限制正常使用。
abstract final class VibrateLimits {
  static const int maxDurationSec = 86400; // 24h
  static const int minPulseOnMs = 20; // 低于 20ms 系统不保证生效
  static const int maxPulseOnMs = 2000;
  static const int maxPulseOffMs = 5000;
  static const int maxPulses = 1000;
  static const int maxJitterMs = 5000;
  static const int maxRampSec = 600;

  /// 固定节奏模式串：步数上限（与 Android Vibrator 模式串长度同量级）
  /// 与单步时长上限。
  static const int maxPatternSteps = 32;
  static const int maxPatternStepMs = 60000;
}

/// **随机振动（v1.9，docs/20 §4.2）**：一次触发内产生**随机脉冲串** ——
/// 每个脉冲的时长、间隔、强度都在各自区间内随机。
///
/// 与 `randomInterval` 触发组合即得到「随机间隔的随机振动」（FR-36）：
/// 触发层决定"什么时候震"，本动作决定"震成什么样"。
///
/// ⚠️ 为什么不塞进 [VibrateAction]：固定节奏与随机脉冲串的参数集**不相交**，
/// 合并后每个字段都得可空 → 消费点必然写出 `??` 链猜值（**BUG-068 的成因**）。
/// 新增 sealed 子类换来的是：老任务 `action_json` 一字不改（向后兼容）+
/// 所有穷尽 switch 编译期强制处理。
class RandomVibrateAction extends ActionConfig {
  const RandomVibrateAction({
    this.durationSecMin = 3,
    this.durationSecMax = 10,
    this.pulseOnMsMin = 150,
    this.pulseOnMsMax = 400,
    this.pulseOffMsMin = 100,
    this.pulseOffMsMax = 600,
    this.amplitudeMin = 0.4,
    this.amplitudeMax = 1.0,
    this.maxPulses = 200,
    this.rampUpSec = 0,
    // R93：默认 USAGE_ALARM（见下方 `respectDnd` 字段注记）。
    this.respectDnd = false,
  })  : assert(durationSecMin >= 1 &&
            durationSecMin <= durationSecMax &&
            durationSecMax <= VibrateLimits.maxDurationSec),
        assert(pulseOnMsMin >= VibrateLimits.minPulseOnMs &&
            pulseOnMsMin <= pulseOnMsMax &&
            pulseOnMsMax <= VibrateLimits.maxPulseOnMs),
        assert(pulseOffMsMin >= 0 &&
            pulseOffMsMin <= pulseOffMsMax &&
            pulseOffMsMax <= VibrateLimits.maxPulseOffMs),
        assert(amplitudeMin >= 0 && amplitudeMin <= amplitudeMax && amplitudeMax <= 1),
        assert(maxPulses >= 1 && maxPulses <= VibrateLimits.maxPulses),
        assert(rampUpSec >= 0 && rampUpSec <= VibrateLimits.maxRampSec);

  final int durationSecMin;
  final int durationSecMax;

  /// 单个脉冲的振动时长区间。
  final int pulseOnMsMin;
  final int pulseOnMsMax;

  /// 脉冲之间的停顿区间。
  final int pulseOffMsMin;
  final int pulseOffMsMax;

  /// **强度区间**（核心可调项）。无振幅控制设备上会被系统一律拉满。
  final double amplitudeMin;
  final double amplitudeMax;

  /// 脉冲数上限。**防爆护栏**：`on=20ms + off=0ms` 在 10 分钟内会产生 3 万个
  /// 时间点，直接撑爆 Android waveform 数组。超限时由物化期**截断并审计**，
  /// 不抛异常（与条件层"无法判定按满足处理"同一容错哲学）。
  final int maxPulses;

  /// 渐强：起始强度线性爬升到目标值的时长（0=关闭）。
  final int rampUpSec;

  /// 是否遵循系统勿扰。false ⇒ 原生侧用 `USAGE_ALARM`（**会穿透勿扰**，
  /// 与音频 `AudioChannel.alarm` 同一合规口径，UI 必须显式提示）。
  ///
  /// 🔴 R93 起默认 **false**（本机自排动作 = 用户自己设的"闹钟"）。
  /// 旧默认 true 走 `USAGE_NOTIFICATION`：系统静音/勿扰时**整条振动被吞**，
  /// 而 `vibrator.vibrate()` 仍返回成功 ⇒ 回执写 success、用户毫无感觉
  /// （用户报障"手机震动不好使"的真因，也是最坏的静默失败）。
  /// ⚠️ 远程入站仍然**强制 true**（`rc_script.dart`）—— 对端不得绕过本机勿扰。
  ///
  /// ⚠️ QUA-07（R94）：这个默认值翻转是**用户可感知的行为变更** ——
  /// 新建任务（编辑器默认随构造器 false）与存量任务（JSON 缺键时
  /// [RandomVibrateAction.fromJson] 同样取 false，R93 的有意识决定，
  /// `r93_vibrate_dnd_test` 的 VD 用例锁定）从此都会在静音/勿扰期间震动。
  /// 行为变更必须让用户知情（穿透勿扰的合规口径），提示契约：
  /// - prefs 键 **`dnd_default_changed_notice_pending`**（常量
  ///   `kDndDefaultChangedNoticePending`，定义在 `lib/core/app_keys.dart`，
  ///   归 F6；键名字符串跨 isolate 共享，拼写以此注释与常量为准）；
  /// - **写入方**：启动链在检测到"默认已翻转且未提示过"时置 `true`；
  /// - **读取方**：设置页一次性横幅（`settings_screen.dart`）读到 true
  ///   时展示说明，用户关闭后置回 `false`；
  /// - **横幅 UI 归 F6**，本文件只锁定键名与写入/读取契约，防止两侧漂移。
  final bool respectDnd;

  /// BUG-123：四个区间都必须运行时夹紧 —— 这是最容易崩的一族。
  /// `pulseOnMsMin > pulseOnMsMax` 在 release 下会被照收，物化期
  /// `min + rng.nextInt(max - min + 1)` 拿到负数上界 ⇒ `RangeError` ⇒ 引擎 tick 崩。
  factory RandomVibrateAction.fromJson(Map<String, dynamic> j) {
    final dur = _rangeInt(j['durationSecMin'], j['durationSecMax'], 3, 10, 1,
        VibrateLimits.maxDurationSec);
    final on = _rangeInt(j['pulseOnMsMin'], j['pulseOnMsMax'],
        VibrateLimits.minPulseOnMs, VibrateLimits.maxPulseOnMs,
        VibrateLimits.minPulseOnMs, VibrateLimits.maxPulseOnMs);
    final off = _rangeInt(j['pulseOffMsMin'], j['pulseOffMsMax'], 100, 600, 0,
        VibrateLimits.maxPulseOffMs);
    final amp = _rangeDouble(j['amplitudeMin'], j['amplitudeMax'], 0.4, 1.0, 0, 1);
    return RandomVibrateAction(
      durationSecMin: dur.min,
      durationSecMax: dur.max,
      pulseOnMsMin: on.min,
      pulseOnMsMax: on.max,
      pulseOffMsMin: off.min,
      pulseOffMsMax: off.max,
      amplitudeMin: amp.min,
      amplitudeMax: amp.max,
      maxPulses: _clampInt(j['maxPulses'], 200, 1, VibrateLimits.maxPulses),
      rampUpSec: _clampInt(j['rampUpSec'], 0, 0, VibrateLimits.maxRampSec),
      // R93：缺省随构造器默认（false = USAGE_ALARM）。
      // 旧数据里没有这个键时**不能**再回落 true —— 那等于把静默失败留给存量任务。
      // ⚠️ QUA-07：这是用户可感知的行为变更，一次性提示契约见
      // [RandomVibrateAction.respectDnd] 字段注记（prefs 键
      // `dnd_default_changed_notice_pending`，横幅归 F6）。
      respectDnd: j['respectDnd'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'randomVibrate',
        'durationSecMin': durationSecMin,
        'durationSecMax': durationSecMax,
        'pulseOnMsMin': pulseOnMsMin,
        'pulseOnMsMax': pulseOnMsMax,
        'pulseOffMsMin': pulseOffMsMin,
        'pulseOffMsMax': pulseOffMsMax,
        'amplitudeMin': amplitudeMin,
        'amplitudeMax': amplitudeMax,
        'maxPulses': maxPulses,
        'rampUpSec': rampUpSec,
        'respectDnd': respectDnd,
      };
}

/// **持续振动（v1.9，docs/20 §4.3）**：一段时长内**连续**振动，强度可在区间内
/// **随机波动**，支持渐强/渐弱、占空比与锐度。
///
/// 实现按设备能力三级降级（docs/20 §5.2）：
/// Android 16 包络（强度+锐度）→ 波形+振幅（强度）→ on/off（强度满格）。
/// **每一级降级都必须明示用户**（FR-34 口径修正）。
class ContinuousVibrateAction extends ActionConfig {
  const ContinuousVibrateAction({
    this.durationSecMin = 10,
    this.durationSecMax = 30,
    this.amplitudeMin = 0.5,
    this.amplitudeMax = 1.0,
    this.jitterMs = 0,
    this.sharpnessMin = 0.0,
    this.sharpnessMax = 0.0,
    this.dutyCyclePct = 100,
    this.rampUpSec = 0,
    this.rampDownSec = 0,
    // R93：默认 USAGE_ALARM（见下方 `respectDnd` 字段注记）。
    this.respectDnd = false,
  })  : assert(durationSecMin >= 1 &&
            durationSecMin <= durationSecMax &&
            durationSecMax <= VibrateLimits.maxDurationSec),
        assert(amplitudeMin >= 0 && amplitudeMin <= amplitudeMax && amplitudeMax <= 1),
        assert(jitterMs >= 0 && jitterMs <= VibrateLimits.maxJitterMs),
        assert(sharpnessMin >= 0 &&
            sharpnessMin <= sharpnessMax &&
            sharpnessMax <= 1),
        assert(dutyCyclePct >= 10 && dutyCyclePct <= 100),
        assert(rampUpSec >= 0 && rampUpSec <= VibrateLimits.maxRampSec),
        assert(rampDownSec >= 0 && rampDownSec <= VibrateLimits.maxRampSec);

  final int durationSecMin;
  final int durationSecMax;

  /// **随机振幅区间**（核心可调项）。
  final double amplitudeMin;
  final double amplitudeMax;

  /// 强度波动周期：每 N 毫秒重新取一次随机强度（0=恒定，只取一次基准值）。
  final int jitterMs;

  /// 锐度区间（**仅 Android 16 包络生效**，其余平台忽略并明示）。
  final double sharpnessMin;
  final double sharpnessMax;

  /// 占空比：100=不停顿；50=振一半停一半。低于 100 时实现为等长 on/off 波形。
  final int dutyCyclePct;

  final int rampUpSec;
  final int rampDownSec;

  /// 同 [RandomVibrateAction.respectDnd]（R93 起默认 false = USAGE_ALARM；
  /// QUA-07 一次性提示契约见那里的字段注记）。
  final bool respectDnd;

  /// BUG-123：区间/占空比全部运行时夹紧（理由同 [RandomVibrateAction.fromJson]）。
  /// `dutyCyclePct < 10` 会让原生侧算出的 on/off 分片表退化成"全 off"，
  /// 即**配置了却完全不振**，且不报错。
  factory ContinuousVibrateAction.fromJson(Map<String, dynamic> j) {
    final dur = _rangeInt(j['durationSecMin'], j['durationSecMax'], 10, 30, 1,
        VibrateLimits.maxDurationSec);
    final amp = _rangeDouble(j['amplitudeMin'], j['amplitudeMax'], 0.5, 1.0, 0, 1);
    final sharp =
        _rangeDouble(j['sharpnessMin'], j['sharpnessMax'], 0.0, 0.0, 0, 1);
    return ContinuousVibrateAction(
      durationSecMin: dur.min,
      durationSecMax: dur.max,
      amplitudeMin: amp.min,
      amplitudeMax: amp.max,
      jitterMs: _clampInt(j['jitterMs'], 0, 0, VibrateLimits.maxJitterMs),
      sharpnessMin: sharp.min,
      sharpnessMax: sharp.max,
      dutyCyclePct: _clampInt(j['dutyCyclePct'], 100, 10, 100),
      rampUpSec: _clampInt(j['rampUpSec'], 0, 0, VibrateLimits.maxRampSec),
      rampDownSec: _clampInt(j['rampDownSec'], 0, 0, VibrateLimits.maxRampSec),
      respectDnd: j['respectDnd'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'continuousVibrate',
        'durationSecMin': durationSecMin,
        'durationSecMax': durationSecMax,
        'amplitudeMin': amplitudeMin,
        'amplitudeMax': amplitudeMax,
        'jitterMs': jitterMs,
        'sharpnessMin': sharpnessMin,
        'sharpnessMax': sharpnessMax,
        'dutyCyclePct': dutyCyclePct,
        'rampUpSec': rampUpSec,
        'rampDownSec': rampDownSec,
        'respectDnd': respectDnd,
      };
}

/// 组合动作：主动作 + 可选前缀通知（仅两段，保持简单可预期）。
class CompositeAction extends ActionConfig {
  const CompositeAction({required this.primary, this.prefixNotify});

  final ActionConfig primary;
  final NotifyAction? prefixNotify;

  /// BUG-123：`primary` 缺失/损坏时**不能抛** —— 抛出去会让整条任务读不出来
  /// （`TaskRepository.listAll` 是 `rows.map(Task.fromRow)`，一行炸全表空）。
  /// 退化为一条明说原因的通知，执行期可见。
  factory CompositeAction.fromJson(Map<String, dynamic> j) {
    ActionConfig primary;
    try {
      primary = ActionConfig.fromJson(
          (j['primary'] as Map).cast<String, dynamic>());
    } on Object {
      primary = const NotifyAction(
          title: '声盾', body: '组合动作的主配置缺失或损坏，本次动作已跳过');
    }
    NotifyAction? prefix;
    final rawPrefix = j['prefixNotify'];
    if (rawPrefix is Map) {
      try {
        prefix = NotifyAction.fromJson(rawPrefix.cast<String, dynamic>());
      } on Object {
        prefix = null; // 前缀通知坏了就不发，但主动作照常执行。
      }
    }
    return CompositeAction(primary: primary, prefixNotify: prefix);
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'composite',
        'primary': primary.toJson(),
        if (prefixNotify != null) 'prefixNotify': prefixNotify!.toJson(),
      };
}

/// 声景轨道：来源（预置分类或指定音源 ID）+ 音量 + 循环。
class SoundscapeTrack {
  const SoundscapeTrack({
    this.presetCategory,
    this.assetId,
    this.volume = 0.6,
    this.loop = true,
  }) : assert(presetCategory != null || assetId != null);

  final String? presetCategory; // 预置库分类（如 ambient/nature）
  final String? assetId; // 指定音源 ID（优先于分类）
  final double volume;
  final bool loop;

  Map<String, dynamic> toJson() => {
        if (presetCategory != null) 'presetCategory': presetCategory,
        if (assetId != null) 'assetId': assetId,
        'volume': volume,
        'loop': loop,
      };

  /// BUG-123：两个来源都为空时**返回 null**，由 [SoundscapeAction.fromJson]
  /// 过滤掉这一轨。旧写法直接构造 —— release 下 assert 被剥离后得到一条
  /// "什么都指不到"的轨，执行期只能解析失败（且用户看不出是哪一轨的问题）。
  static SoundscapeTrack? fromJson(Map<String, dynamic> j) {
    final cat = j['presetCategory'] as String?;
    final id = j['assetId'] as String?;
    if ((cat == null || cat.isEmpty) && (id == null || id.isEmpty)) return null;
    return SoundscapeTrack(
      presetCategory: (cat == null || cat.isEmpty) ? null : cat,
      assetId: (id == null || id.isEmpty) ? null : id,
      // 音量越界会让 `AudioPlayer.setVolume` 抛错。
      volume: _clampDouble(j['volume'], 0.6, 0, 1),
      loop: j['loop'] as bool? ?? true,
    );
  }
}

/// 声景混音：最多 4 轨同时叠加，总时长到点渐出。
class SoundscapeAction extends ActionConfig {
  /// BUG-123：**只保留上界断言**。下界（≥1 轨）此前也在 assert 里，而
  /// release 下它被剥离 ⇒ 空轨声景照样落库；`fromJson` 又无法凭空造出一轨，
  /// 于是 debug 抛错、release 静默 —— 两条路行为不一致。现在允许空集，
  /// 由执行期**如实报错**（`background_engine` 的「无可解析的音轨」分支）。
  const SoundscapeAction(
      {required this.tracks, this.durationSec = 60, this.fadeOutSec = 5})
      : assert(tracks.length <= 4);

  final List<SoundscapeTrack> tracks;
  final int durationSec;
  final int fadeOutSec;

  factory SoundscapeAction.fromJson(Map<String, dynamic> j) {
    final raw = (j['tracks'] as List?) ?? const [];
    final cleaned = <SoundscapeTrack>[];
    for (final t in raw) {
      if (t is! Map) continue;
      final track = SoundscapeTrack.fromJson(t.cast<String, dynamic>());
      if (track != null) cleaned.add(track);
    }
    return SoundscapeAction(
      tracks: cleaned.length > 4 ? cleaned.sublist(0, 4) : cleaned,
      durationSec: _clampInt(j['durationSec'], 60, 1, _maxActionDurationSec),
      fadeOutSec: _clampInt(j['fadeOutSec'], 5, 0, 600),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'soundscape',
        'tracks': [for (final t in tracks) t.toJson()],
        'durationSec': durationSec,
        'fadeOutSec': fadeOutSec,
      };
}

/// 动作集候选：一个候选动作 + 选中权重（v1.8）。
class ActionSetCandidate {
  const ActionSetCandidate({required this.weight, required this.action});

  final double weight; // 选中权重（≥0；0 表示永不选中，占位用）
  final ActionConfig action;

  Map<String, dynamic> toJson() =>
      {'weight': weight, 'action': action.toJson()};

  /// BUG-123：`action` 缺失/不是 Map 时返回 null（由 [ActionSetAction.fromJson]
  /// 过滤）。旧写法 `(j['action'] as Map)` 会抛 `TypeError` ⇒ 整条任务读不出来。
  static ActionSetCandidate? fromJson(Map<String, dynamic> j) {
    final raw = j['action'];
    if (raw is! Map) return null;
    final ActionConfig inner;
    try {
      inner = ActionConfig.fromJson(raw.cast<String, dynamic>());
    } on Object {
      // 内层 kind 未知/结构损坏：丢掉这个候选而不是让整条任务报废。
      return null;
    }
    return ActionSetCandidate(
      // 权重：负数会让 `pick()` 的累计和变负 ⇒ 落到"永远选最后一个"；
      // 上界与 `TaskWire.maxActionSetWeight` 同量级（防溢出成 inf）。
      weight: _clampDouble(j['weight'], 1.0, 0, 1e6),
      action: inner,
    );
  }
}

/// **动作集（随机指令集，v1.8）**：触发命中后，按权重随机从候选动作中
/// 选**一个**执行——"到点随机播放声音中的某一个 / 随机执行某一指令"。
/// 行业对应：iOS Shortcuts 的 Choose from List + Tasker 的 Random。
class ActionSetAction extends ActionConfig {
  /// BUG-123：下界从 2 放宽到 1 —— `fromJson` 过滤后可能只剩一个，
  /// 而"只有一个候选"仍然是合法可执行的（随机性退化，不是错误）。
  /// 上界保留：超过 12 个候选会让编辑器与 UI 同时失去可用性。
  const ActionSetAction({required this.candidates})
      : assert(candidates.length >= 1, '动作集至少需要 1 个候选'),
        assert(candidates.length <= 12, '动作集最多 12 个候选');

  final List<ActionSetCandidate> candidates;

  /// **空集兜底候选**：只在配置损坏（候选全被过滤掉）时出现。
  ///
  /// 为什么不静默跳过：项目红线是"失败必须让用户知道"。一条明说原因的
  /// 通知，比"到点了什么都没发生"更容易定位问题。
  static const ActionSetCandidate fallbackCandidate = ActionSetCandidate(
    weight: 1,
    action: NotifyAction(title: '声盾', body: '动作集配置为空，本次动作已跳过'),
  );

  /// 加权随机选中一个候选（调用方注入 [rng] 以便测试）。
  ///
  /// BUG-123：空集此前会让 `Random().nextInt(0)` / `candidates.last` 抛
  /// `RangeError`（release 下 `assert` 已剥离，空集是真能构造出来的）。
  ActionSetCandidate pick(Random rng) {
    if (candidates.isEmpty) return fallbackCandidate;
    final total = candidates.fold<double>(0, (s, c) => s + c.weight);
    if (total <= 0) {
      // 全零权重：等概率兜底（配置错误时的安全行为）。
      return candidates[rng.nextInt(candidates.length)];
    }
    var roll = rng.nextDouble() * total;
    for (final c in candidates) {
      roll -= c.weight;
      if (roll <= 0) return c;
    }
    return candidates.last;
  }

  factory ActionSetAction.fromJson(Map<String, dynamic> j) {
    final raw = (j['candidates'] as List?) ?? const [];
    final cleaned = <ActionSetCandidate>[];
    for (final c in raw) {
      if (c is! Map) continue;
      final cand = ActionSetCandidate.fromJson(c.cast<String, dynamic>());
      if (cand != null) cleaned.add(cand);
    }
    return ActionSetAction(
      candidates: cleaned.isEmpty
          ? const [fallbackCandidate]
          : (cleaned.length > 12 ? cleaned.sublist(0, 12) : cleaned),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'randomFrom',
        'candidates': [for (final c in candidates) c.toJson()],
      };
}
