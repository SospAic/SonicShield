import 'package:shared_preferences/shared_preferences.dart';

/// 外部 AI / 在线语音接口配置（本机持久化，SharedPreferences）。
///
/// ## 两条能力的默认策略不同（都在"开箱可用"与"不静默"之间取平衡）
///
/// 1. 「一键生成反击计划」调 DeepSeek（[baseUrl] + [apiKey] + [model]）：
///    Key 有**内置默认**（[defaultApiKey]），出厂即可用；
/// 2. 在线语音音色（含东北话）走 [ttsEndpoint] + [ttsApiKey]：
///    **内置默认是一个免 Key 的公开端点**（[defaultTtsEndpoint]，Microsoft Edge
///    「大声朗读」），出厂即可用；也可改成 Azure 兼容 REST（那时才需要 Key）。
///
/// 两者都遵循"**要失败，但不要静默失败**"：端点/Key 被**显式清空**后，相关
/// 能力如实报失败、绝不偷偷发起网络请求（对照 `remote_store.dart` 的 broker 处理）。
///
/// ## 内置默认（开箱可用，但不写死）
///
/// 为免"装了却用不了"，DeepSeek Key 与在线语音端点各有一个**内置默认**
/// （[defaultApiKey] / [defaultTtsEndpoint]）：编译期可用 `--dart-define`
/// （`DEEPSEEK_API_KEY` / `ONLINE_TTS_ENDPOINT` / `ONLINE_TTS_API_KEY`）覆盖，
/// 运行期可在设置页「语音与接口」随时改写；两者都优先于该默认。内置默认只是
/// **起点**，不是写死的终点 —— 任何一次显式保存都会覆盖它（含保存空串以停用）。
///
/// ## 为什么地址/模型用「空串回到默认」而不是「删键回默认」
///
/// 用户可能把地址清空以表达"用默认"，也可能从未配置。两种语义都应由 getter
/// 统一收敛成默认值 —— 调用点永远拿到一个**可直接用**的值，不需要到处写 `??`。
/// [apiKey] / [ttsApiKey] 区分得更细：**从未配置**（键不存在）回落对应内置默认；
/// **显式清空**（保存了空串）表示"停用"，如实返回空串。
class ApiConfigStore {
  ApiConfigStore(this._prefs);

  final SharedPreferences _prefs;

  // ---- DeepSeek（OpenAI 兼容 Chat Completions）----

  /// DeepSeek 官方 API 基址（OpenAI 兼容，实际端点为 `{baseUrl}/chat/completions`）。
  static const defaultBaseUrl = 'https://api.deepseek.com';

  /// 默认模型（DeepSeek 通用对话模型，成本低、JSON 输出稳定）。
  static const defaultModel = 'deepseek-chat';

  /// 内置默认 Key：编译期可用 `--dart-define=DEEPSEEK_API_KEY=...` 覆盖。
  ///
  /// 这里只是**出厂默认**，不是写死的唯一来源 —— 见类文档。
  static const String _builtInApiKey = String.fromEnvironment(
    'DEEPSEEK_API_KEY',
    defaultValue: 'sk-6c623340b8804850b3e6fe68452aeeac',
  );

  /// 从未配置时使用的 DeepSeek Key（内置默认，可被 `--dart-define` 覆盖）。
  static String get defaultApiKey => _builtInApiKey;

  static const _kBaseUrl = 'api_base_url';
  static const _kApiKey = 'api_key';
  static const _kModel = 'api_model';

  // ---- 在线语音（默认免 Key；也可改用兼容 Azure Speech 的 REST 端点）----

  static const _kTtsEndpoint = 'tts_endpoint';
  static const _kTtsApiKey = 'tts_api_key';

  /// 内置默认在线语音端点：Microsoft Edge「大声朗读」公开 WebSocket（**免 Key**）。
  ///
  /// 编译器可用 `--dart-define=ONLINE_TTS_ENDPOINT=...` 覆盖。它走与 Azure 同一批
  /// 神经网络音色（含东北话），但无需账号 —— 出厂即可用（"在线语音需配置"的落点）。
  static const String _builtInTtsEndpoint = String.fromEnvironment(
    'ONLINE_TTS_ENDPOINT',
    defaultValue: 'wss://speech.platform.bing.com/consumer/speech/synthesize/'
        'readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4',
  );

