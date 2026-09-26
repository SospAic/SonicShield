import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';

/// 每设备 KDF 盐的**复用语义**行为锁（SR）。
///
/// ## 为什么需要它
///
/// `RcEndpointService` 是**私有构造的单例**（`RcEndpointService._()`），宿主测试
/// 无法实例化 ⇒ "生成/复用盐"的语义原先只能靠**源码锁**覆盖
/// （`test/q35_endpoint_wiring_test.dart` 的 Q1-03：断言方法体里含 `saltFor(`）。
///
/// ⚠️ 而源码锁**锁不住语义**：把"取已存盐"与"生成新盐"写反了，源码锁照样全绿 ——
/// 这正是本项目反复吃过的"假绿通道"（A11 / ASE-03/ASE-04 同源）。
///
/// 因此第 36 轮把这段逻辑抽成**顶层函数** [ensureSaltForDevice]
/// （`RcEndpointService._ensureSalt` 只做转发），让它可以被**行为**断言。
/// 本文件就是那把锁，并配 `SR-07` 反例证明判据非恒真。
///
/// ## 锁的是什么（为什么它值钱）
///
/// ★ **复用优先**：已配对设备**再次配对时绝不能换盐**。若换盐，控制端会存下新盐
/// 而本机（或对端）仍按旧盐派生 ⇒ 两端密钥不一致 ⇒ **静默失联**
/// （配对"成功"，此后所有命令与回执都解不开，界面上没有任何错误提示）。
/// 这类缺陷的形状是"功能看起来还在、只是永远不生效"，最贵也最难查。
///
/// ⚠️ 诚实边界：本文件锁的是**纯语义**（存储已装配时的行为）。
/// "真机上盐确实随配对回执下发、两端确实用同一份盐"仍需**两台设备**验收。
void main() {
  /// 每个用例一份干净存储。
  /// ⚠️ `SharedPreferences` 的 mock 是**全局**的 ⇒ 不复位会跨用例串盐。
  Future<KdfSaltStore> freshStore() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return KdfSaltStore(await SharedPreferences.getInstance());
  }

  test('SR-01 未装配盐存储 → null（不得凭空造盐，必须回落无盐 v1 路径）', () async {
    expect(await ensureSaltForDevice(null, 'dev-A'), isNull,
        reason: '未装配时若造一个盐返回，已配对设备会立刻失联（对端没有这份盐）');
  });

  test('SR-02 deviceId 为空 → null（空 id 会让所有设备共用一条记录）', () async {
    final store = await freshStore();
    expect(await ensureSaltForDevice(store, ''), isNull,
        reason: '空 id 若也落盘，会写成 `rc:kdfsalt:` 这**一条**，'
            '所有空 id 设备共用同一个盐');
  });

  test('SR-03 ★ 复用优先：已有盐必须原样返回，且不改写存储', () async {
    final store = await freshStore();
    final original = KdfSaltStore.newSalt();
    await store.saveSalt('dev-A', original);

    final got = await ensureSaltForDevice(store, 'dev-A');

    expect(got, original, reason: '★ 已配对设备再次配对**绝不能换盐**');
    expect(store.saltFor('dev-A'), original, reason: '存储里的值也不得被改写');
  });

  test('SR-04 无盐 → 生成并落盘；第二次调用返回同一份（幂等）', () async {
    final store = await freshStore();
    expect(store.saltFor('dev-A'), isNull, reason: '前置条件：确实还没有盐');

    final first = await ensureSaltForDevice(store, 'dev-A');
    expect(first, isNotNull);
    expect(first!.length, 32, reason: '盐必须是 32 字节（与 KdfSaltStore.newSalt 一致）');
    expect(store.saltFor('dev-A'), first, reason: '必须落盘，不能只留在内存里');

    final second = await ensureSaltForDevice(store, 'dev-A');
    expect(second, first, reason: '★ 第二次必须复用，不能重新生成');
  });

  test('SR-05 不同 deviceId 拿到不同的盐（每设备独立，不是全局一份）', () async {
    final store = await freshStore();
    final a = await ensureSaltForDevice(store, 'dev-A');
    final b = await ensureSaltForDevice(store, 'dev-B');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b),
        reason: '每设备随机盐是 Q1.B 的设计目标；共用一个盐等于退化回全局盐');
  });

  test('SR-06 盐是随机的（两份冷启动不撞）', () async {
    final s1 = await freshStore();
    final s2 = await freshStore();
    final a = await ensureSaltForDevice(s1, 'dev-A');
    final b = await ensureSaltForDevice(s2, 'dev-A');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b),
        reason: '随机盐不能是常量/固定派生；撞了说明退化成了固定盐');
  });

  test('SR-07 反例：一个"每次重新生成"的实现必须在 SR-03 的判据下判红', () async {
    // 反例样本：与真源只差**一行**（少了"复用优先"）。
    Future<List<int>?> regenerateEveryTime(KdfSaltStore? s, String id) async {
      if (s == null || id.isEmpty) return null;
      final salt = KdfSaltStore.newSalt(); // ← 每次都新生成
      await s.saveSalt(id, salt);
      return salt;
    }

    // SR-03 用的判据（深比较，不是 `==` 的引用比较 —— List 没有重写 ==）。
    bool sr03Predicate(List<int>? got, List<int> original) =>
        got != null && listEquals(got, original);

    final store = await freshStore();
    final original = KdfSaltStore.newSalt();
    await store.saveSalt('dev-A', original);

    final bad = await regenerateEveryTime(store, 'dev-A');

    // ① 反例样本本身必须"会变"，否则这条反例证明不了任何东西。
    expect(sr03Predicate(bad, original), isFalse,
        reason: '反例样本确实换了盐');
    expect(store.saltFor('dev-A'), isNot(original),
        reason: '反例样本把存储里的盐也换掉了 —— 这正是"静默失联"的成因');

    // ② 对照：真源在同一场景下必须**稳定**。
    final good = await ensureSaltForDevice(store, 'dev-A');
    expect(sr03Predicate(good, store.saltFor('dev-A')!), isTrue,
        reason: '★ 真源在同一判据下必须为 true ⇒ 判据能区分"复用"与"每次重生成"');
  });
}
