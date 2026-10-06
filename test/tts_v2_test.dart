import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sonic_shield/domain/models/tts_voice.dart';
import 'package:sonic_shield/services/online_tts_client.dart';
import 'package:sonic_shield/services/tts_service.dart';

/// v2.0 仿真 TTS 的三块**纯逻辑**：
/// - 音色目录（`tts_voice.dart`）：解析回落 + 系统音色匹配；
/// - 统一入口（`tts_service.dart`）：按音色选路 + 失败收敛；
/// - 在线合成（`online_tts_client.dart`）：SSML 拼装 + 合成 + 出声编排。
///
/// 平台胶水（`FlutterTts` / 临时文件 / 播放器）不在这里 —— 它们由注入的替身
/// 表达，从而这些"选哪条路、失败报什么"的判断能在宿主测试里被穷举。
void main() {
  group('TV 音色目录', () {
    test('TV-01 未知 / 空 id 一律回落默认音色（不抛）', () {
      expect(TtsVoices.byId(null).id, TtsVoices.defaultId);
      expect(TtsVoices.byId('').id, TtsVoices.defaultId);
      expect(TtsVoices.byId('  ').id, TtsVoices.defaultId);
      expect(TtsVoices.byId('不存在的音色').id, TtsVoices.defaultId);
    });

    test('TV-02 已知 id 原样解析', () {
      expect(TtsVoices.byId('az_db_male_yunbiao').onlineVoiceName,
          'zh-CN-liaoning-YunbiaoNeural');
      expect(TtsVoices.byId('az_db_male_yunbiao').dialect, TtsDialect.dongbei);
      expect(TtsVoices.byId('sys_zh_male').isOnline, isFalse);
    });

    test('TV-03 目录同时含普通话与东北话、男女各一（需求硬约束）', () {
      const voices = TtsVoices.all;
      for (final d in TtsDialect.values) {
        for (final g in TtsGender.values) {
          expect(voices.any((v) => v.dialect == d && v.gender == g), isTrue,
              reason: '缺少 ${d.label}·${g.label} 的音色');
        }
      }
      expect(TtsVoices.onlineVoices, isNotEmpty);
      expect(TtsVoices.systemVoices, isNotEmpty);
    });

    test('TV-04 音色 id 唯一（落库/传输靠它，重复会让 byId 不确定）', () {
      final ids = TtsVoices.all.map((v) => v.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('TV-05 系统音色匹配：name 命中（大小写不敏感）', () {
      final voices = <Map<String, String>>[
        {'name': 'Microsoft Huihui', 'locale': 'zh-CN'},
        {'name': 'Microsoft Yaoyao', 'locale': 'zh-CN'},
      ];
      final picked = TtsVoices.pickSystemVoice(voices, <String>['yaoyao']);
      expect(picked, {'name': 'Microsoft Yaoyao', 'locale': 'zh-CN'});
    });

    test('TV-06 系统音色匹配：locale 也能命中；关键词按顺序优先', () {
      final voices = <Map<String, String>>[
        {'name': 'A', 'locale': 'en-US'},
        {'name': 'B', 'locale': 'zh-CN'},
      ];
      expect(TtsVoices.pickSystemVoice(voices, <String>['zh-cn'])!['name'], 'B');
      // 第一个关键词无命中则看第二个
      expect(TtsVoices.pickSystemVoice(voices, <String>['nope', 'en-us'])!['name'],
          'A');
    });

    test('TV-07 系统音色匹配：匹配不到 / 畸形输入 → null（交给系统默认）', () {
      expect(TtsVoices.pickSystemVoice(null, <String>['female']), isNull);
      expect(TtsVoices.pickSystemVoice('not-a-list', <String>['female']), isNull);
      expect(TtsVoices.pickSystemVoice(<Object?>[1, 2], <String>['female']),
          isNull);
      expect(
          TtsVoices.pickSystemVoice(
              <Map<String, String>>[
                {'name': 'X', 'locale': 'zh-CN'}
              ],
              <String>['female']),
          isNull);
      // 空关键词表 = 不挑音色
      expect(TtsVoices.pickSystemVoice(<Object?>[], const <String>[]), isNull);
    });
  });

  group('TSVC 统一 TTS 入口', () {
    test('TSVC-01 空文本 → 失败，且不调用任何委托', () async {
      var called = false;
      final svc = TtsService(
        speakSystem: (t, v, m) async => called = true,
        speakOnline: (t, v, n) async {
          called = true;
          return true;
        },
      );
      final r = await svc.say('   ', voiceId: 'sys_zh_female');
      expect(r.ok, isFalse);
      expect(called, isFalse);
      expect(r.message, contains('空'));
    });

    test('TSVC-02 系统音色走离线委托，音量夹到 0..1', () async {
      double? gotVol;
      List<String>? gotMatch;
      final svc = TtsService(
        speakSystem: (t, v, m) async {
          gotVol = v;
          gotMatch = m;
        },
        speakOnline: (t, v, n) async => fail('不应走在线'),
      );
      final r = await svc.say('你好', voiceId: 'sys_zh_male', volume: 3);
      expect(r.ok, isTrue);
      expect(r.online, isFalse);
      expect(gotVol, 1.0);
      expect(gotMatch, isNotEmpty); // 系统音色带了匹配关键词
    });

    test('TSVC-03 在线音色走在线委托；委托返回 false → 失败（不假成功）', () async {
      String? gotVoice;
      final svc = TtsService(
        speakSystem: (t, v, m) async => fail('不应走系统'),
        speakOnline: (t, v, n) async {
          gotVoice = n;
          return false;
        },
      );
      final r = await svc.say('你好', voiceId: 'az_db_female_xiaobei');
      expect(gotVoice, 'zh-CN-liaoning-XiaobeiNeural');
      expect(r.ok, isFalse);
      expect(r.online, isTrue);
    });

    test('TSVC-04 委托抛错被收敛成失败结果，异常不外泄', () async {
      final sys = TtsService(
        speakSystem: (t, v, m) async => throw StateError('无引擎'),
        speakOnline: (t, v, n) async => true,
      );
      final r1 = await sys.say('你好', voiceId: 'sys_zh_female');
      expect(r1.ok, isFalse);
      expect(r1.message, contains('无引擎'));

      final on = TtsService(
        speakSystem: (t, v, m) async {},
        speakOnline: (t, v, n) async => throw StateError('网络炸了'),
      );
      final r2 = await on.say('你好', voiceId: 'az_zh_female_xiaoxiao');
      expect(r2.ok, isFalse);
      expect(r2.online, isTrue);
      expect(r2.message, contains('网络炸了'));
    });
  });

  group('OTC 在线语音客户端', () {
    test('OTC-01 SSML 拼装：XML 转义 + 空音色回落默认', () {
      final ssml = OnlineTtsClient.buildSsml(
          'A&B <C>', 'zh-CN-liaoning-XiaobeiNeural');
      expect(ssml, contains('A&amp;B &lt;C&gt;'));
      expect(ssml, contains('name="zh-CN-liaoning-XiaobeiNeural"'));
      expect(ssml, contains('xml:lang="zh-CN"'));
      expect(OnlineTtsClient.buildSsml('hi', ''),
          contains('name="zh-CN-XiaoxiaoNeural"'));
    });

    test('OTC-02 未配置（缺 Key/端点）→ null，不发请求', () async {
      var hit = 0;
      final c = OnlineTtsClient(
        client: MockClient((req) async {
          hit++;
          return http.Response('x', 200);
        }),
        endpoint: '',
        apiKey: '',
      );
      expect(c.configured, isFalse);
      expect(await c.synthesize('你好', 'v'), isNull);
      expect(hit, 0);
    });

    test('OTC-03 200 且非空体 → 音频字节；200 空体 → null', () async {
      final c = OnlineTtsClient(
        client: MockClient((req) async => http.Response.bytes(
            Uint8List.fromList(<int>[1, 2, 3]), 200)),
        endpoint: 'https://x/y',
        apiKey: 'k',
      );
      expect(await c.synthesize('你好', 'v'), <int>[1, 2, 3]);

      final empty = OnlineTtsClient(
        client: MockClient((req) async => http.Response.bytes(<int>[], 200)),
        endpoint: 'https://x/y',
        apiKey: 'k',
      );
      expect(await empty.synthesize('你好', 'v'), isNull);
    });

    test('OTC-04 请求头与 SSML 体正确送出', () async {
      late http.Request seen;
      final c = OnlineTtsClient(
        client: MockClient((req) async {
          seen = req;
          return http.Response.bytes(Uint8List.fromList(<int>[9]), 200);
        }),
        endpoint: 'https://x/y',
        apiKey: 'secret',
      );
      await c.synthesize('喊话', 'zh-CN-YunxiNeural');
      expect(seen.headers['Ocp-Apim-Subscription-Key'], 'secret');
      expect(seen.headers['X-Microsoft-OutputFormat'],
          OnlineTtsClient.outputFormat);
      expect(utf8.decode(seen.bodyBytes),
          contains('name="zh-CN-YunxiNeural"'));
    });

    test('OTC-05 非 2xx / 网络异常 / 空文本 → null（不抛）', () async {
      final bad = OnlineTtsClient(
        client: MockClient((req) async => http.Response('nope', 401)),
        endpoint: 'https://x/y',
        apiKey: 'k',
      );
      expect(await bad.synthesize('你好', 'v'), isNull);

      final boom = OnlineTtsClient(
        client: MockClient((req) async => throw StateError('offline')),
        endpoint: 'https://x/y',
        apiKey: 'k',
      );
      expect(await boom.synthesize('你好', 'v'), isNull);

      final ok = OnlineTtsClient(
        client: MockClient(
            (req) async => http.Response.bytes(<int>[1], 200)),
        endpoint: 'https://x/y',
        apiKey: 'k',
      );
      expect(await ok.synthesize('   ', 'v'), isNull);
    });
  });

  group('OTS 在线出声编排', () {
    OnlineTtsClient okClient() => OnlineTtsClient(
          client: MockClient((req) async =>
              http.Response.bytes(Uint8List.fromList(<int>[1, 2]), 200)),
          endpoint: 'https://x/y',
          apiKey: 'k',
        );

    test('OTS-01 合成成功 → 落盘 → 播放 → 清理', () async {
      final events = <String>[];
      final speaker = OnlineTtsSpeaker(
        client: okClient(),
        sink: TtsAudioSink(
          writeTemp: (b, ext) async {
            events.add('write:$ext:${b.length}');
            return '/tmp/a.$ext';
          },
          deleteTemp: (p) async => events.add('delete:$p'),
          play: (p, v) async {
            events.add('play:$p:$v');
            return true;
          },
        ),
      );
      expect(await speaker.speak('你好', 'v', 0.5), isTrue);
      expect(events, ['write:mp3:2', 'play:/tmp/a.mp3:0.5', 'delete:/tmp/a.mp3']);
    });

    test('OTS-02 合成失败 → 不落盘、不播放、不清理（不留垃圾）', () async {
      final events = <String>[];
      final speaker = OnlineTtsSpeaker(
        client: OnlineTtsClient(
          client: MockClient((req) async => http.Response('no', 500)),
          endpoint: 'https://x/y',
          apiKey: 'k',
        ),
        sink: TtsAudioSink(
          writeTemp: (b, ext) async {
            events.add('write');
            return '/tmp/a';
          },
          deleteTemp: (p) async => events.add('delete'),
          play: (p, v) async {
            events.add('play');
            return true;
          },
        ),
      );
      expect(await speaker.speak('你好', 'v', 0.5), isFalse);
      expect(events, isEmpty);
    });

    test('OTS-03 播放失败 → 返回 false 但仍清理临时文件', () async {
      final events = <String>[];
      final speaker = OnlineTtsSpeaker(
        client: okClient(),
        sink: TtsAudioSink(
          writeTemp: (b, ext) async {
            events.add('write');
            return '/tmp/a.mp3';
          },
          deleteTemp: (p) async => events.add('delete'),
          play: (p, v) async => false,
        ),
      );
      expect(await speaker.speak('你好', 'v', 0.5), isFalse);
      expect(events, ['write', 'delete']);
    });

    test('OTS-04 落盘抛错 → 返回 false，不外泄异常', () async {
      final speaker = OnlineTtsSpeaker(
        client: okClient(),
        sink: TtsAudioSink(
          writeTemp: (b, ext) async => throw StateError('磁盘满'),
          deleteTemp: (p) async {},
          play: (p, v) async => true,
        ),
      );
      expect(await speaker.speak('你好', 'v', 0.5), isFalse);
    });
  });
}