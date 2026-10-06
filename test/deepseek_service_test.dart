import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/services/deepseek_service.dart';

/// DeepSeek 一键生成的**收敛与降级**锁：
/// - 未配置 Key → 如实失败且不发请求；
/// - 合规输出 → 一次成功；脏输出 → 一次修复重试；仍脏 → 如实失败（不假成功）；
/// - 请求要点：`response_format=json_object`、低 `temperature`、Bearer 鉴权；
/// - token 统计汇总（供"最省"核验）。
http.Response _ok(String content) => http.Response.bytes(
      utf8.encode(content),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  Future<ApiConfigStore> storeWith({String key = 'sk-test'}) async {
    SharedPreferences.setMockInitialValues({'api_key': key});
    return ApiConfigStore(await SharedPreferences.getInstance());
  }

  String chatBody(String content, {int tin = 11, int tout = 22}) =>
      jsonEncode({
        'choices': [
          {
            'message': {'content': content}
          }
        ],
        'usage': {'prompt_tokens': tin, 'completion_tokens': tout},
      });

  /// 一份**合规**计划 JSON（满足全部硬性要求）。
  String goodPlanJson() => jsonEncode({
        'schema': 'sonicshield.counterPlan/1',
        'name': 'AI 反击',
        'version': 1,
        'dayStartHour': 8,
        'dayEndHour': 20,
        'cooldownSec': 900,
        'respectQuietHours': true,
        'workday': {
          'day': {
            'enabled': true,
            'volumeMin': 0.5,
            'volumeMax': 0.8,
            'durationSecMin': 3,
            'durationSecMax': 8,
            'actionsPerHour': 2,
          },
          'night': {
            'enabled': true,
            'volumeMin': 0.3,
            'volumeMax': 0.5,
            'durationSecMin': 3,
            'durationSecMax': 5,
            'actionsPerHour': 1,
          },
        },
        'restday': {
          'day': {'enabled': false},
          'night': {'enabled': false},
        },
        'presetIds': ['annoy_cough_fit', 'annoy_spit'],
        'ttsTexts': ['干啥呢？'],
        'voiceId': '',
      });

  test('DS-01 未配置 Key → 失败且不发请求', () async {
    var hits = 0;
    final svc = DeepSeekService(
      client: MockClient((r) async {
        hits++;
        return _ok(chatBody(goodPlanJson()));
      }),
      config: await storeWith(key: ''),
    );
    final r = await svc.generatePlan();
    expect(r.ok, isFalse);
    expect(r.message, contains('API Key'));
    expect(hits, 0);
    expect(svc.configured, isFalse);
  });

  test('DS-02 合规输出 → 一次成功；请求要点正确', () async {
    late http.Request seen;
    final svc = DeepSeekService(
      client: MockClient((r) async {
        seen = r;
        return _ok(chatBody(goodPlanJson()));
      }),
      config: await storeWith(),
    );
    final r = await svc.generatePlan(hint: '白天多一点');
    expect(r.ok, isTrue, reason: r.message);
    expect(r.attempts, 1);
    expect(r.plan!.schema, CounterPlan.schemaId);
    expect(r.totalTokens, 33);
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['response_format'], {'type': 'json_object'});
    expect(body['temperature'], 0.3);
    expect(body['stream'], false);
    expect(seen.headers['Authorization'], 'Bearer sk-test');
    final lastMsg = (body['messages'] as List).last as Map<String, dynamic>;
    expect(lastMsg['content'], '白天多一点');
  });

  test('DS-03 首次不合格（schema 错）→ 一次修复后成功', () async {
    var n = 0;
    final svc = DeepSeekService(
      client: MockClient((r) async {
        n++;
        if (n == 1) {
          final bad = jsonDecode(goodPlanJson()) as Map<String, dynamic>;
          bad['schema'] = 'other/9';
          return _ok(chatBody(jsonEncode(bad)));
        }
        return _ok(chatBody(goodPlanJson()));
      }),
      config: await storeWith(),
    );
    final r = await svc.generatePlan();
    expect(r.ok, isTrue, reason: r.message);
    expect(r.attempts, 2);
    expect(n, 2);
  });

  test('DS-04 非 JSON 文本 → 重试；再合法则成功', () async {
    var n = 0;
    final svc = DeepSeekService(
      client: MockClient((r) async {
        n++;
        if (n == 1) return _ok(chatBody('这是一段解释，不是 JSON'));
        return _ok(chatBody('```json\n${goodPlanJson()}\n```'));
      }),
      config: await storeWith(),
    );
    final r = await svc.generatePlan();
    expect(r.ok, isTrue, reason: r.message);
    expect(r.attempts, 2);
  });

  test('DS-05 两次都不合格 → 如实失败，不返回半成品', () async {
    final svc = DeepSeekService(
      client: MockClient((r) async {
        final bad = jsonDecode(goodPlanJson()) as Map<String, dynamic>;
        bad['schema'] = 'other/9';
        return _ok(chatBody(jsonEncode(bad)));
      }),
      config: await storeWith(),
    );
    final r = await svc.generatePlan();
    expect(r.ok, isFalse);
    expect(r.plan, isNull);
    expect(r.message, contains('不合格'));
    expect(r.attempts, DeepSeekService.maxAttempts);
  });

  test('DS-06 HTTP 500 → 失败并带状态码', () async {
    final svc = DeepSeekService(
      client: MockClient((r) async => http.Response('boom', 500)),
      config: await storeWith(),
    );
    final r = await svc.generatePlan();
    expect(r.ok, isFalse);
    expect(r.message, contains('500'));
  });

  test('DS-07 越界脏值由 fromJson 夹紧，仍可判为合规', () async {
    var n = 0;
    final svc = DeepSeekService(
      client: MockClient((r) async {
        n++;
        final j = jsonDecode(goodPlanJson()) as Map<String, dynamic>;
        // 音量 3 → 会被夹到 1；min>max 会被交换 ⇒ 仍然合规。
        (j['workday'] as Map)['day'] = {
          'enabled': true,
          'volumeMin': 3,
          'volumeMax': -1,
          'durationSecMin': 8,
          'durationSecMax': 3,
          'actionsPerHour': 999,
        };
        return _ok(chatBody(jsonEncode(j)));
      }),
      config: await storeWith(),
    );
    final r = await svc.generatePlan();
    expect(r.ok, isTrue, reason: r.message);
    expect(n, 1); // 无需重试
    final w = r.plan!.workdayDay;
    expect(w.volumeMin, 0.0);
    expect(w.volumeMax, 1.0);
    expect(w.durationSecMin, 3);
    expect(w.durationSecMax, 8);
    expect(w.actionsPerHour, CounterWindow.maxActionsPerHour);
  });
}