import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/features/remote/device_list_screen.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 「我的设备」列表（向日葵式：保存连接 + 快速连接）的回归锁。
///
/// 重点不是 UI，而是**共享选择**这条规则：
/// 此前每个 TAB 各自持有 `_selectedId`，在列表页选好的端点切到控制台就丢了，
/// 于是"快速连接"名存实亡。规则错了是**静默**的（不报错、不崩溃），只能靠锁。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
  });

  PairedEndpoint ep(String id, {String name = '端点'}) => PairedEndpoint(
        deviceId: id,
        name: name,
        secret: 's-$id',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  group('DLS 共享选择', () {
    test('DLS-01 已选端点在表里 -> 用它，而不是第一条', () {
      final list = [ep('a'), ep('b'), ep('c')];
      // 关键：persisted 是 'c'，第一条是 'a'；返回 'c' 才叫"快速连接有效"。
      expect(initialSelectedId(list, 'c'), 'c');
    });

    test('DLS-02 已选端点已被删除 -> 回落第一条（不返回失效 id）', () {
      final list = [ep('a'), ep('b')];
      expect(initialSelectedId(list, 'zzz-deleted'), 'a',
          reason: '指向已删除端点的旧状态不能直接用 —— 会让页面选中一个不存在的目标');
    });

    test('DLS-03 没有已选 -> 第一条', () {
      final list = [ep('a'), ep('b')];
      expect(initialSelectedId(list, ''), 'a');
    });

    test('DLS-04 空表 -> 空串', () {
      expect(initialSelectedId(const <PairedEndpoint>[], 'x'), '');
    });

    test('DLS-05 选择会持久化，跨页面读到同一台', () async {
      await store.addPaired(ep('a'));
      await store.addPaired(ep('b', name: '客厅'));
      await store.selectEndpoint('b');
      // 模拟另一个页面重新初始化：应当读到 'b'。
      final again = RemoteStore(await SharedPreferences.getInstance());
      expect(again.selectedEndpointId, 'b');
      expect(initialSelectedId(again.paired(), again.selectedEndpointId), 'b');
    });

    test('DLS-06 删掉当前目标 -> 选择被清空', () async {
      await store.addPaired(ep('a'));
      await store.selectEndpoint('a');
      expect(store.selectedEndpointId, 'a');
      await store.removePaired('a');
      expect(store.selectedEndpointId, '',
          reason: '否则列表里会出现"选中了一个已被删除的端点"');
    });
  });

  group('DLS 备注名', () {
    test('DLS-07 displayName：备注优先，空备注回落自报名', () {
      expect(ep('a', name: 'Xiaomi').displayName, 'Xiaomi');
      final e = ep('a', name: 'Xiaomi').copyWith(alias: '爸妈的手机');
      expect(e.displayName, '爸妈的手机');
      // 空串/纯空格备注视为没写，不能显示成空白。
      expect(e.copyWith(alias: '   ').displayName, 'Xiaomi');
    });

    test('DLS-08 copyWith 能真正清空备注（sentinel 生效）', () {
      final e = ep('a').copyWith(alias: 'nick');
      expect(e.alias, 'nick');
      expect(e.copyWith(alias: null).alias, isNull,
          reason: '若用 `alias ?? this.alias` 就清不掉备注 —— 这是 ??= 同族的静默失效');
      // 不带该参数时保持原值。
      expect(e.copyWith(name: 'new').alias, 'nick');
    });

    test('DLS-09 renamePaired 对不存在的端点静默忽略', () async {
      await store.addPaired(ep('a'));
      await store.renamePaired('nope', 'x');
      expect(store.paired().single.deviceId, 'a');
      expect(store.paired().single.alias, isNull);
    });

    test('DLS-10 touchPaired 记下最近连接时间', () async {
      await store.addPaired(ep('a'));
      expect(store.paired().single.lastConnectedAt, isNull);
      await store.selectEndpoint('a');
      expect(store.paired().single.lastConnectedAt, isNotNull);
    });

    test('DLS-11 touchPaired 对不存在的端点静默忽略（记账不该影响主流程）', () async {
      await store.addPaired(ep('a'));
      await store.touchPaired('nope');
      expect(store.paired().length, 1);
      expect(store.paired().single.lastConnectedAt, isNull);
    });
  });

  group('DLS 展示文案', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('DLS-12 从未连接', () {
      expect(formatLastConnected(null, now), '从未连接');
    });

    test('DLS-13 各档位相对时间', () {
      expect(formatLastConnected(now.subtract(const Duration(seconds: 5)), now),
          '刚刚');
      expect(
          formatLastConnected(now.subtract(const Duration(minutes: 5)), now),
          '5 分钟前');
      expect(formatLastConnected(now.subtract(const Duration(hours: 3)), now),
          '3 小时前');
      expect(formatLastConnected(now.subtract(const Duration(days: 2)), now),
          '2 天前');
      // 超过 30 天回落具体日期（相对时间已经没有意义）。
      expect(formatLastConnected(now.subtract(const Duration(days: 40)), now),
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('DLS-14 时钟回拨不显示负时间', () {
      expect(formatLastConnected(now.add(const Duration(hours: 1)), now),
          '刚刚');
    });
  });
}
