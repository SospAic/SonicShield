/// 动作类型。
enum ActionType {
  playAudio, // 播放音频（核心）
  soundscape, // 声景混音（多轨叠加，v1.3）
  tts, // TTS 喊话（如固定提示语）
  notify, // 仅通知
  recordEvidence, // 录音取证（本地保存，带清晰标注）
  vibrate, // 震动
  composite, // 组合：主动作 + 可选的「先通知」
  ;

  String get label => switch (this) {
        ActionType.playAudio => '播放音频',
        ActionType.soundscape => '声景混音',
        ActionType.tts => '语音喊话',
        ActionType.notify => '发送通知',
        ActionType.recordEvidence => '录音取证',
        ActionType.vibrate => '震动',
        ActionType.composite => '组合动作',
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

  static ActionConfig fromJson(Map<String, dynamic> j) => switch (j['kind']) {
        'play' => PlayAudioAction.fromJson(j),
        'tts' => TtsAction.fromJson(j),
        'notify' => NotifyAction.fromJson(j),
        'record' => RecordEvidenceAction.fromJson(j),
        'vibrate' => VibrateAction.fromJson(j),
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
