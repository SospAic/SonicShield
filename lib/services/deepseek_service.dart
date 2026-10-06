import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/repositories/api_config_store.dart';
import '../domain/models/counter_plan.dart';
import '../domain/scheduling/counter_plan_random.dart';

/// 「一键通过 DeepSeek 生成反击计划」——**最小 token、最高可导入率**。
///
/// ## 为什么能保证"100% 可导入"
/// 三层收敛，逐层兜底：
/// 1. **输出约束**：`response_format={"type":"json_object"}` + 低 `temperature`
///    + 极简系统提示（只给固定 schema 摘要与区间约定）——从源头减少跑偏；
/// 2. **宽容解析**：[CounterPlan.fromJson] **永不抛**，脏字段回默认、越界值夹紧；
/// 3. **一次修复重试**：`validate()` 若报错，把**原始输出 + 具体错误**回灌给模型
///    让它只改 JSON；仍不合格则**如实失败**（绝不把不合格计划落库）。
///
/// token 最省的做法：单条 system + 单条 user；只在重试时追加最小增量；
/// `max_tokens` 收紧到刚好容纳一份计划。
class DeepSeekService {
  DeepSeekService({
    required http.Client client,
    required ApiConfigStore config,
  })  : _client = client,
        _config = config;

  final http.Client _client;
  final ApiConfigStore _config;

  /// 生成计划的最大重试（含首次）——1 次修复足够；再多只是烧 token。
  static const int maxAttempts = 2;

  /// 输出预算：一份计划的 JSON 约 300 token，给到 900 留余量但不放任。
  static const int maxOutputTokens = 900;

  bool get configured => _config.hasApiKey;

  /// 一键生成。失败一律**如实回报**，不返回半成品。
  Future<DeepSeekPlanResult> generatePlan({String hint = ''}) async {
    if (!configured) {
      return DeepSeekPlanResult.fail('未配置 DeepSeek API Key（请在「语音与接口」中填写）');
    }
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': _systemPrompt},
      {
        'role': 'user',
        'content': hint.trim().isEmpty
            ? '生成一份 24 小时全天候随机反击计划。'
            : hint.trim(),
      },
    ];

