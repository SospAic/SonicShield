/// 仿真 TTS 音色目录（v2.0）。
///
/// ## 为什么要有"音色目录"这一层
///
/// 设备内置 TTS（`flutter_tts`）与在线语音服务的能力模型**完全不同**：
/// - 系统 TTS：能拿到什么音色取决于机型/系统里装了哪个 TTS 引擎，
///   只能**按关键词猜**（locale / voice name 子串），且**没有东北话**；
/// - 在线语音（兼容 Azure Speech）：音色由**固定 voice name** 指定，
///   含东北话（`zh-CN-liaoning-XiaobeiNeural` 等），但需要联网 + Key。
///
/// 本目录把两者统一成**同一个 [TtsVoice] 列表**：调用方只持有 [TtsVoice.id]，
/// 由 [TtsVoices.byId] 解析出"走哪条路、用什么参数"。这样本机与远程、
/// 任务动作与指令组步骤都能用**同一个音色 id**，不需要各自理解两套模型。
///
/// ## 失败方向
///
/// 未知 / 空 id 一律回落 [TtsVoices.defaultId]（系统默认普通话女声）——
/// 与项目"读不懂的配置回到最安全默认"的惯例一致（对照
/// `schedule_engine.normalizeQuietWindow`）。系统音色匹配不到时，
/// 由系统 TTS 自己选默认音色（不是错误，只是降级）。
library;

/// 方言/口音。
enum TtsDialect {
  mandarin('普通话'),
  dongbei('东北话');

  const TtsDialect(this.label);
  final String label;
}

enum TtsGender {
  female('女'),
  male('男');

  const TtsGender(this.label);
  final String label;
}

/// 音色的提供方（决定发声通路）。
enum TtsProvider {
  /// 设备内置 TTS（离线、免费；音色取决于系统）。
  system,

  /// 在线语音服务（联网 + Key；音色固定、含东北话）。
  online,

  /// 内置神经 TTS（离线、免费、自然；模型随包发布，见 [neuralVoices]）。
  /// 由 sherpa-onnx 本地合成，不依赖系统引擎、不需要联网与 Key。
  neural,
}

/// 一个可选音色。
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.name,
    required this.gender,
    required this.dialect,
    required this.provider,
    this.systemMatch = const <String>[],
    this.onlineVoiceName = '',
  });

  /// 稳定标识（落库 / 远程传输用它，不用展示名）。
  final String id;

  /// 展示名（如「小北（东北话·女·在线）」）。
  final String name;

  final TtsGender gender;
  final TtsDialect dialect;
  final TtsProvider provider;

  /// 系统 TTS 匹配关键词：在 `voice['name']` / `voice['locale']` 上做
  /// **大小写不敏感的包含**匹配。为空表示"交给系统默认音色"。
  final List<String> systemMatch;

  /// 在线音色的 voice name（如 `zh-CN-XiaoxiaoNeural`）；系统音色为空串。
  final String onlineVoiceName;

  bool get isOnline => provider == TtsProvider.online;

  /// 一句话说明（UI 副标题："普通话·女·神经" / "东北话·男·在线"）。
  String get summary {
    final kind = switch (provider) {
      TtsProvider.online => '在线',
      TtsProvider.neural => '神经',
      TtsProvider.system => '离线',
    };
    return '${dialect.label}·${gender.label}·$kind';
  }
}

abstract final class TtsVoices {
  /// 未知 id 的回落音色（系统默认普通话女声，永远可用）。
  static const String defaultId = 'sys_zh_female';

  /// **内置音色目录**。系统音色在前（离线优先），在线音色在后。
  static const List<TtsVoice> all = <TtsVoice>[
    TtsVoice(
      id: 'sys_zh_female',
      name: '系统默认女声',
      gender: TtsGender.female,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.system,
      systemMatch: <String>['female', '女', 'xiaoxiao', 'huihui'],
    ),
    TtsVoice(
      id: 'sys_zh_male',
      name: '系统默认男声',
      gender: TtsGender.male,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.system,
      systemMatch: <String>['male', '男', 'yunxi', 'kangkang'],
    ),
    TtsVoice(
      id: 'nn_zh_female',
      name: '神经女声（自然·离线）',
      gender: TtsGender.female,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.neural,
      // 神经引擎自带模型，不需要系统/在线匹配参数。
    ),
    TtsVoice(
      id: 'az_zh_female_xiaoxiao',
      name: '晓晓（温柔女声）',
      gender: TtsGender.female,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.online,
      onlineVoiceName: 'zh-CN-XiaoxiaoNeural',
    ),
    TtsVoice(
      id: 'az_zh_female_xiaoyi',
      name: '晓伊（活泼女声）',
      gender: TtsGender.female,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.online,
      onlineVoiceName: 'zh-CN-XiaoyiNeural',
    ),
    TtsVoice(
      id: 'az_zh_male_yunxi',
      name: '云希（年轻男声）',
      gender: TtsGender.male,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.online,
      onlineVoiceName: 'zh-CN-YunxiNeural',
    ),
    TtsVoice(
      id: 'az_zh_male_yunyang',
      name: '云扬（沉稳男声）',
      gender: TtsGender.male,
      dialect: TtsDialect.mandarin,
      provider: TtsProvider.online,
      onlineVoiceName: 'zh-CN-YunyangNeural',
    ),
    TtsVoice(
      id: 'az_db_female_xiaobei',
      name: '小北（东北话·女）',
      gender: TtsGender.female,
      dialect: TtsDialect.dongbei,
      provider: TtsProvider.online,
      onlineVoiceName: 'zh-CN-liaoning-XiaobeiNeural',
    ),
    TtsVoice(
      id: 'az_db_male_yunbiao',
      name: '云彪（东北话·男）',
      gender: TtsGender.male,
      dialect: TtsDialect.dongbei,
      provider: TtsProvider.online,
      onlineVoiceName: 'zh-CN-liaoning-YunbiaoNeural',
    ),
  ];

