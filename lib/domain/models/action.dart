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

  factory PlayAudioAction.fromJson(Map<String, dynamic> j) => PlayAudioAction(
        volumeMin: (j['volumeMin'] as num? ?? 0.6).toDouble(),
        volumeMax: (j['volumeMax'] as num? ?? 1.0).toDouble(),
        durationSecMin: (j['durationSecMin'] as num? ?? 3).toInt(),
        durationSecMax: (j['durationSecMax'] as num? ?? 15).toInt(),
        fadeInSec: (j['fadeInSec'] as num? ?? 0).toInt(),
        fadeOutSec: (j['fadeOutSec'] as num? ?? 0).toInt(),
        channel: (j['channel'] as String?) == 'alarm'
            ? AudioChannel.alarm
            : AudioChannel.media,
        respectDnd: j['respectDnd'] as bool? ?? true,
        rampUpSec: (j['rampUpSec'] as num? ?? 0).toInt(),
        loopFill: j['loopFill'] as bool? ?? false,
      );

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
      this.channel = AudioChannel.media});

  final String text;
  final double volume;
  final AudioChannel channel;

  factory TtsAction.fromJson(Map<String, dynamic> j) => TtsAction(
        text: j['text'] as String? ?? '',
        volume: (j['volume'] as num? ?? 0.8).toDouble(),
        channel: (j['channel'] as String?) == 'alarm'
            ? AudioChannel.alarm
            : AudioChannel.media,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'tts', 'text': text, 'volume': volume, 'channel': channel.name};
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

  factory RecordEvidenceAction.fromJson(Map<String, dynamic> j) =>
      RecordEvidenceAction(seconds: (j['seconds'] as num? ?? 60).toInt());

  @override
  Map<String, dynamic> toJson() => {'kind': 'record', 'seconds': seconds};
}

class VibrateAction extends ActionConfig {
  const VibrateAction({this.patternMs = const [0, 300, 200, 300]});

  final List<int> patternMs;

  factory VibrateAction.fromJson(Map<String, dynamic> j) => VibrateAction(
        patternMs: (j['patternMs'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [0, 300, 200, 300],
      );

  @override
  Map<String, dynamic> toJson() => {'kind': 'vibrate', 'patternMs': patternMs};
}

/// 振动参数的**结构健全性上界**（docs/20 §10.3）。
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
    this.respectDnd = true,
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
  final bool respectDnd;

  factory RandomVibrateAction.fromJson(Map<String, dynamic> j) =>
      RandomVibrateAction(
        durationSecMin: (j['durationSecMin'] as num? ?? 3).toInt(),
        durationSecMax: (j['durationSecMax'] as num? ?? 10).toInt(),
        pulseOnMsMin: (j['pulseOnMsMin'] as num? ?? 150).toInt(),
        pulseOnMsMax: (j['pulseOnMsMax'] as num? ?? 400).toInt(),
        pulseOffMsMin: (j['pulseOffMsMin'] as num? ?? 100).toInt(),
        pulseOffMsMax: (j['pulseOffMsMax'] as num? ?? 600).toInt(),
        amplitudeMin: (j['amplitudeMin'] as num? ?? 0.4).toDouble(),
        amplitudeMax: (j['amplitudeMax'] as num? ?? 1.0).toDouble(),
        maxPulses: (j['maxPulses'] as num? ?? 200).toInt(),
        rampUpSec: (j['rampUpSec'] as num? ?? 0).toInt(),
        respectDnd: j['respectDnd'] as bool? ?? true,
      );

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
    this.respectDnd = true,
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

  final bool respectDnd;

  factory ContinuousVibrateAction.fromJson(Map<String, dynamic> j) =>
      ContinuousVibrateAction(
        durationSecMin: (j['durationSecMin'] as num? ?? 10).toInt(),
        durationSecMax: (j['durationSecMax'] as num? ?? 30).toInt(),
        amplitudeMin: (j['amplitudeMin'] as num? ?? 0.5).toDouble(),
        amplitudeMax: (j['amplitudeMax'] as num? ?? 1.0).toDouble(),
        jitterMs: (j['jitterMs'] as num? ?? 0).toInt(),
        sharpnessMin: (j['sharpnessMin'] as num? ?? 0.0).toDouble(),
        sharpnessMax: (j['sharpnessMax'] as num? ?? 0.0).toDouble(),
        dutyCyclePct: (j['dutyCyclePct'] as num? ?? 100).toInt(),
        rampUpSec: (j['rampUpSec'] as num? ?? 0).toInt(),
        rampDownSec: (j['rampDownSec'] as num? ?? 0).toInt(),
        respectDnd: j['respectDnd'] as bool? ?? true,
      );

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

  factory CompositeAction.fromJson(Map<String, dynamic> j) => CompositeAction(
        primary: ActionConfig.fromJson(j['primary'] as Map<String, dynamic>),
        prefixNotify: j['prefixNotify'] == null
            ? null
            : NotifyAction.fromJson(j['prefixNotify'] as Map<String, dynamic>),
      );

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

  static SoundscapeTrack fromJson(Map<String, dynamic> j) => SoundscapeTrack(
        presetCategory: j['presetCategory'] as String?,
        assetId: j['assetId'] as String?,
        volume: (j['volume'] as num? ?? 0.6).toDouble(),
        loop: j['loop'] as bool? ?? true,
      );
}

/// 声景混音：最多 4 轨同时叠加，总时长到点渐出。
class SoundscapeAction extends ActionConfig {
  const SoundscapeAction(
      {required this.tracks, this.durationSec = 60, this.fadeOutSec = 5})
      : assert(tracks.length >= 1 && tracks.length <= 4);