  /// 内置默认在线语音 Key（Edge 端点免 Key，故默认为空串）。
  ///
  /// 编译器可用 `--dart-define=ONLINE_TTS_API_KEY=...` 覆盖（改用 Azure REST 时填）。
  static const String _builtInTtsApiKey = String.fromEnvironment(
    'ONLINE_TTS_API_KEY',
    defaultValue: '',
  );

  /// 从未配置时使用的在线语音端点（内置默认，可被 `--dart-define` 覆盖）。
  static String get defaultTtsEndpoint => _builtInTtsEndpoint;

  /// 从未配置时使用的在线语音 Key（内置默认，可被 `--dart-define` 覆盖）。
  static String get defaultTtsApiKey => _builtInTtsApiKey;

  /// API 基址；未配置时回落 [defaultBaseUrl]（去掉末尾 `/` 便于拼路径）。
  String get baseUrl => _nonEmpty(_prefs.getString(_kBaseUrl)) ?? defaultBaseUrl;

  /// API Key；**从未配置**回落 [defaultApiKey]；**显式清空**时返回空串（已停用）。
  String get apiKey {
    if (_prefs.containsKey(_kApiKey)) {
      return (_prefs.getString(_kApiKey) ?? '').trim();
    }
    return defaultApiKey.trim();
  }

  /// 模型名；未配置时回落 [defaultModel]。
  String get model => _nonEmpty(_prefs.getString(_kModel)) ?? defaultModel;

  /// 是否已配置可用的 DeepSeek Key（内置默认也算"可用"）。
  bool get hasApiKey => apiKey.isNotEmpty;

  /// Chat Completions 完整端点（拼好，调用方不再关心基址是否带尾斜杠）。
  String get chatCompletionsUrl =>
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

  /// 在线语音完整端点；**从未配置**回落 [defaultTtsEndpoint]（内置免 Key 端点）；
  /// **显式清空**时返回空串（已停用）。
  String get ttsEndpoint {
    if (_prefs.containsKey(_kTtsEndpoint)) {
      return (_prefs.getString(_kTtsEndpoint) ?? '').trim();
    }
    return defaultTtsEndpoint.trim();
  }

  /// 在线语音 Key；**从未配置**回落 [defaultTtsApiKey]；**显式清空**时返回空串。
  String get ttsApiKey {
    if (_prefs.containsKey(_kTtsApiKey)) {
      return (_prefs.getString(_kTtsApiKey) ?? '').trim();
    }
    return defaultTtsApiKey.trim();
  }

  /// 在线语音是否可用。
  ///
  /// - 端点为 `ws://` / `wss://`（含内置默认）→ **免 Key 即可用**；
  /// - 端点为 `http(s)://`（Azure 兼容 REST）→ 端点与 Key 都必须具备；
  /// - 端点为空 → 不可用（已停用）。
  bool get onlineTtsConfigured {
    final ep = ttsEndpoint.trim();
    if (ep.isEmpty) return false;
    final lower = ep.toLowerCase();
    if (lower.startsWith('ws://') || lower.startsWith('wss://')) return true;
    return ttsApiKey.trim().isNotEmpty;
  }

  Future<void> setBaseUrl(String v) => _prefs.setString(_kBaseUrl, v.trim());

  /// 保存 Key（传空串即**停用**内置默认，回到"无 Key"）。
  Future<void> setApiKey(String v) => _prefs.setString(_kApiKey, v.trim());

  Future<void> setModel(String v) => _prefs.setString(_kModel, v.trim());

  /// 保存在线语音配置（`endpoint` 传空串即整体清除、回到"在线语音关闭"）。
  ///
  /// 注意：保存后 [ttsEndpoint] / [ttsApiKey] 会带上"显式"语义 —— 传空串即停用，
  /// **不会**再回落内置默认（要恢复内置默认请用 [clearAll]）。
  Future<void> setOnlineTts({
    required String endpoint,
    required String apiKey,
  }) async {
    await _prefs.setString(_kTtsEndpoint, endpoint.trim());
    await _prefs.setString(_kTtsApiKey, apiKey.trim());
  }

  /// 一键清除全部外部接口配置（基址/模型/Key 各自回到**内置默认**，
  /// 在线语音也回到**内置默认** —— 即内置免 Key Edge 端点，出厂即可用）。
  Future<void> clearAll() async {
    await _prefs.remove(_kBaseUrl);
    await _prefs.remove(_kApiKey);
    await _prefs.remove(_kModel);
    await _prefs.remove(_kTtsEndpoint);
    await _prefs.remove(_kTtsApiKey);
  }

  static String? _nonEmpty(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}