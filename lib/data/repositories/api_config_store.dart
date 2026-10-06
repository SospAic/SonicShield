import 'package:shared_preferences/shared_preferences.dart';

/// 外部 AI / 在线语音接口配置（本机持久化，SharedPreferences）。
///
/// ## 为什么默认全部指向公开默认值、且**不配置就不发起请求**
///
/// 本模块只服务两条**用户显式开启**的能力：
/// 1. 「一键生成反击计划」调 DeepSeek（[baseUrl] + [apiKey] + [model]）；
/// 2. 在线语音音色（含东北话）走兼容 Azure 语音的 [ttsEndpoint] + [ttsApiKey]。
///
/// 两者都**不是**默认能力：未填 Key 时相关按钮直接如实报失败，绝不偷偷发起
/// 网络请求，也不做任何静默降级以外的事 —— 与项目「要失败，但不要静默失败」
/// 的判据一致（对照 `remote_store.dart` 的 broker 配置处理）。
///
/// ## DeepSeek Key 的内置默认（开箱可用，但不写死）
///
/// 为免"装了却用不了"，[apiKey] 有一个**内置默认**（[defaultApiKey]）：
/// 编译期可用 `--dart-define=DEEPSEEK_API_KEY=...` 覆盖，运行期可在设置页
/// 「语音与接口」随时改写；两者都优先于该默认。内置默认只是**起点**，
/// 不是写死的终点 —— 任何一次显式保存都会覆盖它（含保存空串以停用）。
///
/// ## 为什么地址/模型用「空串回到默认」而不是「删键回默认」
///
/// 用户可能把地址清空以表达"用默认"，也可能从未配置。两种语义都应由 getter
/// 统一收敛成默认值 —— 调用点永远拿到一个**可直接用**的值，不需要到处写 `??`。
/// [apiKey] 区分得更细：**从未配置**（键不存在）回落 [defaultApiKey]；
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

  // ---- 在线语音（兼容 Azure Speech / 其它同类 REST 端点）----

  static const _kTtsEndpoint = 'tts_endpoint';
  static const _kTtsApiKey = 'tts_api_key';

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

  /// 在线语音完整端点（如 `https://<region>.tts.speech.microsoft.com/cognitiveservices/v1`）。
  String get ttsEndpoint => _prefs.getString(_kTtsEndpoint) ?? '';

  /// 在线语音 Key；空串 = 未配置。
  String get ttsApiKey => _prefs.getString(_kTtsApiKey) ?? '';

  /// 在线语音是否可用（端点与 Key 都已配置）。
  bool get onlineTtsConfigured =>
      ttsEndpoint.trim().isNotEmpty && ttsApiKey.trim().isNotEmpty;

  Future<void> setBaseUrl(String v) => _prefs.setString(_kBaseUrl, v.trim());

  /// 保存 Key（传空串即**停用**内置默认，回到"无 Key"）。
  Future<void> setApiKey(String v) => _prefs.setString(_kApiKey, v.trim());

  Future<void> setModel(String v) => _prefs.setString(_kModel, v.trim());

  /// 保存在线语音配置（`endpoint` 传空串即整体清除、回到"在线语音关闭"）。
  Future<void> setOnlineTts({
    required String endpoint,
    required String apiKey,
  }) async {
    await _prefs.setString(_kTtsEndpoint, endpoint.trim());
    await _prefs.setString(_kTtsApiKey, apiKey.trim());
  }

  /// 一键清除全部外部接口配置（基址/模型/Key 各自回到**内置默认**，
  /// 在线语音回到"关闭"）。
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