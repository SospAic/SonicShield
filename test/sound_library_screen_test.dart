import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, MethodChannel, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/features/sounds/sound_library_screen.dart';
import 'package:sonic_shield/services/playback_service.dart';

/// 音源库页（`SoundLibraryScreen`）的宿主测试。
///
/// ## 一、为什么不能直接 `await tester.runAsync(回调)`
///
/// `testWidgets` 的用例体跑在 `FakeAsync` 里，而本页的链需要**真实**文件 I/O
/// （`File.copy` / `length` / `delete` / `writeAsBytes`）。直觉写法
/// `await tester.runAsync(() => cb())` 会**死锁** —— 实测三条链全挂，
/// 且挂死后**后面的用例也一起报超时**（`runAsync` 重入被拒）。
///
/// 根因在框架的驱动循环（`flutter_test/src/binding.dart` 的 `runTest`）：
///
/// ```dart
/// fakeAsync.flushMicrotasks();
/// while (_pendingAsyncTasks != null) {      // 只在 runAsync 在飞时
///   await _pendingAsyncTasks!.future;
///   fakeAsync.flushMicrotasks();            // ← fake 微任务只在"段与段之间"排空
/// }
/// ```
///
/// 也就是说：**一次 `runAsync` 在飞的过程中，fake 微任务队列完全没人排空**。
/// 而 Riverpod 的容器（在 `pumpWidget` 时建于 fake zone）等组件会往 fake 队列
/// 里塞微任务 ⇒ 链一旦需要它们，`await` 就永远不返回。
/// 实测证据：把 `cb()` 用 `.timeout()` 掐断后，**链条在超时之后反而继续跑**
/// （`upsertMany` 在测试已经判失败之后才被调用）。
///
/// ## 二、可行写法：**分段驱动**（本文件 [runReal]）
///
/// 1. 第一段 `runAsync` 只**启动**链（`unawaited`，不等它结束）→ 立刻返回；
/// 2. 之后每轮做两件事，链就往前走一段：
///    * `runAsync(() async => await Future<void>.delayed(Duration.zero))`
///      —— 真实 Timer ⇒ **强制真实事件循环转一圈**，dart:io 的完成回调才送得进来；
///    * `tester.pump()` —— **排空 fake 微任务队列**。
///
/// 少了前者：真实 I/O 落盘了但 await 不恢复（实测 675 轮零进展）。
/// 少了后者：纯异步段就走不完。
/// 两个都带上：**含真实 I/O 的整条链 5 轮走完**（实测）。
///
/// ## 三、资源通道打桩（`flutter/assets`）
///
/// `TestDefaultBinaryMessenger` 一旦给 `flutter/assets` 注册了 mock handler，
/// `send()` 就**不再转发给真实实现**（`test_default_binary_messenger.dart` 的
/// `send()`：handler 命中则不走 delegate）。于是 `rootBundle.load*` 变成
/// "由我们应答"的普通 Future，可以完全控制预置清单与音频资源的内容。
///
/// ⚠️ handler 返回 `null` **不是**"交回默认实现"，而是"响应为 null" ——
/// `PlatformAssetBundle.load` 会抛 `FlutterError`（"The asset does not exist or
/// has empty data."）。这正是"资源缺失"用例要的语义，但**别指望它回落**。
///
/// ⚠️ `rootBundle` 是**全局单例**的 `CachingAssetBundle`，`loadString` / `load`
/// 的缓存**跨用例存活** —— 每条用例都必须在 `setUp` 里 `rootBundle.clear()`，
/// 否则第一条预置用例读到的清单会被后面所有用例复用（症状：`manifestLoads`
/// 恒为 0，断言看到的是上一条的内容）。
///
/// ## 四、其他坑
///
/// * **`runAsync` 不能包着 `tester.tap`**（嵌套 `TestAsyncUtils.guard` 抛
///   Guarded function conflict）。所以需要真实 I/O 的用例改成**取出按钮的
///   `onPressed` 回调、交给 [runReal] 驱动**。这不是绕过被测逻辑 —— 它测的
///   正是回调里的异步链；点击的命中测试由 SLB-01..03 / SLB-18 覆盖。
/// * **一个用例挂死会级联**：本文件里第一条挂死的用例会让**后面所有**用例
///   也报超时。看到"多条一起超时"先怀疑第一条，别逐条改断言。
/// * **不要用 `debugPrint` 做探针打印**：它的节流 Timer 会被留在 fake zone 里，
///   之后的打印全部丢失，会把你引到错误的行号上（这个坑本文件踩过）。
/// * `find.byType(FilledButton)` 与 `byWidgetPredicate((w) => w is FilledButton)`
///   在 3.47.3 上**等价**（`FilledButton.tonalIcon` 是普通构造器，
///   `runtimeType == FilledButton`，非私有子类）。本文件用后者，是为了对
///   "以后换成子类实现 / 再加一个 FilledButton"更稳，不是因为前者匹配不到。
const _timeout = Timeout(Duration(seconds: 90));

/// 预置库清单在资源通道上的 key（页面里写死的那一个）。
const _manifestKey = 'assets/audio/presets_manifest.json';

