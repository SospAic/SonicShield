/// R88 覆盖率长尾补齐：`lib/core/providers.dart` 的在线语音装配闭包 +
/// `lib/features/remote/script_builder_screen.dart` 的预置位显示/取消分支。
///
/// ## 本文件覆盖的未覆盖行（R87 lcov）
/// - `lib/core/providers.dart` 73-78 / 80-81 / 87：
///   `ttsServiceProvider.speakOnline` 里 `TtsAudioSink` 的
///   `writeTemp`（落临时文件）/ `deleteTemp`（清理）/ `play(...).ok`。
///   此前只测到"合成失败 → 不落盘"（`providers_v2_test.dart` PVD-04），
///   成功路径的这三个闭包一行都没跑过。
/// - `script_builder_screen.dart` 480：预置位文案超 10 字时的截断显示。
/// - `script_builder_screen.dart` 572：自定义预置位对话框的「取消」。
///
/// ## 如实登记：结构性不可达（不硬凑）
/// - `script_builder_screen.dart` 100 / 110：`_initialEditText` / `_editLabelOf`
///   的 `RcStepKind.vibrate` 分支。两者都只被 `_editStep` 的**文本对话框**
///   调用，而 `_editStep` 在第 118-125 行对 vibrate **提前 return**（走专用
///   振动对话框）⇒ 这两个 switch 臂永远取不到 vibrate 值。且二者是私有类的
///   `static` 方法，外部库无法直接调用。
/// - `script_builder_screen.dart` 163 / 173：`_editStep` 里写回 `params` 的
///   switch 中的 `tts` / `vibrate` 臂。tts 在第 129-149 行提前 return、
///   vibrate 在第 118-125 行提前 return ⇒ 两个臂是**为 switch 穷尽性保留**的
///   死代码。
/// - `script_builder_screen.dart` 200-204：`_send({saveFirst = true})` 的
///   「先存模板再发」分支。全仓 `saveFirst` 只出现在本页，唯一调用点是
///   `onPressed: _send`（无参）⇒ 恒假（`script_builder_screen_test.dart`
///   文件头第 3 条已登记，docs/17 §50）。
///
/// ## 平台另一侧怎么给
/// - `path_provider`：打桩方法通道（`getTemporaryDirectory`），指到用例自建的
///   临时目录 —— 这样才能断言"写进去又被删掉"。
/// - `http`：`speakOnline` 闭包里 `http.Client()` 是硬编码的，注入不了替身，
///   所以用本机 `HttpServer` 当上游（与 `providers_v2_test.dart` 同法），
///   并临时清掉 flutter_test 默认的 `HttpOverrides`（它会把请求拦成 400）。
/// - `just_audio`：用 `test/support/just_audio_stub.dart` 的平台替身，
///   否则 `AudioPlayer` 在宿主上会挂起而不是报错。
///
/// 本文件无 DB 读写（不涉及 `databaseProvider`），因此不需要 `runAsync`。
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/features/remote/script_builder_screen.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/services/remote_tts_presets.dart';

