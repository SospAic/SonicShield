import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/features/settings/evidence_screen.dart';
import 'package:sonic_shield/services/evidence_files.dart';

/// 取证文件管理页（`EvidenceScreen`，P2-11）的宿主回归锁。
///
/// 通过 `EvidenceScreen(store:)` 注入缝塞入替身，避开真实平台目录与文件 I/O
/// —— 页面要锁的是"**界面怎么用服务**"：空态、容量文案、列表项、删除必须
/// 二次确认、删除后重新拉取、失败可见。
///
/// 服务本身（过滤/排序/真删/拒绝非取证路径）由 `evidence_files_test.dart`
/// 在真实临时目录上验证，这里不重复。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kShare = MethodChannel('dev.fluttercommunity.plus/share');

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> shareCalls;

  setUp(() {
    shareCalls = <MethodCall>[];
    messenger().setMockMethodCallHandler(kShare, (call) async {
      shareCalls.add(call);
      return 'ok';
    });
  });

  tearDown(() => messenger().setMockMethodCallHandler(kShare, null));

  EvidenceFile f(String name, {int bytes = 2048}) => EvidenceFile(
        path: '${Directory.systemTemp.path}/$name',
        name: name,
        sizeBytes: bytes,
        modifiedAt: DateTime(2026, 5, 6, 7, 8),
      );

  Future<void> pumpEvidence(WidgetTester tester, EvidenceStore store) async {
    await tester.pumpWidget(MaterialApp(home: EvidenceScreen(store: store)));
    // FutureBuilder 的 future 有两次微任务跳（_store() → list()），多 pump
    // 一轮让 data 落定。
    await tester.pump();
    await tester.pump();
  }

  testWidgets('EVD-01 空态：明确告知暂无取证文件，并给出产生方式', (tester) async {
    await pumpEvidence(tester, _FakeStore(const []));

    expect(find.text('录音取证文件'), findsOneWidget); // AppBar
    expect(find.textContaining('暂无录音取证文件'), findsOneWidget);
    expect(find.textContaining('共 0 个文件'), findsOneWidget,
        reason: '空态也要给出容量口径，而不是什么都不显示');
    // 「永不自动删除」这条承诺必须在页面上可见。
    expect(find.textContaining('永不自动删除'), findsOneWidget);
  });

  testWidgets('EVD-02 列表：逐条渲染名称/大小/时间，顶部汇总容量与数量',
      (tester) async {
    final store = _FakeStore([
      f('evidence_1.evidence.m4a', bytes: 2048),
      f('evidence_2.evidence.m4a', bytes: 3 * 1024 * 1024),
    ]);
    await pumpEvidence(tester, store);

    expect(find.text('evidence_1.evidence.m4a'), findsOneWidget);
    expect(find.text('evidence_2.evidence.m4a'), findsOneWidget);
    expect(find.textContaining('共 2 个文件'), findsOneWidget);
    // 2KB + 3.0MB 的合计应被格式化出来（不是恒定的 0 KB）。
    expect(find.textContaining('共 2 个文件 · '), findsOneWidget);
    expect(find.byTooltip('导出'), findsNWidgets(2));
    expect(find.byTooltip('删除'), findsNWidgets(2));
  });

  testWidgets('EVD-03 点删除 → 先弹二次确认；取消 ⇒ 不删、列表不变',
      (tester) async {
    final store = _FakeStore([f('keep.evidence.m4a')]);
    await pumpEvidence(tester, store);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除「keep.evidence.m4a」？'), findsOneWidget,
        reason: '删用户资产必须二次确认，且带上文件名');
    expect(find.textContaining('不可恢复'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(store.deleted, isEmpty, reason: '取消后绝不能真删');
    expect(find.text('keep.evidence.m4a'), findsOneWidget);
  });

  testWidgets('EVD-04 确认删除 → 调 store.delete 并重新拉取（该项消失）',
      (tester) async {
    final store = _FakeStore([f('gone.evidence.m4a')]);
    await pumpEvidence(tester, store);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除')); // 弹窗里的确认按钮
    await tester.pumpAndSettle();

    expect(store.deleted, [f('gone.evidence.m4a').path]);
    expect(store.listCalls, greaterThanOrEqualTo(2),
        reason: '删除后必须重新拉取列表，否则界面还显示已删的文件');
    expect(find.text('gone.evidence.m4a'), findsNothing);
    expect(find.textContaining('共 0 个文件'), findsOneWidget);
  });

  testWidgets('EVD-05 删除失败 → 明确报错，不静默吞掉', (tester) async {
    final store = _FakeStore([f('boom.evidence.m4a')])
      ..failOnDelete = const FileSystemException('disk on fire');
    await pumpEvidence(tester, store);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('删除失败：'), findsOneWidget,
        reason: '删除失败必须让用户看见');
  });

  testWidgets('EVD-06 点导出 → 走 share_plus 分享该文件', (tester) async {
    final store = _FakeStore([f('share_me.evidence.m4a')]);
    await pumpEvidence(tester, store);

    await tester.tap(find.byTooltip('导出'));
    await tester.pumpAndSettle();

    expect(shareCalls.any((c) => c.method == 'shareFiles'), isTrue,
        reason: '导出=原样分享源文件，不改动源文件');
  });

  testWidgets('EVD-07 分享抛错 → 明确「导出失败」，不静默吞掉', (tester) async {
    // 平台侧分享失败（无可用分享目标 / 通道异常）时，catch 必须给可读回执，
    // 而不是让用户以为"点了导出却没反应"。
    messenger().setMockMethodCallHandler(kShare, (call) async {
      throw PlatformException(code: 'share_unavailable');
    });
    final store = _FakeStore([f('share_boom.evidence.m4a')]);
    await pumpEvidence(tester, store);

    await tester.tap(find.byTooltip('导出'));
    await tester.pumpAndSettle();

    expect(find.textContaining('导出失败：'), findsOneWidget);
  });

  testWidgets('EVD-08 未注入 store → 自建基于文档目录的仓库（默认真实路径也能列空）',
      (tester) async {
    final docs = Directory.systemTemp.createTempSync('evd_docs_');
    const kPathProvider = MethodChannel('plugins.flutter.io/path_provider');
    addTearDown(() {
      messenger().setMockMethodCallHandler(kPathProvider, null);
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });
    messenger().setMockMethodCallHandler(kPathProvider, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return docs.path;
      return null;
    });

    // 生产形态：不传 store ⇒ `_store()` 自建 EvidenceStore(directory: docs)。
    await tester.pumpWidget(const MaterialApp(home: EvidenceScreen()));
    await tester.pump();
    await tester.pump();

    expect(find.text('录音取证文件'), findsOneWidget);
    expect(find.textContaining('暂无录音取证文件'), findsOneWidget,
        reason: '空目录也必须正常渲染空态，而不是卡在加载/报错');
  });
}

/// 内存版取证仓库替身（`extends` 以便基类后续新增成员时不编译报错）。
class _FakeStore extends EvidenceStore {
  _FakeStore(this.items) : super(directory: Directory('unused'));

  List<EvidenceFile> items;
  final List<String> deleted = [];
  int listCalls = 0;
  Object? failOnDelete;

  @override
  Future<List<EvidenceFile>> list() async {
    listCalls++;
    return List.of(items);
  }

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
    final e = failOnDelete;
    if (e != null) throw e;
    items = items.where((x) => x.path != path).toList();
  }
}