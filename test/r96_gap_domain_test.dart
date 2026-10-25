import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/remote/node_catalog.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';
import 'package:sonic_shield/services/deepseek_service.dart';

/// R96 门禁补洞：把「可达却未被测到」的纯逻辑行逐一钉死。
///
/// 全部用例只用固定 `DateTime`、内存替身与 `MockClient`，
/// **不依赖墙钟 / 随机 / 网络 / 真实设备**。
void main() {
  group('GAP 域模型补洞', () {
    test('GAP-01 振动图案超过步数上限 → 截断到前 32 步', () {
      // 33 步（奇数长度便于看出"截断到前 32 个"而不是"保留后半"）。
      final raw = <int>[for (var i = 0; i < 33; i++) i * 10];
      final a = VibrateAction.fromJson(<String, dynamic>{'patternMs': raw});
      expect(a.patternMs.length, VibrateLimits.maxPatternSteps);
      expect(a.patternMs.first, 0);
      expect(a.patternMs.last, 31 * 10);
      // 恰好等于上限时不截断（边界另一侧）。
      final exact = VibrateAction.fromJson(<String, dynamic>{
        'patternMs': <int>[for (var i = 0; i < 32; i++) i],
      });
      expect(exact.patternMs.length, 32);
      expect(exact.patternMs.last, 31);
    });

    test('GAP-02 声景轨只给分类时 assetId 归一化为 null', () {
      final track = SoundscapeTrack.fromJson(<String, dynamic>{
        'presetCategory': 'nature',
        'volume': 0.4,
        'loop': false,
      });
      expect(track, isNotNull);
      expect(track!.presetCategory, 'nature');
      expect(track.assetId, isNull, reason: '缺省 assetId 不能是空串');
      expect(track.volume, 0.4);
      expect(track.loop, isFalse);
      // assetId 非空 → 原样保留（同一行的另一侧）。
      final both = SoundscapeTrack.fromJson(<String, dynamic>{
        'presetCategory': 'nature',
        'assetId': 'asset-1',
      });
      expect(both!.assetId, 'asset-1');
      // 只给 assetId（分类缺省）也成立。
      final onlyId = SoundscapeTrack.fromJson(<String, dynamic>{
        'assetId': 'asset-2',
      });
      expect(onlyId!.presetCategory, isNull);
      expect(onlyId.assetId, 'asset-2');
      // 两源皆空 → 整轨被丢弃（不构造"指不到任何东西"的轨）。
      expect(
          SoundscapeTrack.fromJson(<String, dynamic>{
            'presetCategory': '',
            'assetId': '',
          }),
          isNull);
    });

    test('GAP-03 ConditionEnv 运行期构造（非 const）字段与默认值一致', () {
      // 用运行期值构造 ⇒ 走真实构造器体（全 const 调用会被编译期折叠）。
      final level = int.parse('42');
      final env = ConditionEnv(batteryLevel: level, onWifi: true);
      expect(env.batteryLevel, 42);
      expect(env.charging, isFalse);
      expect(env.inCall, isNull, reason: 'null = 无法判定，不是"没在通话"');
      expect(env.onWifi, isTrue);
      expect(env.toString(), contains('batteryLevel: 42'));
    });
  });

  group('GAP 远程脚本补洞', () {
    test('GAP-04 持续振动（区间未退化）文案带时长与强度区间', () {
      final label = rcVibrateStartLabel(<String, dynamic>{
        'mode': 'continuous',
        'durationSecMin': 5,
        'durationSecMax': 20,
        'amplitudeMin': 0.2,
        'amplitudeMax': 0.9,
      });
      expect(label, '持续振动 5–20 秒（强度 20%–90%）');
      // 退化区间（min == max 且无抖动）仍走"固定振动"文案，与上式区分。
      final fixed = rcVibrateStartLabel(<String, dynamic>{
        'mode': 'continuous',
        'durationSecMin': 8,
        'durationSecMax': 8,
        'amplitudeMin': 0.5,
        'amplitudeMax': 0.5,
        'jitterMs': 0,
      });
      expect(fixed, '固定振动 8 秒（强度 50%）');
    });
  });

  group('GAP 触发器时区形态补洞', () {
    test('GAP-05 小写 z 结尾按瞬时解释', () {
      final t = FixedOnceTrigger.fromJson(
          <String, dynamic>{'at': '2026-11-01T08:00:00z'});
      expect(t.at.toUtc(), DateTime.utc(2026, 11, 1, 8));
    });

    test('GAP-06 ±HHMM 偏移结尾按瞬时解释', () {
      final t = FixedOnceTrigger.fromJson(
          <String, dynamic>{'at': '2026-11-01T08:00:00+0800'});
      expect(t.at.toUtc(), DateTime.utc(2026, 11, 1, 0));
      // 带冒号的偏移同样命中（正则 `:?` 的另一侧）。
      final t2 = FixedOnceTrigger.fromJson(
          <String, dynamic>{'at': '2026-11-01T08:00:00-05:00'});
      expect(t2.at.toUtc(), DateTime.utc(2026, 11, 1, 13));
      // 无偏移的老数据保持"本地墙钟"语义（不进 hasZone 分支）。
      final legacy = FixedOnceTrigger.fromJson(
          <String, dynamic>{'at': '2026-11-01T08:00:00.000'});
      expect(legacy.at.hour, 8);
      expect(legacy.at.isUtc, isFalse);
    });
  });

  group('GAP 反击计划校验补洞', () {
    test('GAP-07 动作配比越界 → 报 0–1 错误', () {
      final plan = CounterPlan.defaults().copyWith(
        workdayDay: const CounterWindow(ttsWeight: 1.5, vibrateWeight: 0),
      );
      final errs = plan.validate();
      expect(
          errs,
          contains(
              '工作日·白天 动作配比（TTS/震动权重）必须在 0–1'));
    });

    test('GAP-08 震动强度越界 → 报 0–1 错误', () {
      final plan = CounterPlan.defaults().copyWith(
        workdayNight: const CounterWindow(
            vibrateAmplitudeMin: -0.2, vibrateAmplitudeMax: 0.5),
      );
      final errs = plan.validate();
      expect(errs, contains('工作日·夜间 震动强度必须在 0–1'));
      // 合法下限 0 不报错（边界另一侧）。
      final ok = CounterPlan.defaults().copyWith(
        workdayNight: const CounterWindow(
            vibrateAmplitudeMin: 0, vibrateAmplitudeMax: 0.5),
      );
      expect(ok.validate(), isEmpty);
    });
  });

  group('GAP 调度补洞', () {
    Task task(TriggerConfig trigger) => Task(
          id: 'task-gap',
          name: '测试任务',
          enabled: true,
          triggerType: TriggerType.randomInterval,
          trigger: trigger,
          actionType: ActionType.playAudio,
          action: const PlayAudioAction(),
          assetIds: const [],
          cooldownSec: 300,
          quietPolicy: QuietPolicy.skip,
          priority: 0,
          createdAt: DateTime(2026, 9, 1, 8),
          updatedAt: DateTime(2026, 9, 1, 8),
        );

    test('GAP-09 活动时段跨零点 → 终点用次日日历日', () {
      // 免打扰窗口置空，避免 22:00–07:00 把跨午夜条目全部 skip 掉。
      const engine = ScheduleEngine(quietStartHour: 0, quietEndHour: 0);
      final t = task(RandomIntervalTrigger(
        dateRange: DateRange(
            start: DateTime(2026, 9, 12), end: DateTime(2026, 9, 14)),
        minGap: const Duration(hours: 1),
        maxGap: const Duration(hours: 2),
        activeStart: const TimeSpec(hour: 22),
        activeEnd: const TimeSpec(hour: 6),
        maxPerDay: 4,
      ));
      final list = engine.materialize(t, DateTime(2026, 9, 12));
      expect(list, isNotEmpty);
      for (final e in list) {
        final h = e.fireAt.hour;
        expect(h >= 22 || h < 6, isTrue,
            reason: '跨午夜窗口外的条目：${e.fireAt}');
        // 终点是**次日** 06:00（日历日 +1），因此不可能落在 9/14 之后。
        expect(e.fireAt.isBefore(DateTime(2026, 9, 14, 6)), isTrue);
      }
    });

    test('GAP-10 单日展开超过 96 条 → 截断到上限', () {
      const plan = CounterPlan(
        cooldownSec: 0,
        workdayDay: CounterWindow(
          volumeMin: 0.5,
          volumeMax: 0.8,
          durationSecMin: 3,
          durationSecMax: 8,
          actionsPerHour: 12,
          ttsWeight: 0,
          vibrateWeight: 0,
        ),
        workdayNight: CounterWindow(
          volumeMin: 0.3,
          volumeMax: 0.5,
          durationSecMin: 3,
          durationSecMax: 5,
          actionsPerHour: 12,
          ttsWeight: 0,
          vibrateWeight: 0,
        ),
      );
      final list = CounterPlanMaterializer.materialize(
        plan,
        planId: 'gap96',
        from: DateTime(2026, 3, 10), // 周二 = 工作日
        days: 1,
        assetIdPool: const {'a1'},
        now: null,
      );
      expect(list.length, CounterPlanMaterializer.maxTasksPerDay);
      expect(list.length, 96);
      expect(list.map((t) => t.id).toSet().length, 96, reason: '截断后 id 不得重复');
    });
  });

  group('GAP 服务补洞', () {
    test('GAP-11 未注入音源解析器 → 默认空池，如实回报"没找到"', () async {
      SharedPreferences.setMockInitialValues({});
      final store = CounterPlanStore(await SharedPreferences.getInstance());
      final svc = CounterPlanService(tasks: _StubTasks(), store: store);
      // 各时段都不排震动 ⇒ 空音源池下一条都排不出来（纯音效计划）。
      const plan = CounterPlan(
        workdayDay: CounterWindow(
            volumeMin: 0.5,
            volumeMax: 0.8,
            durationSecMin: 3,
            durationSecMax: 8,
            actionsPerHour: 2,
            ttsWeight: 0,
            vibrateWeight: 0),
        workdayNight: CounterWindow(
            volumeMin: 0.3,
            volumeMax: 0.5,
            durationSecMin: 3,
            durationSecMax: 5,
            actionsPerHour: 1,
            ttsWeight: 0,
            vibrateWeight: 0),
      );
      expect(plan.validate(), isEmpty);
      final r = await svc.apply(plan,
          planId: 'gap11', now: DateTime(2026, 3, 10), days: 1);
      expect(r.ok, isFalse);
      expect(r.message, contains('没有找到'),
          reason: '默认解析器返回空集 ⇒ 必须如实说"音源没找到"');
    });

    test('GAP-12 DeepSeek 客户端抛异常 → 收敛为可读失败', () async {
      SharedPreferences.setMockInitialValues({'api_key': 'sk-test'});
      final svc = DeepSeekService(
        client: MockClient((r) async => throw const SocketException('断网')),
        config: ApiConfigStore(await SharedPreferences.getInstance()),
      );
      final r = await svc.generatePlan();
      expect(r.ok, isFalse);
      expect(r.message, contains('DeepSeek 请求异常'));
      expect(r.message, contains('断网'));
      expect(r.plan, isNull);
    });
  });

  group('GAP 节点测速补洞', () {
    test('GAP-13 只解析出 IPv6 → 回退取首个地址后如实返回 null', () async {
      // `::1` 是**数字字面量**，getaddrinfo 直接给出 IPv6 地址（无 DNS 查询），
      // 因此这个用例仍然离线且确定性。
      //
      // ⚠️ 但「本机把 `::1` 解析成 IPv6」是**环境前提**，不是被测行为：
      // 关闭 IPv6 的 Windows / 容器里 `lookup` 会抛 `SocketException`，
      // 或者只返回 IPv4 ⇒ 那是**环境不满足**，不是「代码坏了」。
      // 因此把前提显式自证 + 不满足就 `markTestSkipped`（判据本身不放松：
      // 只要前提成立，仍然断言 `stunLatency` 必须返回 null）。
      final List<InternetAddress> addrs;
      try {
        addrs = await InternetAddress.lookup('::1');
      } on SocketException {
        markTestSkipped('环境前提不满足：本机无 IPv6 回环（lookup 抛 SocketException）');
        return;
      }
      if (addrs.isEmpty || addrs.any((a) => a.type != InternetAddressType.IPv6)) {
        markTestSkipped('环境前提不满足：本机把 ::1 解析为非纯 IPv6（${addrs.length} 条）');
        return;
      }
      final ms = await NodeSpeedTest.stunLatency('::1', 3478,
          timeout: const Duration(seconds: 1));
      expect(ms, isNull, reason: '非 IPv4 目标不做 UDP 发送，直接放弃');
    });
  });
}

/// 只服务"校验前就返回"的用例：任何真实仓储调用都视为越界。
class _StubTasks implements TaskRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      '未预期的仓储调用：${invocation.memberName}');
}