import 'support/just_audio_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // ───────────────── providers.dart：在线语音 sink 三件套 ─────────────────

  group('R88S providers.dart 在线语音装配闭包', () {
    late Directory tmp;
    final audio = FakeJustAudio(fileDuration: const Duration(milliseconds: 40));

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('r88s_tts_');
      messenger().setMockMethodCallHandler(kPathProvider, (call) async {
        if (call.method == 'getTemporaryDirectory') return tmp.path;
        return null;
      });
      audio.install();
    });

    tearDown(() {
      audio.uninstall();
      messenger().setMockMethodCallHandler(kPathProvider, null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('R88S-01 合成成功 → writeTemp 落盘、play 播该 mp3、deleteTemp 清理'
        '（覆盖 providers.dart 73-78 / 80-81 / 87）', () async {
      // flutter_test 默认的 HttpOverrides 会把所有请求拦成 400，本机服务
      // 根本收不到 —— 与 providers_v2_test.dart 同法临时放开。
      final prev = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prev);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 200;
        // 非空音频体：OnlineTtsSpeaker 拿到字节才会去写临时文件。
        req.response.add(const <int>[0x49, 0x44, 0x33, 0x04]);
        await req.response.close();
      });

      SharedPreferences.setMockInitialValues({
        // 明文 http 只有回环/私网才被 buildOnlineTtsClient 接受（BUG-132）。
        'tts_endpoint': 'http://127.0.0.1:${server.port}/tts',
        'tts_api_key': 'tk-r88',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final svc = await container.read(ttsServiceProvider.future);
      final ok = await svc
          .speakOnline('你好', 0.7, 'zh-CN-XiaoxiaoNeural')
          .timeout(const Duration(seconds: 20));

      expect(ok, isTrue, reason: '200 + 非空音频 + 播放成功 → 必须如实返回 true');

      // writeTemp（73-78）真的按 `${tmp}/tts_<微秒>.mp3` 落盘并交给播放器。
      expect(audio.loadedUris, hasLength(1), reason: '播放器必须收到一个文件');
      expect(audio.loadedUris.single, contains('tts_'),
          reason: '播放器收到的路径必须来自 writeTemp 的 tts_<微秒>.<ext> 命名');
      expect(audio.loadedUris.single, endsWith('.mp3'),
          reason: '扩展名来自 OnlineTtsSpeaker 的 writeTemp(bytes, "mp3")');
      expect(audio.volumes.last, closeTo(0.7, 1e-9),
          reason: '音量必须透传到播放器');

      // deleteTemp（80-81）：播放结束（含异常）后临时文件不得残留。
      expect(tmp.listSync().where((e) => e.path.contains('tts_')), isEmpty,
          reason: '在线语音不得在缓存目录留垃圾');
    });
  });

  // ───────────────── script_builder_screen.dart：预置位 ─────────────────

  group('R88S script_builder 预置位显示与取消', () {
    const longPreset = '请立即到一楼大厅集合，重复，请立即到一楼大厅集合';
    final presets = <String>[longPreset, '音量调小', '该休息了', '有情况', '收到'];

    /// 预置位文案超过 10 字时，chip 上显示 `前 10 字…`。
    final truncated = '${longPreset.substring(0, 10)}…';

    Future<SharedPreferences> pumpBuilder(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await RemoteTtsPresets.write(prefs, presets);
      final store = RemoteStore(prefs);
      await store.addPaired(PairedEndpoint(
        deviceId: 'devA',
        name: '客厅音箱',
        secret: 'AB2CD5EF',
        pairedAt: DateTime.now(),
      ));

      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(
              home: ScriptBuilderScreen(endpointId: 'devA'))));
      await tester.pumpAndSettle();
      return prefs;
    }

    /// 加一条语音播报并打开它的编辑对话框。
    Future<void> openTtsDialog(WidgetTester tester) async {
      final chip = find.widgetWithText(ActionChip, '语音播报');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '播报「请注意，声盾远程指令」'));
      await tester.pumpAndSettle();
    }

    String dialogText(WidgetTester tester) => tester
        .widget<TextField>(find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)))
        .controller!
        .text;

    testWidgets('R88S-02 超 10 字预置位：chip 截断显示，点入仍是全文'
        '（覆盖 480）', (tester) async {
      await pumpBuilder(tester);
      await openTtsDialog(tester);

      expect(find.widgetWithText(ActionChip, truncated), findsOneWidget,
          reason: '超 10 字必须截断显示（否则 chip 撑破一行）');
      // 截断只发生在显示层：整段长文案此时不该出现在任何 Text/EditableText 里。
      expect(find.text(longPreset), findsNothing);

      await tester.tap(find.widgetWithText(ActionChip, truncated));
      await tester.pumpAndSettle();
      expect(dialogText(tester), longPreset,
          reason: '点预置位必须填入**全文**，截断的只是标签');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('R88S-03 自定义预置位对话框「取消」：关闭且不落库'
        '（覆盖 572）', (tester) async {
      final prefs = await pumpBuilder(tester);
      await openTtsDialog(tester);

      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      final presetsDlg = find.widgetWithText(AlertDialog, '自定义预置位');
      expect(presetsDlg, findsOneWidget);

      await tester.tap(
          find.descendant(of: presetsDlg, matching: find.text('取消')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, '自定义预置位'), findsNothing,
          reason: '取消必须关掉预置位对话框');
      expect(find.widgetWithText(AlertDialog, '编辑步骤 · 语音播报'),
          findsOneWidget,
          reason: '取消只关子对话框，不能把编辑对话框一起关掉');
      expect(RemoteTtsPresets.read(prefs), presets,
          reason: '取消不得改写已落库的预置位');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  });
}
