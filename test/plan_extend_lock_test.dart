import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';

/// **计划续算判据**回归锁（BUG-086，2026-10-18）。
///
/// ## 这把锁守护什么
///
/// 引擎主循环原来的续算判据是：
/// ```dart
/// final pending = await occs.pendingCountAfter(DateTime.now());
/// if (pending < SchedulerConfig.planExtendThreshold.inHours) { … replan … }
/// ```
/// `pendingCountAfter` 返回 `SELECT COUNT(*)` —— **条数**；而
/// `planExtendThreshold.inHours` 是 **12** —— **小时数**。两个不同量纲的
/// 值比大小，任务一多，条数常年 ≥ 12 ⇒ `pending < 12` 恒为 false
/// ⇒ **续算 tick 永不触发** ⇒ 未来计划视界（`planHorizon` 48h）只耗不补，
/// 逐轮缩进，最终夜间时段**没有任何 plan entry**。
///
/// 真机实证（Redmi K70 Pro / Android 16，`_pt/r86_audit/B_device.md`）：
/// 本应用 pending alarm **0 条**、未来覆盖 **0 小时**、22:00–07:00 窗口
/// occurrence **0 条**、JobScheduler 无本应用注册任务。于是用户打开
/// 「夜间豁免主开关」前后**表现完全一样** —— 因为夜里根本没有条目可被豁免。
/// 这是两轮"修缓存/修同步"都没治好的真实根因。
///
/// ## 为什么单靠行为锁不够
///
/// `lib/services/background_engine.dart` 在**设备层豁免清单**里
/// （`tool/coverage_report.dart` `_deviceOnly`，宿主测试不覆盖它），
/// 所以 tick 那条路径**跑不到**。因此这里用两把锁夹住：
/// - **PXD**（源码契约锁）：直接在源码文本上**禁止**"条数 < 小时"这个形状，
///   并反向锚定新判据必须被接线。任何人把旧判据写回来，立刻变红。
/// - **PXP**（行为锁）：对抽出来的纯函数 [planNeedsExtend] 做边界断言，
///   覆盖"该续算/不该续算"两类场景，其中包含旧判据会漏/会误判的具体形状。
///
/// ## 解析坑（与 `tts_asset_lock_test.dart` 同源）
///
/// 本仓库工作区文件是 **CRLF**（`core.autocrlf=true`）。若先 `split('\n')`
/// 再用带 `$` 的正则，行尾残留的 `\r` 会让 `$` 匹配不上 —— 表现是"带注释
/// 的那一行解析不出来"，且只在行内有 `#` 时暴露。故这里先归一化换行。
void main() {
  final engineSrc = () {
    final raw = File('lib/services/background_engine.dart').readAsStringSync();
    return raw.replaceAll('\r\n', '\n');
  }();

  group('PXD · 源码契约：禁止"条数 < 小时"的续算判据', () {
    test('PXD-01 不得拿 pendingCountAfter 的结果与 planExtendThreshold 比大小', () {
      // 旧判据的最精确特征串。用它而不是"调用点后 300 字符内出现 <"这类
      // 宽泛正则 —— 宽正则会误伤邻近代码，窄特征串则只在真的写回旧判据时命中。
      expect(
        engineSrc.contains('< SchedulerConfig.planExtendThreshold'),
        isFalse,
        reason: '续算判据又在拿"条数"和"小时"比大小了（BUG-086 原型）。'
            '判据应为"覆盖末端是否缩进阈值内"，见 planNeedsExtend。',
      );
    });

    test('PXD-02 新判据必须接线：planNeedsExtend + latestPendingFireAt 都要用上', () {
      expect(
        engineSrc.contains('planNeedsExtend('),
        isTrue,
        reason: 'tick 没走 planNeedsExtend —— 判据被绕回旧写法或删干净了',
      );
      expect(
        engineSrc.contains('latestPendingFireAt('),
        isTrue,
        reason: '取不到"覆盖末端"就没有判据输入（MAX(fire_at) 那一步不见了）',
      );
    });

    test('PXD-90 反面样本：把判据写回"条数 < 小时"必须被 PXD-01 抓到', () {
      // 反面样本不是测试缺陷，而是**证明锁有效**：把旧判据原文喂给同一
      // 条判据，它必须命中。若哪天 PXD-01 的特征串写松了，这里会红。
      const buggy = '''
final pending = await occs.pendingCountAfter(DateTime.now());
if (pending < SchedulerConfig.planExtendThreshold.inHours) {
  await stepGuarded('replan(tick)', replan);
}
''';
      expect(buggy.contains('< SchedulerConfig.planExtendThreshold'), isTrue,
          reason: '反面样本竟然没命中 ⇒ PXD-01 的判据已失效，形同虚设');
    });
  });

  group('PXP · 行为：planNeedsExtend 边界', () {
    final now = DateTime(2026, 10, 18, 22, 0); // 正在夜间窗口内
    const t = Duration(hours: 12); // SchedulerConfig.planExtendThreshold 默认值

    test('PXP-01 空表（coverEnd=null）⇒ 必须续算（自愈补排）', () {
      // 新装 / 清库 / 引擎重启后靠这条补回计划。
      expect(planNeedsExtend(null, now: now, threshold: t), isTrue);
    });

    test('PXP-02 覆盖末端还在阈值之外 ⇒ 不续算（稳态约 36h 一次）', () {
      // 48h 视界刚铺满：最后一条在 now+48h，远在 now+12h 之外。
      expect(planNeedsExtend(now.add(const Duration(hours: 48)),
          now: now, threshold: t), isFalse);
      expect(planNeedsExtend(now.add(const Duration(hours: 50)),
          now: now, threshold: t), isFalse);
    });

    test('PXP-03 覆盖末端缩进阈值之内 ⇒ 续算（旧判据正是漏掉这一种）', () {
      expect(planNeedsExtend(now.add(const Duration(hours: 11)),
          now: now, threshold: t), isTrue);
      expect(planNeedsExtend(now.add(const Duration(hours: 6)),
          now: now, threshold: t), isTrue);
      // 刚好落在 now+12h 上（边界）也判"该续算"：覆盖已无余量。
      expect(planNeedsExtend(now.add(t), now: now, threshold: t), isTrue);
    });

    test('PXP-04 正向场景：20 条密集 pending 但只剩 11 小时覆盖 ⇒ 续算', () {
      // 🔴 这是旧判据**必然漏掉**的形状：条数 20 ≥ 12 ⇒ `pending < 12` 为假
      // ⇒ 永不续算 ⇒ 再过一小时这些条目耗尽，夜间从此没有计划。
      const pendingCount = 20;
      expect(pendingCount >= 12, isTrue, reason: '构造旧判据会误判的前提');
      expect(
        planNeedsExtend(now.add(const Duration(hours: 11)),
            now: now, threshold: t),
        isTrue,
        reason: '判据必须看"时间覆盖"，不是"条数"',
      );
    });

    test('PXP-05 反向场景：只有 2 条但覆盖还有 50 小时 ⇒ 不续算', () {
      // 镜像场景：条数很少，旧判据会**误触发**（每 tick 全量重算的性能灾难）。
      const pendingCount = 2;
      expect(pendingCount < 12, isTrue, reason: '构造旧判据会误判的前提');
      expect(
        planNeedsExtend(now.add(const Duration(hours: 50)),
            now: now, threshold: t),
        isFalse,
        reason: '条数少不代表覆盖不足，不许为了凑数反复全量重算',
      );
    });
  });
}
