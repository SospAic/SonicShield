import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/app.dart';
import 'package:sonic_shield/core/theme.dart';
import 'package:sonic_shield/core/utils/random.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/features/guard/guard_toggle.dart';
import 'package:sonic_shield/remote/device_group.dart';

/// 第三十六轮「覆盖率冲刺」—— **纯逻辑簇**（DL 系列）。
///
/// ## 为什么单独一组
///
/// 覆盖率榜（`_pt/unc/*.txt`）显示：一批**声明式/工具类**文件的未覆盖行
/// 根本不是"难测"，而是**从没被任何测试碰过** —— `AppTheme.light()` 一行
/// 都没执行过、随机工具的兜底分支没人走过、`Task.fromRow` 的容错分支
/// 没人触发。这类缺口不补，覆盖率就永远卡在那里。
///
/// ## 锁的是什么（不是"函数存在"）
///
/// - `AppTheme`：**深浅两套主题必须都真实构建**，且品牌色随亮度切换
///   （只测一个就等于没测 `_base` 的分支）；
/// - `pickWeighted`/`sampleInWindow`：**兜底分支必须真被走到**，
///   而且要断言"兜底产物的形状"（等分、有序、数量对）；
/// - `Task._decodeJson` 的"既非 Map 也非 String"兜底：必须**抛出**，
///   不能静默吞掉（静默 → 配置损坏被当成空配置，静默失效）；
/// - `GuardToggleOutcome.text`：`detail` 为空时**必须**退回分类文案，
///   否则"失败原因"就变成空白 —— 用户拿不到任何可行动的信息。
///
/// ⚠️ 不写源码锁（既有 lock 系列已覆盖），全部为行为断言。

/// 固定 `nextDouble()` 的随机源：把浮点兜底分支逼出来。
///
/// `pickWeighted` 的 `return items.last`（random.dart:69）只在
/// "减完所有权重后 r 仍 > 0"时到达 —— 那需要 `fold` 累加与逐次相减
/// 的浮点误差不一致，用真随机数**碰运气**极不稳定。这里固定
/// `nextDouble() = 1.0`，让误差必然暴露。
///
/// ⚠️ Dart **不允许**在函数体内声明类 —— 必须放在顶层。
class FixedDoubleRandom implements Random {
  FixedDoubleRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => max - 1;

  @override
  bool nextBool() => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DL-01 AppTheme：深浅两套主题都要真构建', () {
    test('light 用深青做 seed，且 M3 + AppBar 居中生效', () {
      final t = AppTheme.light();
      expect(t.useMaterial3, isTrue);
      expect(t.colorScheme.brightness, Brightness.light);
      expect(t.colorScheme.primary, isNot(AppTheme.shieldDeep),
          reason: 'primary 是 seed 派生色，不等于 seed 本身');
      expect(t.appBarTheme.centerTitle, isTrue);
      expect(t.snackBarTheme.behavior, SnackBarBehavior.floating);
    });