  final List<SoundscapeTrack> tracks;
  final int durationSec;
  final int fadeOutSec;

  factory SoundscapeAction.fromJson(Map<String, dynamic> j) => SoundscapeAction(
        tracks: [
          for (final t in (j['tracks'] as List?) ?? [])
            SoundscapeTrack.fromJson((t as Map).cast<String, dynamic>()),
        ],
        durationSec: (j['durationSec'] as num? ?? 60).toInt(),
        fadeOutSec: (j['fadeOutSec'] as num? ?? 5).toInt(),
      );

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

  static ActionSetCandidate fromJson(Map<String, dynamic> j) =>
      ActionSetCandidate(
        weight: (j['weight'] as num?)?.toDouble() ?? 1.0,
        action:
            ActionConfig.fromJson((j['action'] as Map).cast<String, dynamic>()),
      );
}

/// **动作集（随机指令集，v1.8）**：触发命中后，按权重随机从候选动作中
/// 选**一个**执行——"到点随机播放声音中的某一个 / 随机执行某一指令"。
/// 行业对应：iOS Shortcuts 的 Choose from List + Tasker 的 Random。
class ActionSetAction extends ActionConfig {
  const ActionSetAction({required this.candidates})
      : assert(candidates.length >= 2, '动作集至少需要 2 个候选才有随机意义'),
        assert(candidates.length <= 12, '动作集最多 12 个候选');

  final List<ActionSetCandidate> candidates;

  /// 加权随机选中一个候选（调用方注入 [rng] 以便测试）。
  ActionSetCandidate pick(Random rng) {
    final total = candidates.fold<double>(0, (s, c) => s + c.weight);
    if (total <= 0) {
      // 全零权重：等概率兜底（配置错误时的安全行为）。
      return candidates[Random().nextInt(candidates.length)];
    }
    var roll = rng.nextDouble() * total;
    for (final c in candidates) {
      roll -= c.weight;
      if (roll <= 0) return c;
    }
    return candidates.last;
  }

  factory ActionSetAction.fromJson(Map<String, dynamic> j) => ActionSetAction(
        candidates: [
          for (final c in (j['candidates'] as List?) ?? [])
            ActionSetCandidate.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'randomFrom',
        'candidates': [for (final c in candidates) c.toJson()],
      };
}
