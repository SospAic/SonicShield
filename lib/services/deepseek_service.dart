import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/repositories/api_config_store.dart';
import '../domain/models/counter_plan.dart';
import '../domain/models/counter_plan_params.dart';
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
  ///
  /// [params] 非空 ⇒ 用**用户调好的生成参数**替换系统提示里的区间约定，并把
  /// 参数说明拼进 user 消息 —— 于是 AI 与本机随机落在同一组约束里（产物可互相
  /// 导入）。[hint] 非空时**优先**当作额外要求（在参数说明之后追加）。
  Future<DeepSeekPlanResult> generatePlan({
    String hint = '',
    CounterPlanParams? params,
  }) async {
    if (!configured) {
      return DeepSeekPlanResult.fail('未配置 DeepSeek API Key（请在「语音与接口」中填写）');
    }
    final sys = params == null ? _systemPrompt : _systemPromptFor(params);
    final fromParams = params?.toPromptHint() ?? '';
    final user = <String>[
      if (fromParams.isNotEmpty) fromParams,
      if (hint.trim().isNotEmpty) hint.trim(),
      if (fromParams.isEmpty && hint.trim().isEmpty)
        '生成一份 24 小时全天候随机反击计划。',
    ].join('\n');
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': sys},
      {'role': 'user', 'content': user},
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
"presetIds":[音效id],"ttsTexts":[中文短句],"voiceId":"",
"scheduleMode":"recurringRandom","occurrenceCount":3,"spanDays":3,
"specificDate":null,"rangeStart":null,"rangeEnd":null,"weekdays":[1,2,3,4,5,6,7]}
W={"enabled":true/false,"volumeMin":0-1,"volumeMax":0-1,
"durationSecMin":1-600,"durationSecMax":1-600,"actionsPerHour":0-12,
"ttsWeight":0-1,"vibrateWeight":0-1,"vibrateAmplitudeMin":0-1,"vibrateAmplitudeMax":0-1}
硬性要求：至少一个 enabled=true；presetIds 与 ttsTexts 不能同时为空；
ttsTexts 每条不超过 20 字；音量/时长下限不得大于上限；ttsWeight+vibrateWeight≤1。
ttsWeight/vibrateWeight 是**动作配比**：该时段每次反击选 TTS / 震动的概率，其余为音效。
昼夜导向（必须遵守）：白天(6-21时)**尽量不喊话**——白天窗口 ttsWeight=0、
vibrateWeight≈0.2、音量0.70-1.00（大量大音量噪音为主）、震动强度0.80-1.00（少量高强度震动）；
夜间 ttsWeight≈0.6（以说烦人的话为主）、vibrateWeight≈0.3（震动配合）、
音量0.10-0.30（轻幅度噪音）、震动强度0.40-0.80。
区间约定：工作日白天音量0.70-1.00、时长3-8、配比(音效0/TTS0/震动0.2)；
工作日夜0.10-0.30、3-5、配比(0.1/0.6/0.3)；休息日白天(可关)0.70-1.00、3-8、配比(0/0/0.2)；
休息日夜(可关)0.10-0.30、3-5、配比(0.1/0.6/0.3)。
排期：默认 scheduleMode="recurringRandom"（周一至周日循环随机）。
presetIds 只能从此清单选择（可多选，建议3-6个）：
$_allowedPresets
''';

  /// 参数化系统提示：结构不变，只把「区间约定」换成用户调好的参数区间。
  ///
  /// 与 [_systemPrompt] 同口径（同样极简、不做解释），差别仅在区间来源 ——
  /// 这样"用户把工作日夜间音量区间调宽"能**真的传给模型**，而不是嘴上说说。
  static String _systemPromptFor(CounterPlanParams p) {
    String w(PlanWindowParams x) => x.enabled
        ? '音量${x.volumeMin.toStringAsFixed(2)}-${x.volumeMax.toStringAsFixed(2)}、'
            '时长${x.durationSecMin}-${x.durationSecMax}、'
            '每小时${x.actionsPerHourMin}-${x.actionsPerHourMax}、'
            '配比(音效${x.audioWeight.toStringAsFixed(2)}/'
            'TTS${x.ttsWeight.toStringAsFixed(2)}/震动${x.vibrateWeight.toStringAsFixed(2)})、'
            '震动强度${x.vibrateAmplitudeMin.toStringAsFixed(2)}-'
            '${x.vibrateAmplitudeMax.toStringAsFixed(2)}'
        : 'enabled=false（不反击）';
    return '''
你是「声盾」随机反击计划生成器。只输出一个 JSON 对象，禁止解释与代码块。
结构（字段名必须一致）：
{"schema":"sonicshield.counterPlan/1","name":文字,"version":1,
"dayStartHour":0-23,"dayEndHour":0-23,"cooldownSec":0-86400,"respectQuietHours":true/false,
"workday":{"day":W,"night":W},"restday":{"day":W,"night":W},
"presetIds":[音效id],"ttsTexts":[中文短句],"voiceId":"",
"scheduleMode":"single|several|severalDays|specificDate|dateRange|recurringRandom",
"occurrenceCount":1-96,"spanDays":1-92,"specificDate":"yyyy-MM-dd或null",
"rangeStart":"yyyy-MM-dd或null","rangeEnd":"yyyy-MM-dd或null","weekdays":[1-7]}
W={"enabled":true/false,"volumeMin":0-1,"volumeMax":0-1,
"durationSecMin":1-600,"durationSecMax":1-600,"actionsPerHour":0-12,
"ttsWeight":0-1,"vibrateWeight":0-1,"vibrateAmplitudeMin":0-1,"vibrateAmplitudeMax":0-1}
硬性要求：至少一个 enabled=true；presetIds 与 ttsTexts 不能同时为空；
ttsTexts 每条不超过 20 字；音量/时长下限不得大于上限；ttsWeight+vibrateWeight≤1。
ttsWeight/vibrateWeight 是**动作配比**：该时段每次反击选 TTS / 震动的概率，其余为音效。
昼夜导向（必须遵守）：白天(${p.dayStartHour}-${p.dayEndHour}时)**尽量不喊话**（ttsWeight=0）；
夜间以 TTS 说烦人的话为主 + 震动配合 + 轻幅度噪音。
区间约定（**必须落在下列区间内**）：
工作日白天(${w(p.workdayDay)})；工作日夜(${w(p.workdayNight)})；
休息日白天(${w(p.restdayDay)})；休息日夜(${w(p.restdayNight)})；
动作间隔 ${p.cooldownSecMin}-${p.cooldownSecMax} 秒；白天 ${p.dayStartHour}-${p.dayEndHour} 时。
排期要求（**原样回填**）：${p.scheduleSummary()}；
单次/指定日期用 specificDate，区间用 rangeStart/rangeEnd，循环随机用 weekdays（1=周一…7=周日）。
presetIds 只能从此清单选择（可多选，建议3-6个）：
$_allowedPresets
''';
  }

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