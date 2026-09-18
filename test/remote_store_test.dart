import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/remote_store.dart';

/// 配对表持久化（`RemoteStore`）契约测试。
///
/// ## BUG-031 回归背景
/// `paired()` 在空表时返回 `const []`（不可变），而 `addPaired` 写的是
/// `[...paired()..removeWhere(...), e]` —— 级联 `..removeWhere` 作用在
/// **不可变列表**上直接抛 `Unsupported operation: Cannot remove from an
/// unmodifiable list`。
///
/// 后果比"配对表写不进去"更隐蔽：`pair_qr_screen._pairFromUri` 没有 try/catch，
/// 异常在 `await` 处抛出 → 其后的 `setState('已配对：…')` 永不执行 →
/// 使用者看到的是"扫完码界面毫无反应，也不报错"。
/// **首次配对必然触发**（空表），因此这是主路径上的 P1 缺陷。
///
/// 本文件锁定：空表/非空表/重复配对/删除 四条路径都不得抛异常，
/// 且 `paired()` 必须始终返回**可变**列表（消灭该类脚枪）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
  });

  PairedEndpoint ep(String id, [String name = '端点']) => PairedEndpoint(
        deviceId: id,
        name: name,
        secret: 'sec-$id',
        pairedAt: DateTime.now(),
      );

  test('RS-01 空表读取返回可变列表，且不抛异常', () {
    final list = store.paired();
    expect(list, isEmpty);
    // 关键：必须是可变的（BUG-031 的根因就是这里返回了 const []）。
    expect(() => list.removeWhere((_) => true), returnsNormally);
  });

  test('RS-02 空表 addPaired 不抛异常并写入成功（BUG-031 回归）', () async {
    // 修复前：这里抛 Unsupported operation（首次配对必然失败）。
    await expectLater(store.addPaired(ep('dev-1', '端点A')), completes);

    final list = store.paired();
    expect(list, hasLength(1));
    expect(list.first.deviceId, 'dev-1');
    expect(list.first.name, '端点A');
    expect(list.first.secret, 'sec-dev-1');
  });

  test('RS-03 同一 deviceId 重复配对为覆盖，不产生重复项', () async {
    await store.addPaired(ep('dev-1', '旧名'));
    await store.addPaired(ep('dev-1', '新名'));

    final list = store.paired();
    expect(list, hasLength(1));
    expect(list.first.name, '新名', reason: '重新配对应覆盖旧记录');
  });

  test('RS-04 多个端点共存且顺序稳定', () async {
    await store.addPaired(ep('dev-1', 'A'));
    await store.addPaired(ep('dev-2', 'B'));
    await store.addPaired(ep('dev-3', 'C'));

    expect(store.paired().map((e) => e.deviceId), ['dev-1', 'dev-2', 'dev-3']);

    // 覆盖中间一项不应打乱其余顺序
    await store.addPaired(ep('dev-2', 'B2'));
    expect(store.paired().map((e) => e.deviceId), ['dev-1', 'dev-2', 'dev-3']);
    expect(store.paired()[1].name, 'B2');
  });

  test('RS-05 空表 removePaired 不抛异常（同类脚枪）', () async {
    await expectLater(store.removePaired('nope'), completes);
    expect(store.paired(), isEmpty);
  });

  test('RS-06 removePaired 精确删除目标项', () async {
    await store.addPaired(ep('dev-1', 'A'));
    await store.addPaired(ep('dev-2', 'B'));

    await store.removePaired('dev-1');

    expect(store.paired().map((e) => e.deviceId), ['dev-2']);
  });

  test('RS-07 配对表损坏（非法 JSON）→ 视为空表且不抛', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rc_paired', '{not json');

    expect(store.paired(), isEmpty);
    // 损坏后仍可正常写入新配对（自愈）
    await store.addPaired(ep('dev-9', 'X'));
    expect(store.paired().map((e) => e.deviceId), ['dev-9']);
  });

  test('RS-08 配对秘密与时间戳可完整往返', () async {
    final at = DateTime.fromMillisecondsSinceEpoch(1750000000000);
    await store.addPaired(PairedEndpoint(
        deviceId: 'd', name: 'n', secret: 's3cr3t', pairedAt: at));

    final back = store.paired().single;
    expect(back.secret, 's3cr3t');
    expect(back.pairedAt.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
  });

  // ---------------- RS-1x TURN 中继配置（S5） ----------------

  test('RS-10 默认未配置 TURN（不内置公共中继）', () {
    expect(store.turnUrl, isEmpty);
    expect(store.turnUser, isEmpty);
    expect(store.turnCred, isEmpty);
    expect(store.turnConfigured, isFalse);
  });

  test('RS-11 TURN 配置可保存与读取，且去除首尾空白', () async {
    await store.setTurn(
        url: '  turn:relay.example.com:3478  ',
        user: ' sonic ',
        cred: 'p@ss');

    expect(store.turnUrl, 'turn:relay.example.com:3478');
    expect(store.turnUser, 'sonic');
    expect(store.turnCred, 'p@ss');
    expect(store.turnConfigured, isTrue);
  });

  test('RS-12 传空地址即关闭中继（降级回纯 STUN）', () async {
    await store.setTurn(url: 'turn:x:3478', user: 'u', cred: 'c');
    expect(store.turnConfigured, isTrue);

    await store.setTurn(url: '', user: '', cred: '');

    expect(store.turnConfigured, isFalse);
    expect(store.turnUrl, isEmpty);
  });

  test('RS-13 仅空白地址视为未配置', () async {
    await store.setTurn(url: '   ', user: 'u', cred: 'c');
    expect(store.turnConfigured, isFalse);
  });

  test('RS-14 TURN 配置与配对表互不干扰', () async {
    await store.setTurn(url: 'turn:x:3478', user: 'u', cred: 'c');
    await store.addPaired(ep('dev-1'));

    expect(store.turnConfigured, isTrue);
    expect(store.paired(), hasLength(1));
  });
}
