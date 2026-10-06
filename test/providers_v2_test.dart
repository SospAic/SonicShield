/// `lib/core/providers.dart` 的 v2.0 覆盖测试。
///
/// ## 为什么单开一个文件
///
/// 本文件里的 provider 此前只能被"整个 ProviderScope 起页（并 override 掉
/// 数据库）"的界面用例顺带碰到，而界面用例为了避开 FakeAsync 里的真实 IO，
/// 一律把 `databaseProvider` 换掉 —— 于是这些 provider 的**装配体本身**
/// （`AppDatabase.open()`、`ApiConfigStore`、`DeepSeekService`、`TtsService`
/// 的 `speakOnline` 闭包、`CounterPlanStore/Service`）从没被执行过。
/// 这里用 `ProviderContainer` 直接把它们解析出来，锁住"接线对不对"。
///
/// ## 平台另一侧怎么给
///
/// - `SharedPreferences.setMockInitialValues`：内存实现，够用；
/// - `plugins.flutter.io/path_provider`：**打桩方法通道**（`getTemporaryDirectory`
///   的方法名就是它本身，见 `settings_screen_test.dart` 的踩坑注释）；
/// - `http`：`speakOnline` 闭包里 `http.Client()` 是**硬编码**的，注入不了替身，
///   所以用本机 `HttpServer` 当上游 —— 并且必须临时清掉 flutter_test 默认的
///   `HttpOverrides`（它会把所有请求拦成 400，本地服务根本收不到）。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';
import 'package:sonic_shield/services/deepseek_service.dart';
import 'package:sonic_shield/services/holiday_update_service.dart';
import 'package:sonic_shield/services/tts_service.dart';
import 'package:sonic_shield/services/background_service_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late Directory tmp;

  setUp(() async {
    db = await AppDatabase.open(inMemoryDatabasePath);
    tmp = Directory.systemTemp.createTempSync('sonic_providers_');
    messenger().setMockMethodCallHandler(kPathProvider, (call) async {
      if (call.method == 'getTemporaryDirectory') return tmp.path;
      return null;
    });
  });

  tearDown(() async {
    messenger().setMockMethodCallHandler(kPathProvider, null);
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 起一个只回一次注入响应的本机服务；返回它的端点 URL。
  Future<Uri> startServer(int status, List<int> body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.statusCode = status;
      if (body.isNotEmpty) req.response.add(body);
      await req.response.close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}/tts');
  }

  /// 临时放开 flutter_test 的 `HttpOverrides`，让真实 `http.Client()` 能连到
  /// 本机服务；用例结束恢复原值（不污染同文件后续用例）。
  ///
  /// ⚠️ `HttpOverrides` 的 `global` **只有 setter、没有 getter**（dart:io
  /// `_http/overrides.dart`），所以这里读 `current` 来保存原值。
  void allowRealHttp() {
    final prev = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prev);
  }

  // ───────────────── 接口配置 / DeepSeek ─────────────────

  test('PVD-01 apiConfigStoreProvider 解析出 ApiConfigStore，并如实反映已落库配置',
      () async {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://api.example.com/',
      'api_model': 'deepseek-chat',
      'api_key': 'sk-test',
      'tts_endpoint': 'https://tts.example.com/v1',
      'tts_api_key': 'tk-test',
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final store = await c.read(apiConfigStoreProvider.future);
    expect(store, isA<ApiConfigStore>());
    expect(store.apiKey, 'sk-test');
    expect(store.hasApiKey, isTrue);
    expect(store.baseUrl, 'https://api.example.com/');
    expect(store.chatCompletionsUrl,
        'https://api.example.com/chat/completions');
    expect(store.onlineTtsConfigured, isTrue, reason: '端点与 Key 都配了');
  });

  test('PVD-02 deepseekServiceProvider 解析出 DeepSeekService（装配默认 http.Client + 配置）',
      () async {
    SharedPreferences.setMockInitialValues({'api_key': 'sk-test'});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final svc = await c.read(deepseekServiceProvider.future);
    expect(svc, isA<DeepSeekService>());
    // `configured` 取自注入的 `ApiConfigStore` ⇒ 证明 cfg 真的接进来了。
    expect(svc.configured, isTrue);
  });

  test('PVD-02b 显式停用 Key → DeepSeekService.configured 为 false（不误报可用）',
      () async {
    // 出厂带内置默认 Key；要落到"不可用"必须**显式清空**（保存空串）。
    SharedPreferences.setMockInitialValues({'api_key': ''});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final svc = await c.read(deepseekServiceProvider.future);
    expect(svc.configured, isFalse);
  });

  // ───────────────── TtsService / speakOnline 闭包 ─────────────────

  test('PVD-03 ttsServiceProvider 解析出 TtsService；显式关闭在线语音 → speakOnline 直接 false',
      () async {
    // 出厂默认是内置免 Key 端点（可用）；这里**显式清空端点**以表达"关闭"，
    // 闭包据此立刻 false、不发任何请求。
    SharedPreferences.setMockInitialValues({'tts_endpoint': ''});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final svc = await c.read(ttsServiceProvider.future);
    expect(svc, isA<TtsService>());

    final ok = await svc.speakOnline('你好', 0.8, 'zh-CN-XiaoxiaoNeural');
    expect(ok, isFalse, reason: '显式关闭在线语音时必须直接返回 false（不偷偷联网）');
  });

  test('PVD-03b 出厂默认（空 SharedPreferences）→ 在线语音即 configured（内置免 Key 端点）',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final store = await c.read(apiConfigStoreProvider.future);
    expect(store.onlineTtsConfigured, isTrue,
        reason: '出厂内置免 Key Edge 端点，开箱即可用（"在线语音需配置"的落点）');
    expect(store.ttsEndpoint, startsWith('wss://'));
  });

  test('PVD-04 已配置在线语音 + 上游非 200 → speakOnline 走失败分支返回 false',
      () async {
    allowRealHttp();
    final url = await startServer(500, const []);
    SharedPreferences.setMockInitialValues({
      'tts_endpoint': url.toString(),
      'tts_api_key': 'tk',
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final svc = await c.read(ttsServiceProvider.future);
    final ok = await svc
        .speakOnline('你好', 0.8, 'zh-CN-XiaoxiaoNeural')
        .timeout(const Duration(seconds: 20));
    expect(ok, isFalse, reason: '非 2xx 合成失败，不得假成功');
    // 合成失败不写任何临时文件（不讲垃圾）。
    expect(tmp.listSync().where((e) => e.path.contains('tts_')), isEmpty,
        reason: '合成失败不应落临时文件');
  });

  // ───────────────── 反击计划 store / service ─────────────────

  test('PVD-06 counterPlanStore/ServiceProvider 解析出对象（复用 in-memory DB 契约）',
      () async {
    SharedPreferences.setMockInitialValues({'counter_plan_enabled': false});
    final c = ProviderContainer(overrides: [
      // 与界面用例同源：把数据库换成 setUp 里开好的内存库。
      databaseProvider.overrideWith((ref) async => db),
    ]);
    addTearDown(c.dispose);

    final store = await c.read(counterPlanStoreProvider.future);
    expect(store, isA<CounterPlanStore>());
    expect(store.enabled, isFalse, reason: '默认关');

    // 这一条会顺带解析 taskRepoProvider / assetRepoProvider（都挂在同一 DB 上）。
    final svc = await c.read(counterPlanServiceProvider.future);
    expect(svc, isA<CounterPlanService>());
    expect(svc.currentPlan(), isNull, reason: '未配置 → 无计划');
    expect(svc.planId, CounterPlanStore.defaultPlanId);
  });

  test('PVD-07 holidayUpdateServiceProvider 解析出服务；counterPlanService 的注入闭包真的生效',
      () async {
    // holidayUpdateServiceProvider 的工厂体（providers.dart:127–129）。
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final holiday = await c.read(holidayUpdateServiceProvider.future);
    expect(holiday, isA<HolidayUpdateService>());

    // counterPlanServiceProvider 的 `resolveAudioIds` / `replan` 闭包
    // （providers.dart:140–142）只有在真的调用一次 apply 时才会执行。
    // replan 会走 BackgroundServiceManager（宿主无原生实现会抛），用测试缝短路。
    BackgroundServiceManager.replanHook = () async {};
    addTearDown(() => BackgroundServiceManager.replanHook = null);

    final c2 = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => db),
    ]);
    addTearDown(c2.dispose);
    final svc = await c2.read(counterPlanServiceProvider.future);
    // 只用 TTS 文案：默认音源库为空也能生成任务 ⇒ 一路走到 _replan()。
    final plan = CounterPlan.defaults().copyWith(
      presetIds: const [],
      ttsTexts: const ['干啥呢？'],
    );
    final r = await svc.apply(plan, now: DateTime(2026, 3, 10), days: 3);
    expect(r.ok, isTrue, reason: r.message);
    expect(svc.enabled, isTrue);
  });
}