  /// 按 id 解析音色；空 / 未知一律回落 [defaultId]（不抛）。
  static TtsVoice byId(String? id) {
    final key = id?.trim() ?? '';
    for (final v in all) {
      if (v.id == key) return v;
    }
    return all.first;
  }

  /// 大小写不敏感、且**带词边界**的包含匹配：仅当 [key] 前后都不是 ASCII 字母
  /// 时才算命中。这是选男声却听到女声的根因修复 —— 系统语音名里常出现
  /// `Female` / `Male`，朴素 `contains('male')` 会把 `Female` 误中。
  static bool _hits(String text, String key) {
    var i = text.indexOf(key);
    while (i >= 0) {
      final before = i == 0 ? '' : text[i - 1];
      final after = i + key.length >= text.length ? '' : text[i + key.length];
      if (!_isAsciiLetter(before) && !_isAsciiLetter(after)) return true;
      i = text.indexOf(key, i + 1);
    }
    return false;
  }

  /// 单个字符是否为 ASCII 字母（A–Z / a–z）。中文等非 ASCII 字符一律视为
  /// "非字母"，因此中文关键词（如「男」「女」）不受词边界约束，永远按需命中。
  static bool _isAsciiLetter(String ch) {
    if (ch.isEmpty) return false;
    final c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  }

  /// 从系统 TTS 的语音列表里，挑出与 [match] **首个命中**的一条。
  ///
  /// 输入是 `FlutterTts.getVoices()` 的**原样结构**（`List<Map>`，每项含
  /// `name` / `locale`），输出可直接喂 `FlutterTts.setVoice`。这里刻意不 import
  /// `flutter_tts`：入参是 `Object?`，因此这个"怎么猜音色"的决策是**纯函数**，
  /// 宿主测试能穷举（对照 `remote_playback.PlaybackSelector` 的注入风格）。
  ///
  /// 匹配规则：对每个关键词做**大小写不敏感 + 词边界**的 `name`/`locale` 匹配，
  /// 关键词按 [match] 顺序优先。**返回 `null` = 交给系统默认音色**（不是错误，
  /// 只是降级 —— 机型上装没装对应引擎不归我们管）。
  static Map<String, String>? pickSystemVoice(Object? voices, List<String> match) {
    if (voices is! List || match.isEmpty) return null;
    for (final key in match) {
      final k = key.trim().toLowerCase();
      if (k.isEmpty) continue;
      for (final raw in voices) {
        if (raw is! Map) continue;
        final name = (raw['name'] ?? '').toString();
        final locale = (raw['locale'] ?? '').toString();
        if (name.isEmpty) continue;
        if (_hits(name.toLowerCase(), k) || _hits(locale.toLowerCase(), k)) {
          return <String, String>{'name': name, 'locale': locale};
        }
      }
    }
    return null;
  }

  /// 离线（系统）音色。
  static List<TtsVoice> get systemVoices =>
      all.where((v) => v.provider == TtsProvider.system).toList();

  /// 在线音色。
  static List<TtsVoice> get onlineVoices =>
      all.where((v) => v.provider == TtsProvider.online).toList();

  /// 内置神经 TTS 音色（离线、自然，模型随包发布）。
  static List<TtsVoice> get neuralVoices =>
      all.where((v) => v.provider == TtsProvider.neural).toList();

  /// 所有**离线**音色（系统 + 神经），用于「不需要联网」场景的优先展示。
  static List<TtsVoice> get offlineVoices =>
      all.where((v) => v.provider != TtsProvider.online).toList();
}