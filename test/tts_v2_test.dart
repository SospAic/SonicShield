import 'dart:convert';
import 'dart:io';
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

    test('TV-08 ★ 性别边界匹配：female 名里的 male 不再误中（选男声听女声的根因）', () {
      // 系统语音名常出现 Female/Male：「Microsoft Female」含子串 male，
      // 朴素 contains('male') 会误中它。边界匹配应只挑真正的 Male 语音。
      final voices = <Map<String, String>>[
        {'name': 'Microsoft Female', 'locale': 'zh-CN'},
        {'name': 'Microsoft Male', 'locale': 'zh-CN'},
      ];
      expect(TtsVoices.pickSystemVoice(voices, <String>['male'])!['name'],
          'Microsoft Male');
      // 反向：选女声命中 Female，不受 Male 同名子串干扰。
      expect(TtsVoices.pickSystemVoice(voices, <String>['female'])!['name'],
          'Microsoft Female');
      // 中文关键词不受词边界约束：'男' 仍正常命中。
      final zh = <Map<String, String>>[
        {'name': '中文女声', 'locale': 'zh-CN'},
        {'name': '中文男声', 'locale': 'zh-CN'},
      ];
      expect(TtsVoices.pickSystemVoice(zh, <String>['男'])!['name'], '中文男声');
      // Android 系统音色名形如 `zh-cn-x-ccc#female_1-local` / `#male_1-local`，
      // 同样验证分隔符边界下 male/female 不互串。
      final sep = <Map<String, String>>[
        {'name': 'zh-cn-x-ccc#female_1-local', 'locale': 'zh-CN'},
        {'name': 'zh-cn-x-ccc#male_1-local', 'locale': 'zh-CN'},
      ];
      expect(TtsVoices.pickSystemVoice(sep, <String>['male', '男'])!['name'],
          'zh-cn-x-ccc#male_1-local');
      expect(TtsVoices.pickSystemVoice(sep, <String>['female', '女'])!['name'],
          'zh-cn-x-ccc#female_1-local');
    });

    test('TV-09 边界规则不误伤：词首/词尾/分隔符边界仍命中；CJK 按包含匹配', () {
      // 词首：'male_1' 在名字开头
      expect(
          TtsVoices.pickSystemVoice(<Map<String, String>>[
            {'name': 'male_1', 'locale': 'zh-CN'},
          ], <String>['male'])!['name'],
          'male_1');
      // 分隔符两侧：'#male_1-local'
      expect(
          TtsVoices.pickSystemVoice(<Map<String, String>>[
            {'name': 'x#male-local', 'locale': 'zh-CN'},
          ], <String>['male'])!['name'],
          'x#male-local');
      // CJK 关键词不含 ASCII 字母 ⇒ 退化为包含匹配
      expect(
          TtsVoices.pickSystemVoice(<Map<String, String>>[
            {'name': '女声引擎', 'locale': 'zh-CN'},
          ], <String>['女'])!['name'],
          '女声引擎');
      // 'female' 整体仍可命中（它自己的边界是合法的）
      expect(
          TtsVoices.pickSystemVoice(<Map<String, String>>[
            {'name': 'x#female_1-local', 'locale': 'zh-CN'},
          ], <String>['female'])!['name'],
          'x#female_1-local');
    });

    test('TV-10 neural 提供方与离线聚合', () {
      expect(TtsVoices.neuralVoices, isNotEmpty);
      expect(TtsVoices.neuralVoices.first.provider, TtsProvider.neural);
      expect(
        TtsVoices.offlineVoices,
        containsAll(
            <Object>[...TtsVoices.systemVoices, ...TtsVoices.neuralVoices]),
      );
      expect(TtsVoices.byId('nn_zh_female').summary, contains('神经'));
    });

    test('TV-11 summary 覆盖三种通路（离线/在线/神经）', () {
      expect(TtsVoices.byId('sys_zh_female').summary, '普通话·女·离线');
      expect(TtsVoices.byId('az_zh_female_xiaoxiao').summary, '普通话·女·在线');
      expect(TtsVoices.byId('nn_zh_female').summary, '普通话·女·神经');
    });
  });

  group('TSVC 统一 TTS 入口', () {
    test('TSVC-01 空文本 → 失败，且不调用任何委托', () async {
      var called = false;
      final svc = TtsService(
        speakSystem: (t, v, m) async => called = true,
        speakNeural: (t, v) async => false,
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
        speakNeural: (t, v) async => false,
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
        speakNeural: (t, v) async => false,
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
        speakNeural: (t, v) async => false,
        speakOnline: (t, v, n) async => true,
      );
      final r1 = await sys.say('你好', voiceId: 'sys_zh_female');
      expect(r1.ok, isFalse);
      expect(r1.message, contains('无引擎'));

      final on = TtsService(
        speakSystem: (t, v, m) async {},
        speakNeural: (t, v) async => false,
        speakOnline: (t, v, n) async => throw StateError('网络炸了'),
      );
      final r2 = await on.say('你好', voiceId: 'az_zh_female_xiaoxiao');
      expect(r2.ok, isFalse);
      expect(r2.online, isTrue);
      expect(r2.message, contains('网络炸了'));
    });
  });

  group('TSVC-N 神经 TTS 路由', () {
    test('TSVC-N-01 neural 音色走 speakNeural；发声成功 → ok', () async {
      var called = false;
      final svc = TtsService(
        speakSystem: (t, v, m) async => fail('不应走系统'),
        speakNeural: (t, v) async {
          called = true;
          return true;
        },
        speakOnline: (t, v, n) async => fail('不应走在线'),
      );
      final r = await svc.say('你好', voiceId: 'nn_zh_female', volume: 0.7);
      expect(r.ok, isTrue);
      expect(r.online, isFalse);
      expect(called, isTrue);
    });

    test('TSVC-N-02 neural 发声失败 → 优雅回落系统默认音色（ok，不报错）', () async {
      var fellBack = false;
      final svc = TtsService(
        speakSystem: (t, v, m) async {
          // 回落时不应挑具体音色（match 为空 = 系统默认音色）。
          expect(m, isEmpty);
          fellBack = true;
        },
        speakNeural: (t, v) async => false,
        speakOnline: (t, v, n) async => fail('不应走在线'),
      );
      final r = await svc.say('你好', voiceId: 'nn_zh_female');
      expect(fellBack, isTrue);
      expect(r.ok, isTrue);
      expect(r.message, contains('回落'));
    });

    test('TSVC-N-03 neural 委托抛错 → 失败结果，异常不外泄', () async {
      final svc = TtsService(
        speakSystem: (t, v, m) async {},
        speakNeural: (t, v) async => throw StateError('引擎炸了'),
        speakOnline: (t, v, n) async => true,
      );
      final r = await svc.say('你好', voiceId: 'nn_zh_female');
      expect(r.ok, isFalse);
      expect(r.message, contains('引擎炸了'));
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

  group('EDGE Edge「大声朗读」免 Key 通路', () {
    Uint8List binFrame(String path, List<int> payload) {
      final header = utf8.encode('Path:$path\r\n');
      final out = BytesBuilder();
      out.add(<int>[(header.length >> 8) & 0xff, header.length & 0xff]);
      out.add(header);
      out.add(payload);
      return out.toBytes();
    }

    test('EDGE-01 协议：先 config 后 ssml；收 Path:audio 音频；turn.end 结束并关连接',
        () async {
      final frame = binFrame('audio', <int>[1, 2, 3]);
      final socket = _FakeEdgeSocket(<Object?>[
        'X-RequestId:x\r\nPath:turn.start\r\n\r\n{"context":{}}',
        frame,
        'X-RequestId:x\r\nPath:turn.end\r\n\r\n',
      ]);
      final c = EdgeTtsClient(
        endpoint: 'wss://edge.example/v1',
        connector: (url, {headers}) async {
          expect(url.toString(), 'wss://edge.example/v1');
          return socket;
        },
        requestId: 'abc123',
      );
      expect(c.configured, isTrue);
      final bytes = await c.synthesize('你好', 'zh-CN-liaoning-XiaobeiNeural');
      expect(bytes, <int>[1, 2, 3]);

      expect(socket.sent, hasLength(2), reason: '只发 config + ssml 两帧');
      expect(socket.sent[0], contains('Path:speech.config'));
      expect(socket.sent[0], contains('X-RequestId:abc123'));
      expect(socket.sent[0], contains(EdgeTtsClient.outputFormat));
      expect(socket.sent[1], contains('Path:ssml'));
      expect(socket.sent[1], contains('name="zh-CN-liaoning-XiaobeiNeural"'));
      expect(socket.closed, isTrue, reason: '合成后必须关连接');
    });

    test('EDGE-02 非 audio 二进制帧被忽略；只有非音频帧 → null', () async {
      final c = EdgeTtsClient(
        endpoint: 'wss://edge.example/v1',
        connector: (url, {headers}) async => _FakeEdgeSocket(<Object?>[
              binFrame('response', <int>[9, 9]),
              'Path:turn.end\r\n\r\n',
            ]),
      );
      expect(await c.synthesize('你好', 'v'), isNull);
    });

    test('EDGE-03 未收到 turn.end（对端异常关闭）→ null（不播残缺音频）', () async {
      final c = EdgeTtsClient(
        endpoint: 'wss://edge.example/v1',
        connector: (url, {headers}) async =>
            _FakeEdgeSocket(<Object?>[binFrame('audio', <int>[1, 2])]),
      );
      expect(await c.synthesize('你好', 'v'), isNull);
    });

    test('EDGE-04 端点为空 / 文本为空 → null，不建连', () async {
      var connected = 0;
      final ep = EdgeTtsClient(
        endpoint: '  ',
        connector: (url, {headers}) async {
          connected++;
          return _FakeEdgeSocket(<Object?>[]);
        },
      );
      expect(ep.configured, isFalse);
      expect(await ep.synthesize('你好', 'v'), isNull);

      final txt = EdgeTtsClient(
        endpoint: 'wss://edge.example/v1',
        connector: (url, {headers}) async {
          connected++;
          return _FakeEdgeSocket(<Object?>[]);
        },
      );
      expect(await txt.synthesize('   ', 'v'), isNull);
      expect(connected, 0, reason: '未配置/空文本不应发起连接');
    });

    test('EDGE-05 建连抛错 → null（不外泄异常），且 close 安全', () async {
      final c = EdgeTtsClient(
        endpoint: 'wss://edge.example/v1',
        connector: (url, {headers}) async => throw StateError('offline'),
      );
      expect(await c.synthesize('你好', 'v'), isNull);
      c.close(); // 无资源，安全空操作
    });

    test('EDGE-06 audioPayload 边界：帧过短 / header 越界 → null', () {
      expect(EdgeTtsClient.audioPayload(Uint8List.fromList(<int>[1])), isNull);
      expect(
        EdgeTtsClient.audioPayload(Uint8List.fromList(<int>[0, 200, 1, 2])),
        isNull,
        reason: '声明 header 长 200 但实际不足 → null',
      );
      final ok = binFrame('audio', <int>[7, 8]);
      expect(EdgeTtsClient.audioPayload(ok), <int>[7, 8]);
    });

    test('EDGE-07 newRequestId 为 32 位十六进制', () {
      final id = EdgeTtsClient.newRequestId();
      expect(id, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id), isTrue);
    });
  });

  group('BOTC buildOnlineTtsClient 选通路', () {
    test('BOTC-01 空端点 → null（未配置）', () {
      expect(buildOnlineTtsClient(endpoint: '', apiKey: ''), isNull);
      expect(buildOnlineTtsClient(endpoint: '   ', apiKey: 'k'), isNull);
    });

    test('BOTC-02 ws/wss → EdgeTtsClient（免 Key）', () {
      expect(
        buildOnlineTtsClient(
            endpoint: 'wss://edge.example/v1', apiKey: ''),
        isA<EdgeTtsClient>(),
      );
      expect(
        buildOnlineTtsClient(endpoint: 'WS://edge.example/v1', apiKey: ''),
        isA<EdgeTtsClient>(),
      );
    });

    test('BOTC-03 http(s) → OnlineTtsClient，且必须有 Key', () {
      final c = buildOnlineTtsClient(
        endpoint: 'https://r.tts.example/v1',
        apiKey: 'k',
      );
      expect(c, isA<OnlineTtsClient>());
      expect(
        buildOnlineTtsClient(endpoint: 'https://r.tts.example/v1', apiKey: ''),
        isNull,
        reason: 'REST 端点缺 Key → 不可用',
      );
    });

    test('BOTC-04 未知协议 → null', () {
      expect(
        buildOnlineTtsClient(endpoint: 'ftp://x/y', apiKey: 'k'),
        isNull,
      );
    });
  });

  group('EDGE-IO 生产连接器 defaultEdgeSocketConnector / _IoEdgeSocket', () {
    test('EDGE-IO-01 真连本机 WebSocket：stream/add/close 全通路可用（150–174）',
        () async {
      // flutter_test 默认的 HttpOverrides 会把请求拦成 400 ⇒ 要先放开，
      // 让 dart:io 的 WebSocket.connect 能连到本机服务。
      final prev = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prev);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = <String>[];
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((data) {
          if (data is String) {
            received.add(data);
            ws.add('echo:$data'); // 回一帧，验证 stream 真的可达
          }
        });
      });

      final socket = await defaultEdgeSocketConnector(
          Uri.parse('ws://127.0.0.1:${server.port}'));
      expect(socket, isA<EdgeSocket>());

      final frames = <Object?>[];
      final sub = socket.stream.listen(frames.add);
      socket.add('hello'); // 覆盖 _IoEdgeSocket.add
      for (var i = 0; i < 100 && frames.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received, contains('hello'));
      expect(frames, contains('echo:hello'),
          reason: 'WebSocket 双向都必须真的通 —— 只发不收等于连接器是坏的');

      await sub.cancel();
      await socket.close(); // 覆盖 _IoEdgeSocket.close
    });
  });
}

/// 假 Edge WebSocket：预置收帧序列、记录发送帧与是否关闭。
class _FakeEdgeSocket implements EdgeSocket {
  _FakeEdgeSocket(this._frames);

  final List<Object?> _frames;
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Stream<Object?> get stream => Stream<Object?>.fromIterable(_frames);

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() async => closed = true;
}