    var lastError = '';
    var tokensIn = 0;
    var tokensOut = 0;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final (content, err, usage) = await _chat(messages);
      tokensIn += usage.$1;
      tokensOut += usage.$2;
      if (content == null) {
        return DeepSeekPlanResult.fail(err ?? '请求失败', promptTokens: tokensIn,
            completionTokens: tokensOut);
      }
      final json = _extractJson(content);
      if (json == null) {
        lastError = '返回内容不是合法 JSON';
      } else {
        final plan = CounterPlan.fromJson(json);
        final errs = plan.validate();
        if (errs.isEmpty) {
          return DeepSeekPlanResult.ok(plan,
              message: attempt == 1 ? 'AI 计划已生成' : 'AI 计划已生成（经一次修复）',
              attempts: attempt,
              promptTokens: tokensIn,
              completionTokens: tokensOut);
        }
        lastError = errs.join('；');
      }
      if (attempt < maxAttempts) {
        messages
          ..add({'role': 'assistant', 'content': content})
          ..add({
            'role': 'user',
            'content': '上面的输出不合格：$lastError。'
                '请只输出修正后的 JSON 对象，不要解释、不要代码块。',
          });
      }
    }
    return DeepSeekPlanResult.fail('AI 生成的计划仍不合格：$lastError',
        attempts: maxAttempts,
        promptTokens: tokensIn,
        completionTokens: tokensOut);
  }

  /// 单次 Chat Completions 往返。
  ///
  /// 返回 `(正文, 错误说明, (promptTokens, completionTokens))`；
  /// 任何失败都以 `正文=null` 表达（异常不外泄，交由上层如实回报）。
  Future<(String?, String?, (int, int))> _chat(
      List<Map<String, String>> messages) async {
    try {
      final resp = await _client.post(
        Uri.parse(_config.chatCompletionsUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_config.apiKey}',
        },
        body: jsonEncode({
          'model': _config.model,
          'messages': messages,
          'temperature': 0.3,
          'max_tokens': maxOutputTokens,
          'stream': false,
          'response_format': {'type': 'json_object'},
        }),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (null, 'DeepSeek 返回 HTTP ${resp.statusCode}', (0, 0));
      }
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      if (body is! Map) return (null, 'DeepSeek 返回结构异常', (0, 0));
      final usage = body['usage'];
      final tin = usage is Map ? (usage['prompt_tokens'] as num?)?.toInt() ?? 0 : 0;
      final tout =
          usage is Map ? (usage['completion_tokens'] as num?)?.toInt() ?? 0 : 0;
      final choices = body['choices'];
      if (choices is! List || choices.isEmpty) {
        return (null, 'DeepSeek 未返回 choices', (tin, tout));
      }
      final first = choices.first;
      final msg = first is Map ? first['message'] : null;
      final content = msg is Map ? msg['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        return (null, 'DeepSeek 返回空内容', (tin, tout));
      }
      return (content, null, (tin, tout));
    } on Object catch (e) {
      return (null, 'DeepSeek 请求异常：$e', (0, 0));
    }
  }

  /// 从模型输出里抠出 JSON 对象：先直解，失败则取首 `{` 到末 `}` 再解。
  static Map<String, dynamic>? _extractJson(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    Object? decode(String s) {
      try {
        return jsonDecode(s);
      } on Object {
        return null;
      }
    }

    final direct = decode(t);
    if (direct is Map) return direct.cast<String, dynamic>();
    final i = t.indexOf('{');
    final j = t.lastIndexOf('}');
    if (i < 0 || j <= i) return null;
    final sliced = decode(t.substring(i, j + 1));
    return sliced is Map ? sliced.cast<String, dynamic>() : null;
  }

  /// 极简系统提示：固定 schema + 区间约定 + 动作白名单。
  ///
  /// 刻意**不含**多余示例与解释——每多一句都是每次请求都要付的 token。
  static final String _systemPrompt = '''
你是「声盾」随机反击计划生成器。只输出一个 JSON 对象，禁止解释与代码块。
结构（字段名必须一致）：
{"schema":"sonicshield.counterPlan/1","name":文字,"version":1,
"dayStartHour":0-23,"dayEndHour":0-23,"cooldownSec":0-86400,"respectQuietHours":true/false,
"workday":{"day":W,"night":W},"restday":{"day":W,"night":W},
"presetIds":[音效id],"ttsTexts":[中文短句],"voiceId":""}
W={"enabled":true/false,"volumeMin":0-1,"volumeMax":0-1,
"durationSecMin":1-600,"durationSecMax":1-600,"actionsPerHour":0-12}
硬性要求：至少一个 enabled=true；presetIds 与 ttsTexts 不能同时为空；
ttsTexts 每条不超过 20 字；音量/时长下限不得大于上限。
区间约定：工作日白天音量0.50-0.80、时长3-8；工作日夜0.30-0.50、3-5；
休息日白天(可关)0.50-0.80、3-8；休息日夜(可关)0.10-0.30、3-5。
presetIds 只能从此清单选择（可多选，建议3-6个）：
$_allowedPresets
''';

  static String get _allowedPresets =>
      CounterPlanRandom.annoyPresets.join(', ');
}

/// 一键生成结果。
class DeepSeekPlanResult {
  const DeepSeekPlanResult._({
    required this.ok,
    this.plan,
    required this.message,
    this.attempts = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  factory DeepSeekPlanResult.ok(CounterPlan plan,
          {required String message,
          int attempts = 1,
          int promptTokens = 0,
          int completionTokens = 0}) =>
      DeepSeekPlanResult._(
          ok: true,
          plan: plan,
          message: message,
          attempts: attempts,
          promptTokens: promptTokens,
          completionTokens: completionTokens);

  factory DeepSeekPlanResult.fail(String message,
          {int attempts = 0, int promptTokens = 0, int completionTokens = 0}) =>
      DeepSeekPlanResult._(
          ok: false,
          message: message,
          attempts: attempts,
          promptTokens: promptTokens,
          completionTokens: completionTokens);

  final bool ok;
  final CounterPlan? plan;
  final String message;
  final int attempts;

  /// 本次（含重试）累计消耗，供测试报告与"token 最省"核验。
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;
}