/// 假文件选择器（`file_picker` 的官方注入点，**不引入新依赖**）。
class _FakePicker extends FilePicker {
  FilePickerResult? result;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    return result;
  }
}

/// 内存版音源仓储。
///
/// **为什么不用真 `AssetRepository`**：它把查询交给 `databaseFactoryFfi`，
/// 而 FFI 把 SQLite 放在**后台 isolate** —— 查/写库在 `FakeAsync` 里
/// **一样挂死**（见技能 `flutter-widget-test-harness`）。本文件要测的是
/// **界面怎么用仓储**（批量写一次、失败回滚、按 id 删），SQL 本身由仓储层
/// 自己的测试覆盖。
class _FakeRepo implements AssetRepository {
  _FakeRepo([List<AudioAsset>? seed]) : items = [...?seed];

  final List<AudioAsset> items;

  /// 非 null 时 `upsertMany` 抛出它（模拟写库失败）。
  Object? failOnSaveAll;

  /// `upsertMany` 被调用的次数 —— 断言"**一次**批量写"（BUG-047 的原子性）。
  int saveAllCalls = 0;

  /// `listAll` 被调用的次数 —— P2-24：断言无关 `setState` 不会重复全量查询。
  int listAllCalls = 0;

  final List<String> deletedIds = [];

  @override
  Future<List<AudioAsset>> listAll() async {
    listAllCalls++;
    return List.of(items);
  }

  @override
  Future<Set<String>> nameSet() async => items.map((a) => a.name).toSet();

  @override
  Future<void> upsert(AudioAsset a) async {
    items.removeWhere((x) => x.id == a.id);
    items.add(a);
  }

  @override
  Future<void> upsertMany(Iterable<AudioAsset> batch) async {
    saveAllCalls++;
    final f = failOnSaveAll;
    if (f != null) throw f;
    for (final a in batch) {
      items.removeWhere((x) => x.id == a.id);
      items.add(a);
    }
  }

  @override
  Future<void> delete(String id) async {
    deletedIds.add(id);
    items.removeWhere((x) => x.id == id);
  }

  /// DAT-16：事务内判重 + 插入。内存版按 `name` 去重（与真实实现同语义：
  /// 已落库的名字跳过，同批内同名只取第一条）。
  @override
  Future<({int inserted, int skipped})> insertMissingByName(
      Iterable<AudioAsset> batch) async {
    final present = items.map((a) => a.name).toSet();
    final seen = <String>{};
    var inserted = 0;
    var skipped = 0;
    for (final a in batch) {
      if (present.contains(a.name) || !seen.add(a.name)) {
        skipped++;
        continue;
      }
      items.add(a);
      seen.add(a.name);
      inserted++;
    }
    return (inserted: inserted, skipped: skipped);
  }
}

/// 假播放器。
///
/// 用 `extends` 而不是 `implements`：`PlaybackService` 还有
/// `stopSoundscape` / `playSoundscape` 等成员，`extends` 只需覆盖要观测的
/// 那几个，其余继承 —— 也就不会因为基类新增方法而**编译报错**。
/// 这里要的是"测试听逻辑"，不是"锁播放器 API"。
class _FakePlayer extends PlaybackService {
  final played = <String>[];
  int stops = 0;
  bool disposed = false;

  /// 非 null 时 `play` 挂在这里 —— 用来观察"播放中"的界面状态。
  Completer<void>? gate;

  /// 非 null 时 `play` 抛出它 —— 驱动"试听失败必须可见且复位"的兜底分支
  /// （文件被清理 / 编解码不支持）。
  Object? throwOnPlay;