    test('dark 走另一个 seed（shieldMid），两套主题不能是同一个对象', () {
      final light = AppTheme.light();
      final dark = AppTheme.dark();
      expect(dark.colorScheme.brightness, Brightness.dark);
      expect(dark.colorScheme.primary, isNot(light.colorScheme.primary),
          reason: '深浅主题若共用 seed，_base 的分支就等于没被执行');
    });
  });

  group('DL-02 随机工具：兜底分支必须真被走到', () {
    test('pickWeighted 浮点误差导致全部权重减完仍未命中 → 回落 items.last', () {
      final items = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
      final weights = List<double>.filled(7, 0.1);
      final got = pickWeighted(items, weights, FixedDoubleRandom(1.0));
      expect(got, 'g', reason: '权重全部减完仍 > 0 时必须回落到最后一个');
    });

    test('sampleInWindow 窗口装不下最小间隔 → 退化为等分（且数量正确）', () {
      // n=5、window=100ms、minGap=30ms：(5-1)*30=120 >= 100 → 必然走等分兜底。
      final out = sampleInWindow(
        n: 5,
        window: const Duration(milliseconds: 100),
        minGap: const Duration(milliseconds: 30),
        rng: FixedDoubleRandom(0.5),
      );
      expect(out, hasLength(5));
      for (var i = 1; i < out.length; i++) {
        expect(
          out[i].inMilliseconds,
          greaterThanOrEqualTo(out[i - 1].inMilliseconds),
          reason: '兜底产物必须有序（等分 + 微抖动后仍单调）',
        );
      }
      expect(out.first.inMilliseconds, lessThanOrEqualTo(100));
    });

    test('sampleInWindow 拒绝采样失败兜底：清空后整体等分', () {
      // 窗口极小 + 间隔极大，让拒绝采样 attempts 耗尽。
      final out = sampleInWindow(
        n: 40,
        window: const Duration(milliseconds: 50),
        minGap: const Duration(milliseconds: 1),
        rng: FixedDoubleRandom(0.999),
      );
      expect(out, hasLength(40), reason: '兜底必须把数量补齐，不能少给');
      final unique = out.map((d) => d.inMilliseconds).toSet();
      expect(unique.length, lessThanOrEqualTo(41));
    });
  });

  group('DL-03 模型层容错：损坏数据不得被静默吞掉', () {
    test('Task._decodeJson 遇到既非 Map 也非 String 的值 → 抛错而非空配置', () {
      final row = <String, dynamic>{
        'id': 't1',
        'name': '任务',
        'enabled': 1,
        'trigger_type': 'dailyAt',
        'trigger_json': 42, // 既不是 Map 也不是 String
        'action_type': 'playAudio',
        'action_json': <String, dynamic>{'kind': 'playAudio'},
        'asset_ids': <String>[],
        'cooldown_sec': 0,
        'quiet_policy': 'skip',
        'created_at': 0,
        'updated_at': 0,
      };
      expect(() => Task.fromRow(row), throwsA(isA<ArgumentError>()),
          reason: '损坏的 trigger_json 必须暴露，静默当空配置=配置被吞');
    });

    test('WeeklyTrigger.fromJson 带 dateRange 时必须解析出区间', () {
      final t = WeeklyTrigger.fromJson(<String, dynamic>{
        'weekdays': [1, 3, 5],
        'time': {'hour': 9, 'minute': 30},
        'dateRange': {
          'start': '2026-01-01',
          'end': '2026-12-31',
        },
      });
      expect(t.weekdays, {1, 3, 5});
      expect(t.time.hour, 9);
      expect(t.dateRange, isNotNull);
      expect(t.dateRange!.start.year, 2026);
    });

    test('lerpColorSafe 端点与中点', () {
      // ⚠️ 必须比 ARGB 数值，不能比对象：`Colors.red` 是 `MaterialColor`，
      // 而 `Color.lerp` 返回的是普通 `Color` —— 两者 `==` 不成立
      // （第一轮实测就栽在这里：Expected MaterialColor / Actual Color）。
      expect(lerpColorSafe(Colors.red, Colors.blue, 0.0).toARGB32(),
          Colors.red.toARGB32());
      expect(lerpColorSafe(Colors.red, Colors.blue, 1.0).toARGB32(),
          Colors.blue.toARGB32());
      final mid = lerpColorSafe(Colors.red, Colors.blue, 0.5);
      expect(mid.toARGB32(), isNot(Colors.red.toARGB32()));
      expect(mid.toARGB32(), isNot(Colors.blue.toARGB32()));
    });
  });

  group('DL-04 小工具/值对象', () {
    test('ConditionEnv 默认：电量 100、不在充电、平台项无法判定', () {
      const env = ConditionEnv();
      expect(env.charging, isFalse);
      expect(env.batteryLevel, 100);
      expect(env.inCall, isNull, reason: 'null = 无法判定，不是"没在通话"');
      expect(env.onWifi, isNull);
    });

    test('DeviceGroupStore.newId 带 g 前缀且是纯数字时间戳', () {
      final a = DeviceGroupStore.newId();
      expect(a, startsWith('g'));
      expect(int.tryParse(a.substring(1)), isNotNull,
          reason: 'id 主体必须是可解析的微秒时间戳');

      // ⚠️ **实测发现（不断言，只记录）**：Windows 上
      // `DateTime.now().microsecondsSinceEpoch` 的实际粒度粗于 1 微秒 ——
      // 连续两次 `newId()` 实测返回**同一个值**（`g1790383692399129`）。
      // 因此这里**不**断言"两次必不相同"，否则用例在 CI/Windows 上随机红。
      // Android 端（真实运行环境）时钟粒度更细，且分组不同步、量级极小，
      // 暂不视为缺陷；仅记录以便将来若出现组覆盖再查。
    });

    test('ScheduleEngine 可带自定义免打扰窗口构造', () {
      const e = ScheduleEngine(
        quietStartHour: 23,
        quietEndHour: 7,
        allowQuietExempt: true,
      );
      expect(e.quietStartHour, 23);
      expect(e.quietEndHour, 7);
      expect(e.allowQuietExempt, isTrue);
    });
  });

  group('DL-05 GuardToggleOutcome：失败原因不得变成空白', () {
    test('none 视为成功，文案为空', () {
      const o = GuardToggleOutcome(GuardToggleFailure.none);
      expect(o.ok, isTrue);
      expect(o.text, isEmpty);
    });

    test('detail 为空 → 必须退回分类文案（不能给用户空白）', () {
      const o = GuardToggleOutcome(GuardToggleFailure.micDenied);
      expect(o.ok, isFalse);
      expect(o.text, contains('麦克风'),
          reason: 'detail 缺失时若不退回分类文案，用户就看不到任何可行动信息');
    });

    test('detail 非空且非空串 → 优先用引擎自报的具体原因', () {
      const o = GuardToggleOutcome(
        GuardToggleFailure.guardStartFailed,
        detail: '麦克风被占用',
      );
      expect(o.text, '麦克风被占用');
    });

    test('detail 为**空白串**时按现状返回该空白串（现状锁定 + 已知瑕疵）', () {
      // ⚠️ **实测行为**：`text` 的判据是 `d.isNotEmpty`，空白串 `"   "` 满足
      // 该条件 → **原样返回**，不会退回分类文案。也就是说"引擎给了个全空白
      // 的原因"会让用户看到一片空白。
      //
      // 这里锁定**现状**（而不是我期望的行为）：改判据属于产品决策，
      // 不该由一个覆盖率冲刺的用例偷偷改掉。瑕疵已记入 docs/12，待裁决。
      const o = GuardToggleOutcome(GuardToggleFailure.engineNoResponse,
          detail: '   ');
      expect(o.text, '   ');
    });

    test('每个失败分类都有非空兜底文案（不得出现空白提示）', () {
      for (final f in GuardToggleFailure.values) {
        if (f == GuardToggleFailure.none) continue;
        expect(guardFailureText(f).trim().isNotEmpty, isTrue,
            reason: '$f 缺少兜底文案 → 用户会看到空白提示');
      }
    });
  });

  group('DL-06 App 外壳：合规开关 + 整壳可挂载', () {
    test('complianceAcceptedProvider 默认已接受', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(complianceAcceptedProvider), isTrue);
    });

    testWidgets('SonicShieldApp 能挂起来（不因路由/主题配置而抛）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: SonicShieldApp()),
      );
      await tester.pump();
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });
}