  @override
  Future<PlayResult> play({
    required String path,
    required AudioChannel channel,
    required double volume,
    required int maxDurationMs,
    int fadeInMs = 0,
    int fadeOutMs = 0,
    int rampUpMs = 0,
    bool loopFill = false,
    PlayPriority priority = PlayPriority.normal,
  }) async {
    played.add(path);
    final t = throwOnPlay;
    if (t != null) throw t;
    final g = gate;
    if (g != null) await g.future;
    return const PlayResult(ok: true, playedMs: 10);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp; // 假的「应用文档目录」
  late Directory src; // 本地导入的源文件目录
  late _FakePicker picker;
  late _FakeRepo repo;
  late _FakePlayer player;

  /// 清单内容的替身。`null` = 资源缺失（读清单会抛 `FlutterError`）。
  String? fakeManifest;

  /// 非 null 时，`assets/audio/**` 的读取返回这么多字节的合成数据；
  /// `null` = 资源缺失（读音频会抛 `FlutterError`）。
  int? fakeAudioBytes;

  /// 清单 / 音频各被读了几次 —— 用来断言"导入进行中不重入"、
  /// 以及"幂等跳过时根本不读音频"。
  int manifestLoads = 0;
  int audioLoads = 0;

  /// 非 null 时，**读清单会卡在这里**。
  ///
  /// 用来稳定观察"导入进行中"的界面：mock 的清单读取本身在一个微任务里就
  /// 完成了，而 `pump()` 是**先排空微任务、再绘制帧** —— 不等一帧的话，
  /// 看到的时候状态早就复位了（实测：`onPressed` 已经非 null）。
  Completer<void>? manifestGate;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sonic_slb_');
    src = Directory('${tmp.path}/src')..createSync();
    picker = _FakePicker();
    FilePicker.platform = picker;
    repo = _FakeRepo();
    player = _FakePlayer();
    fakeManifest = null;
    fakeAudioBytes = null;
    manifestLoads = 0;
    audioLoads = 0;
    manifestGate = null;

    // ⚠️ **必须清缓存**：`rootBundle` 是全局单例的 `CachingAssetBundle`，
    // `loadString` / `load` 的缓存**跨用例存活**。不清的话，第一条预置用例
    // 读到的内容会被后面所有用例复用 —— 症状是 `manifestLoads` 恒为 0、
    // 断言看到的是上一条的清单（实测踩过：SLB-13..17 一起红）。
    rootBundle.clear();

    messenger().setMockMethodCallHandler(kPathProvider, (call) async {
      // ⚠️ 方法名是**通道上的**名字：`getApplicationDocumentsDirectory`
      // （平台接口层叫 `getApplicationDocumentsPath`）。
      if (call.method == 'getApplicationDocumentsDirectory') return tmp.path;
      if (call.method == 'getTemporaryDirectory') return tmp.path;
      return null;
    });

    // 接管资源通道：本页要读的只有清单与预置音频两类。
    // 返回 `null` = 该资源不存在（页面会看到 `FlutterError`）。
    messenger().setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode((message as ByteData).buffer.asUint8List());
      if (key == _manifestKey) {
        manifestLoads++;
        final gate = manifestGate;
        if (gate != null) await gate.future;
        final m = fakeManifest;
        if (m == null) return null;
        return _bytes(utf8.encode(m));
      }
      if (key.startsWith('assets/audio/')) {
        audioLoads++;
        final n = fakeAudioBytes;
        if (n == null) return null;
        return _bytes(List<int>.filled(n, 7));
      }
      return null;
    });
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(kPathProvider, null);
    messenger().setMockMessageHandler('flutter/assets', null);
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Windows 上偶发"文件被占用"——夹具清理失败不该让用例红。
      }
    }
  });

  // ───────────────────────────── 夹具 ─────────────────────────────

  AudioAsset asset({
    required String id,
    required String name,
    String? path,
    int sizeBytes = 2048,
    List<String> tags = const [],
  }) =>
      AudioAsset(
        id: id,
        name: name,
        path: path ?? '${tmp.path}/$id.wav',
        sizeBytes: sizeBytes,
        tags: tags,
        createdAt: DateTime(2026, 9, 22),
      );

  /// 建一个源文件，返回它的 `PlatformFile`。
  PlatformFile source(String name, {int bytes = 8}) {
    final f = File('${src.path}/$name')
      ..writeAsBytesSync(List<int>.filled(bytes, 7));
    return PlatformFile(name: name, path: f.path, size: bytes);
  }

  /// 预置清单里的一条。
  Map<String, Object> preset({
    required String id,
    required String category,
    required String name,
    int durationMs = 500,
  }) =>
      {
        'id': id,
        'category': category,
        'name': name,
        'file': 'presets/$id.wav',
        'durationMs': durationMs,
      };

  String manifestOf(List<Map<String, Object>> items) =>
      jsonEncode({'items': items});

  /// 文档目录里本次导入落下的文件（按文件名）。
  ///
  /// ⚠️ 按 `[\\/]` 切，不能写 `split('/')` —— Windows 上路径是反斜杠，
  /// 那样会整条路径当一个"文件名"，断言就变成恒真/恒假。
  List<String> audioFiles() => tmp
      .listSync()
      .whereType<File>()
      .map((f) => f.path.split(RegExp(r'[\\/]')).last)
      .where((n) => n.startsWith('audio_'))
      .toList();

  Future<void> pumpLib(
    WidgetTester tester, {
    bool embedded = false,
    bool confirmDelete = false,
    List<AudioAsset>? seed,
  }) async {
    if (seed != null) repo.items.addAll(seed);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [assetRepoProvider.overrideWith((ref) async => repo)],
      child: MaterialApp(
        home: SoundLibraryScreen(
              embedded: embedded,
              previewPlayer: player,
              confirmDelete: confirmDelete),
      ),
    ));
    // 第一帧：FutureBuilder 还没拿到仓储 → 空态；
    // 冲两次微任务后拿到列表（P2-24 后 `_listAssets()` 只在 initState 建一次，
    // 与旧实现"每次 build 都新建 Future"不同 —— 见 SLB-25）。
    await tester.pump();
    await tester.pump();
  }

  /// 取「导入预置库」按钮。
  ///
  /// ⚠️ 用 `byWidgetPredicate` 而不是 `byType(FilledButton)`：本页只有一个
  /// FilledButton，两者**都能命中**；但 `byType` 比的是**精确 runtimeType**，
  /// 一旦以后把按钮换成 `FilledButton.icon` 的子类实现（或页面里再加一个
  /// FilledButton）就会静默失配 —— 用谓词是**对未来改动更稳**的写法。
  /// （2026-09-22 实测：3.47.3 的 `FilledButton.tonalIcon` 是普通构造器，
  /// `runtimeType == FilledButton`，故两种写法等价。）
  FilledButton presetsButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.byWidgetPredicate((w) => w is FilledButton).first);

  /// `onPressed` 的静态类型是 `VoidCallback`（`void Function()`），
  /// 但页面挂上去的是 `Future<void> Function()`。要把它**原样**交给
  /// [runReal] 等待，就得转回来（`Future<void> <: void`，合法的向下转型）。
  Future<void> Function() awaitable(VoidCallback? cb) =>
      cb! as Future<void> Function();

  /// 取「导入音频」FAB 上的回调（见 [awaitable]）。
  Future<void> Function() importCallback(WidgetTester tester) => awaitable(
      tester.widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed);

  /// 取「导入预置库」按钮上的回调（见 [awaitable]）。
  Future<void> Function() presetsCallback(WidgetTester tester) =>
      awaitable(presetsButton(tester).onPressed);

  /// 取第一条记录的「删除」回调（见 [awaitable]）。
  Future<void> Function() deleteCallback(WidgetTester tester) => awaitable(
      tester
          .widget<IconButton>(find
              .ancestor(
                  of: find.byTooltip('删除'),
                  matching: find.byType(IconButton))
              .first)
          .onPressed);

  /// **分段驱动**一条需要真实文件 I/O 的链（机制见文件头 §二）。
  ///
  /// 超时会**显式失败**而不是静默放行 —— 否则"链没跑完"会伪装成"断言通过"。
  Future<void> runReal(WidgetTester tester, Future<void> Function() body) async {
    var done = false;
    Object? error;
    StackTrace? stack;

    // 段 1：只启动，不等它结束。
    await tester.runAsync(() async {
      unawaited(body().then<void>((_) {
        done = true;
      }, onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      }));
    });

    // 段 2..N：真实转一圈 + 排空 fake 微任务。
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }
    if (!done) {
      fail('runReal 超时：链在 20s 内没走完（zone 死锁？见文件头 §二）');
    }
    if (error != null) {
      Error.throwWithStackTrace(error!, stack!);
    }
    // 让 `setState` 后的重建与 FutureBuilder 的重读落地。
    //
    // ⚠️ P2-24 后刷新用的新 future 是在 **body 的 real zone** 里创建的
    // （`_reloadAssets()` 在异步链尾调用），它的续体挂在**真实**微任务队列上,
    // 而收尾的 fake `pump()` **排不到**它 —— 必须先真实转一圈（同循环体）
    // 再 pump，新数据才会落到 widget 树。
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
    }
  }

  /// 排空 SnackBar 队列（每条 4 秒）与页面自己的兜底 Timer。
  Future<void> drainSnacks(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // SLB-A · 渲染
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('SLB-01 空态：说清"两条路都能导入"，且点名 70 条 / 13 分类',
      (tester) async {
    await pumpLib(tester);

    expect(find.text('暂无音源。'), findsOneWidget);
    expect(find.textContaining('导入预置库'), findsWidgets);
    // v2.0 阶段 A：新增 `annoy`（招人烦）分类 → 60/12 抬到 70/13。
    expect(find.textContaining('70 条内置音效'), findsOneWidget);
    expect(find.textContaining('敲击/撞击/拖拽/门窗'), findsOneWidget,
        reason: '分类清单是"这里到底有什么"的唯一说明，别删');
  }, timeout: _timeout);

  testWidgets('SLB-02 列表渲染：大小取 KB、tags 空与非空两种拼法', (tester) async {
    await pumpLib(tester, seed: [
      asset(id: 'a', name: '无标签', sizeBytes: 2048),
      asset(id: 'b', name: '有标签', sizeBytes: 3072, tags: ['预置', 'knocks']),
    ]);

    expect(find.text('无标签'), findsOneWidget);
    expect(find.text('有标签'), findsOneWidget);
    // 2048 / 1024 = 2 KB；3072 / 1024 = 3 KB（整除，不是四舍五入）
    expect(find.text('2 KB'), findsOneWidget);
    expect(find.text('3 KB · 预置/knocks'), findsOneWidget);
    expect(find.text('3 KB'), findsNothing,
        reason: '有标签时必须拼上 ` · a/b`，不能只显示大小');
  }, timeout: _timeout);

  testWidgets('SLB-03 embedded 只影响标题，不影响「导入预置库」可达性',
      (tester) async {
    // 这条锁的是一条**产品判断**：作为分组子 TAB 时必须保留「导入预置库」，
    // 否则新 IA 下这个能力**不可达**（页面注释里写明了）。
    await pumpLib(tester, embedded: true);
    expect(find.text('音源库'), findsNothing, reason: 'embedded 不该再显示标题');
    expect(find.text('导入预置库'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pumpLib(tester);
    expect(find.text('音源库'), findsOneWidget);
    expect(find.text('导入预置库'), findsOneWidget);
  }, timeout: _timeout);

  // ══════════════════════════════════════════════════════════════════════
  // SLB-B · 试听（靠 `previewPlayer` 注入缝）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('SLB-04 点试听 → 立刻变「停止」，播完自己复位', (tester) async {
    await pumpLib(tester, seed: [asset(id: 'a', name: 'A')]);
    player.gate = Completer<void>();

    await tester.tap(find.byTooltip('试听'));
    await tester.pump();

    expect(player.played, ['${tmp.path}/a.wav']);
    // 关键：`_previewingId` 在 `await play()` **之前**就设上了，
    // 所以播放期间图标必须是"停止"（否则用户会以为没反应、反复点）。
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);

    player.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
  }, timeout: _timeout);

  testWidgets('SLB-05 播放中再点同一条 → 停止，且**不再**发起播放', (tester) async {
    await pumpLib(tester, seed: [asset(id: 'a', name: 'A')]);
    player.gate = Completer<void>();

    await tester.tap(find.byTooltip('试听'));
    await tester.pump();
    expect(player.played.length, 1);

    await tester.tap(find.byTooltip('试听'));
    await tester.pump();

    expect(player.stops, 1, reason: '第二条命令必须先把上一条停掉');
    expect(player.played.length, 1,
        reason: '同一条再点 = "停止"，不是"重播" —— 再播一次会让人以为按钮坏了');
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
  }, timeout: _timeout);

  testWidgets('SLB-06 播放中点另一条 → 先停旧的，再播新的', (tester) async {
    await pumpLib(tester, seed: [
      asset(id: 'a', name: 'A'),
      asset(id: 'b', name: 'B'),
    ]);
    player.gate = Completer<void>();

    await tester.tap(find.byTooltip('试听').first);
    await tester.pump();
    expect(player.played, ['${tmp.path}/a.wav']);

    await tester.tap(find.byTooltip('试听').last);
    await tester.pump();

    expect(player.stops, 1);
    expect(player.played, ['${tmp.path}/a.wav', '${tmp.path}/b.wav']);

    player.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.stop), findsNothing);
  }, timeout: _timeout);

  testWidgets('SLB-23 试听失败（文件被清理/编解码不支持）→ 提示可见且图标复位',
      (tester) async {
    await pumpLib(tester, seed: [asset(id: 'a', name: 'A')]);
    player.throwOnPlay = StateError('Decoder init failed');

    await tester.tap(find.byTooltip('试听'));
    await tester.pump();
    await tester.pump();

    // 失败必须可见：否则用户只看到"点了没反应"，会反复点。
    expect(find.textContaining('试听失败'), findsOneWidget,
        reason: '播放失败要给可读原因，不能静默吞掉');
    // 且必须复位 —— 否则图标永远停在"停止"，再点走的是"停止"分支，
    // 表现为"这条音源再也试听不了"。
    expect(find.byIcon(Icons.play_arrow), findsOneWidget,
        reason: '失败后必须复位到"可试听"，否则该条永远点不动');
    expect(find.byIcon(Icons.stop), findsNothing);
    expect(tester.takeException(), isNull);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-25 [P2-24] 试听等无关 setState 不重查库；改库后才重查一次',
      (tester) async {
    await pumpLib(tester, seed: [asset(id: 'a', name: 'A')]);
    expect(repo.listAllCalls, 1, reason: '首帧只应查一次列表');

    // 试听只改 `_previewingId`，与列表无关 —— 必须复用已完成的 future。
    player.gate = Completer<void>();
    await tester.tap(find.byTooltip('试听'));
    await tester.pump();
    expect(repo.listAllCalls, 1,
        reason: '★ 旧实现把 `_listAssets()` 建在 build 内：每次试听 setState 都会重查 DB'
            '并解码 tags；列表 Future 必须在无关状态变化时复用（P2-24）');

    player.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(repo.listAllCalls, 1, reason: '播放完成后的复位同样不该重查');

    // 删除会改变库内容 → 必须换新 future，重查一次。
    await runReal(tester, deleteCallback(tester));
    expect(repo.deletedIds, ['a']);
    expect(repo.listAllCalls, 2,
        reason: '库内容变化（删除）后必须重查一次，否则列表看不到变化');
    expect(find.text('A'), findsNothing);
  }, timeout: _timeout);

  // ══════════════════════════════════════════════════════════════════════
  // SLB-C · 本地导入（分段驱动）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('SLB-07 用户取消选择 → 什么都不发生（不写库、不提示）',
      (tester) async {
    await pumpLib(tester);
    picker.result = null;

    await runReal(tester, importCallback(tester));

    expect(picker.calls, 1);
    expect(repo.saveAllCalls, 0);
    expect(find.byType(SnackBar), findsNothing);
  }, timeout: _timeout);

  testWidgets('SLB-08 选中 0 个文件 → 同样不写库（不是"导入完成：新增 0 条"）',
      (tester) async {
    await pumpLib(tester);
    picker.result = const FilePickerResult([]);

    await runReal(tester, importCallback(tester));

    expect(repo.saveAllCalls, 0);
    expect(find.byType(SnackBar), findsNothing);
  }, timeout: _timeout);

  testWidgets('SLB-09 正常导入 2 个文件：复制到私有目录 + **一次**批量写库 + 提示',
      (tester) async {
    await pumpLib(tester);
    picker.result = FilePickerResult([
      source('a.mp3', bytes: 11),
      source('b.wav', bytes: 22),
    ]);

    await runReal(tester, importCallback(tester));

    expect(repo.saveAllCalls, 1,
        reason: '批量导入必须**一次**写库（BUG-047：逐条写会留下半套库）');
    expect(repo.items.length, 2);
    // 落盘证据：扩展名保留、字节数来自目标文件本身（不是源文件的 size 字段）
    final paths = repo.items.map((a) => a.path).toList();
    expect(paths.any((p) => p.endsWith('.mp3')), isTrue);
    expect(paths.any((p) => p.endsWith('.wav')), isTrue);
    expect(repo.items.map((a) => a.sizeBytes), everyElement(greaterThan(0)));
    for (final p in paths) {
      expect(File(p).existsSync(), isTrue, reason: '$p 应该已经落盘');
      expect(p.startsWith(tmp.path), isTrue, reason: '必须落在应用私有目录里');
    }
    expect(find.text('导入完成：新增 2 条'), findsOneWidget);
    // 列表跟着刷新（setState 后重新拉了一次）
    expect(find.text('a.mp3'), findsOneWidget);
    expect(find.text('b.wav'), findsOneWidget);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-10 没有扩展名 → `.bin`；path 为 null 的条目被跳过',
      (tester) async {
    await pumpLib(tester);
    picker.result = FilePickerResult([
      source('noext'),
      PlatformFile(name: 'ghost', path: null, size: 0),
      source('c.flac'),
    ]);

    await runReal(tester, importCallback(tester));

    expect(repo.items.length, 2,
        reason: 'path == null 的条目没有来源，必须丢掉而不是落一条坏记录');
    final names =
        repo.items.map((a) => a.path.split(RegExp(r'[\\/]')).last).toList();
    expect(names.any((n) => n.endsWith('.bin')), isTrue,
        reason: '无扩展名要给 `.bin` 兜底，不能把名字直接当扩展名');
    expect(names.any((n) => n.endsWith('.flac')), isTrue);
    expect(find.text('导入完成：新增 2 条'), findsOneWidget);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-11 写库失败 → 已落盘文件被回滚，提示"已回滚，库内无残留"',
      (tester) async {
    await pumpLib(tester);
    picker.result = FilePickerResult([source('a.mp3'), source('b.mp3')]);
    repo.failOnSaveAll = StateError('磁盘满了');

    await runReal(tester, importCallback(tester));

    expect(repo.items, isEmpty, reason: '库内必须零新增');
    expect(repo.saveAllCalls, 1);
    expect(audioFiles(), isEmpty, reason: '写库失败后必须把本次落盘的文件删掉（不留孤儿）');
    expect(find.textContaining('导入失败（已回滚，库内无残留）'), findsOneWidget);

    await drainSnacks(tester);
  }, timeout: _timeout);

  // ══════════════════════════════════════════════════════════════════════
  // SLB-D · 预置库导入（资源通道已打桩，整条链可测）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('SLB-12 清单为空 → 走完流程、提示"新增 0 条"、状态复位',
      (tester) async {
    await pumpLib(tester);
    fakeManifest = manifestOf([]);

    await runReal(tester, presetsCallback(tester));

    expect(manifestLoads, 1);
    expect(repo.saveAllCalls, 0,
        reason: '空清单不该产生任何数据库操作（连空事务都不开）');
    expect(find.textContaining('预置音效导入完成：新增 0 条'), findsOneWidget);
    expect(find.textContaining('库内共 0 条'), findsOneWidget);
    // `finally` 必须把状态复位，否则按钮永久禁用
    expect(presetsButton(tester).onPressed, isNotNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-13 清单非法 → 明说失败，且**状态复位**（按钮不能永久禁用）',
      (tester) async {
    await pumpLib(tester);
    fakeManifest = '{ 这不是 JSON';

    await runReal(tester, presetsCallback(tester));

    expect(find.textContaining('导入失败（已回滚，库内无残留）'), findsOneWidget);
    expect(presetsButton(tester).onPressed, isNotNull,
        reason: '`finally` 没复位的话，用户只能重启应用才能再导入');
    expect(repo.saveAllCalls, 0);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-14 导入进行中：连点两下**不重入**，清单只读一次', (tester) async {
    await pumpLib(tester);
    fakeManifest = manifestOf([
      preset(id: 'knocks_door_single', category: 'knocks', name: '敲门（单下）'),
    ]);
    fakeAudioBytes = 16;

    // 先抓回调：一旦进入导入中，按钮的 onPressed 会变成 null，就再也拿不到了。
    final cb = presetsCallback(tester);
    // 同一帧里调两次（模拟"手快连点两下"）：第二次必须被 `_importingPresets`
    // 挡在**读清单之前**（重入会重复落盘、重复写一整批）。
    await runReal(tester, () async {
      final first = cb();
      final second = cb();
      await first;
      await second;
    });

    expect(manifestLoads, 1, reason: '第二次点击必须被守卫挡在清单读取之前');
    expect(audioLoads, 1);
    expect(repo.saveAllCalls, 1, reason: '重入会写两批 —— 库内会出现重复条目');
    expect(repo.items.length, 1);
    expect(presetsButton(tester).onPressed, isNotNull);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-15 音频资源缺失 → 失败回滚、库内零新增、状态复位',
      (tester) async {
    await pumpLib(tester);
    fakeManifest = manifestOf([
      preset(id: 'missing', category: 'knocks', name: '缺失音效'),
    ]);
    // fakeAudioBytes 保持 null → 读音频会抛 "The asset does not exist…"
    await runReal(tester, presetsCallback(tester));

    expect(audioLoads, 1);
    expect(repo.items, isEmpty);
    expect(repo.saveAllCalls, 0, reason: '一条都没落盘，就不该碰数据库');
    expect(audioFiles(), isEmpty);
    expect(find.textContaining('导入失败（已回滚，库内无残留）'), findsOneWidget);
    expect(presetsButton(tester).onPressed, isNotNull);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-16 成功导入 2 条预置：落盘 + **一次**批量写库 + 提示 + 列表刷新',
      (tester) async {
    await pumpLib(tester);
    fakeManifest = manifestOf([
      preset(id: 'knocks_door_single', category: 'knocks', name: '敲门（单下）'),
      preset(id: 'glass_break', category: 'glass', name: '玻璃破碎'),
    ]);
    fakeAudioBytes = 64;

    await runReal(tester, presetsCallback(tester));

    expect(audioLoads, 2);
    expect(repo.saveAllCalls, 1, reason: '整批也必须是**一次**事务（BUG-047）');
    expect(repo.items.length, 2);
    expect(audioFiles().length, 2, reason: '每条预置都要在私有目录落一份 .wav');
    expect(repo.items.map((a) => a.name).toList(),
        containsAll(['[预置]敲门（单下）', '[预置]玻璃破碎']));
    // v2.0：第三个 tag 是 manifest 的稳定 id（反击计划按它回查本机已装的音效）。
    expect(repo.items.first.tags, ['预置', 'knocks', 'knocks_door_single']);
    expect(repo.items.map((a) => a.sizeBytes), everyElement(64),
        reason: '字节数取自资源本身（data.lengthInBytes）');
    expect(find.textContaining('预置音效导入完成：新增 2 条，跳过已存在 0 条'),
        findsOneWidget);
    expect(find.textContaining('库内共 2 条'), findsOneWidget);
    // 列表刷新（`finally` 里的 setState 顺带重建了 FutureBuilder）
    expect(find.text('[预置]敲门（单下）'), findsOneWidget);
    expect(find.text('0 KB · 预置/knocks/knocks_door_single'), findsOneWidget);

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-17 幂等：库内已有同名 → 跳过，**不读资源、不落盘、不写库**',
      (tester) async {
    await pumpLib(tester, seed: [
      asset(id: 'old', name: '[预置]敲门（单下）', tags: ['预置', 'knocks']),
    ]);
    fakeManifest = manifestOf([
      preset(id: 'knocks_door_single', category: 'knocks', name: '敲门（单下）'),
    ]);
    fakeAudioBytes = 64;

    await runReal(tester, presetsCallback(tester));

    expect(audioLoads, 0,
        reason: '重名条目必须在 `materialize` **之前**就跳过 —— 否则白读一次音频');
    expect(audioFiles(), isEmpty, reason: '跳过就不该落盘（否则会留下孤儿文件）');
    expect(repo.saveAllCalls, 0, reason: '全部重名 → 连空事务都不开');
    expect(find.textContaining('新增 0 条，跳过已存在 1 条'), findsOneWidget);
    expect(repo.items.length, 1, reason: '原有那条必须原样保留');

    await drainSnacks(tester);
  }, timeout: _timeout);

  testWidgets('SLB-18 导入中界面：按钮禁用 + 转圈 + 图标让位（用户知道它在干活）',
      (tester) async {
    await pumpLib(tester);
    // 把清单读取卡住 → 稳定停在"导入进行中"这一帧。
    // （不能只靠"pump 一帧"：`_importingPresets` 虽然同步置位，但 `pump()`
    //   会先排空微任务，mock 的清单读取在那时就完成了，状态已经复位。）
    manifestGate = Completer<void>();

    await tester.tap(find.text('导入预置库'));
    await tester.pump();

    expect(manifestLoads, 1);
    expect(presetsButton(tester).onPressed, isNull, reason: '导入中必须禁用按钮');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.library_music), findsNothing,
        reason: '图标位置要换成转圈，否则用户看不出它在动');

    // 放开闸门：清单缺失 → 链失败并复位（**不碰文件**，收尾可确定）。
    manifestGate!.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(presetsButton(tester).onPressed, isNotNull, reason: '失败后必须复位');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('导入失败（已回滚，库内无残留）'), findsOneWidget);

    await drainSnacks(tester);
  }, timeout: _timeout);

  // ══════════════════════════════════════════════════════════════════════
  // SLB-E · 删除（真实文件 I/O → 分段驱动）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('SLB-19 删除：先删记录、再删文件、最后刷新列表', (tester) async {
    final a = asset(id: 'a', name: 'A', path: '${tmp.path}/audio_a.wav');
    File(a.path).writeAsBytesSync(List<int>.filled(4, 1));
    await pumpLib(tester, seed: [a, asset(id: 'b', name: 'B')]);
    expect(find.text('A'), findsOneWidget);

    // `confirmDelete` 已由 pumpLib 注入为 false —— 无对话框，直接走删除链。
    await runReal(tester, deleteCallback(tester));

    expect(repo.deletedIds, ['a']);
    expect(File(a.path).existsSync(), isFalse, reason: '记录删了，文件也要删');
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsOneWidget);
  }, timeout: _timeout);

  testWidgets('SLB-20 文件已不在 → 不抛异常，列表照样刷新（孤儿文件不影响使用）',
      (tester) async {
    final a = asset(id: 'a', name: 'A', path: '${tmp.path}/never_existed.wav');
    await pumpLib(tester, seed: [a]);

    // `confirmDelete` 默认 false —— 无对话框，直接走删除链（孤儿文件容错）。
    await runReal(tester, deleteCallback(tester));

    expect(tester.takeException(), isNull);
    expect(repo.deletedIds, ['a']);
    expect(find.text('A'), findsNothing);
  }, timeout: _timeout);

  // ══════════════════════════════════════════════════════════════════════
  // SLB-F · 生命周期
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('SLB-22 删除确认对话框：出现、可取消、取消后记录还在', (tester) async {
    final a = asset(id: 'a', name: 'A', path: '${tmp.path}/audio_a.wav');
    File(a.path).writeAsBytesSync(List<int>.filled(4, 1));
    await pumpLib(tester, seed: [a], confirmDelete: true);

    // ⚠️ 确认场景**不能**用 runReal：链停在「等对话框结果」会 zone 死锁。
    // 直接启动链，对话框落地后点「取消」，链自然走完（无真实 IO）。
    unawaited(deleteCallback(tester)());
    await tester.pump(); // 对话框路由落地
    expect(find.textContaining('删除「'), findsOneWidget,
        reason: 'QR3：删除必须先确认（误删音源会让引用它的任务失效）');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.deletedIds, isEmpty, reason: '取消 ⇒ 不删');
    expect(find.text('A'), findsOneWidget);
  }, timeout: _timeout);

  testWidgets('SLB-24 确认删除 → 记录与文件都真的删掉（不是只关掉对话框）',
      (tester) async {
    final a = asset(id: 'a', name: 'A', path: '${tmp.path}/audio_a.wav');
    File(a.path).writeAsBytesSync(List<int>.filled(4, 1));
    await pumpLib(tester, seed: [a], confirmDelete: true);

    // ⚠️ 同 SLB-22：确认场景**不能**用 runReal（链会停在"等对话框结果"处
    // zone 死锁）。这里改成"先按 SLB-22 的方式启动 → 点确认 → 再分段驱动"，
    // 因为点完「删除」之后链才进入真实文件 I/O。
    unawaited(deleteCallback(tester)());
    await tester.pump();
    expect(find.textContaining('删除「'), findsOneWidget);

    await tester.tap(find.text('删除'));

    // 🔴 R97：**等目标现象**，不要数轮数。
    //
    // 旧写法是「固定 30 轮 `runAsync(零延迟)`、不做早退」—— 本轮门禁在整机
    // 满载（他项目 WSL2 + SD-WebUI 占满 CPU/内存）下实测复现一次红：30 轮
    // 不够让 `await f.delete()` 的续体恢复并走到 `setState`，断言于是看到
    // **旧的** 'A' ⇒ 失败原因被伪装成「列表没刷新」这个业务缺陷。
    //
    // 纪律与 PA-05 / RS-ND4 同源：等一个**会自己发生的事**（列表刷新），
    // 而不是等一个固定次数。退出条件刻意**不是**「文件已消失」——
    // 文件删除比 `setState` 更早可见，拿它当条件会过早收工。
    var refreshed = false;
    for (var i = 0; i < 300 && !refreshed; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      refreshed = find.text('A').evaluate().isEmpty;
    }
    expect(refreshed, isTrue, reason: '删完列表要立刻刷新');

    expect(repo.deletedIds, ['a'], reason: '确认删除必须真的删记录，否则是"假删除"');
    expect(File(a.path).existsSync(), isFalse,
        reason: '文件也要删 —— 只删记录会留下永远无人回收的孤儿文件');
  }, timeout: _timeout);

  testWidgets('SLB-21 卸载时释放试听播放器（否则解码器与唤醒锁会漏）',
      (tester) async {
    await pumpLib(tester);
    expect(player.disposed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(player.disposed, isTrue);
  }, timeout: _timeout);
}

/// `List<int>` → `ByteData`（资源通道的应答格式）。
ByteData _bytes(List<int> data) => Uint8List.fromList(data).buffer.asByteData();
