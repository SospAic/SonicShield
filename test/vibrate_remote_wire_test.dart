import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/remote/task_wire.dart';

/// 振动动作的**远程线格式**回归锁（v1.9，docs/20 §11.3）。
///
/// ## 为什么这个文件必须存在
///
/// `ActionConfig` 的区间约束**只由 `assert` 表达**，而 release 构建会剥离
/// assert。对端发来自相矛盾的振动参数时：
/// - debug：构造期抛错（看起来"有保护"）；
/// - release：静默写入 DB → 物化期崩。
/// 两条路径行为不一致，唯一的统一防线是 `TaskWire._sanitizeActionMap`
/// 在**构造前**夹紧原始 JSON。
///
/// 而"给新 kind 补分支"这件事**不编译报错**（`switch` 带 `default:`），
/// 落进去就是原样透传 —— 属于项目纪律里"只能靠锁"的那一类。
/// 本文件把"每个动作 kind 都被夹紧"变成可断言的量。
void main() {
  // ---------------- 夹具 ----------------

  Map<String, dynamic> wire({
    required Map<String, dynamic> action,
    ActionType actionType = ActionType.vibrate,
  }) =>
      {
        'id': 't1',
        'name': '振动任务',
        'enabled': true,
        'triggerType': TriggerType.dailyAt.name,
        'trigger': const DailyTrigger(time: TimeSpec(hour: 8, minute: 30)).toJson(),
        'actionType': actionType.name,
        'action': action,
        'assetIds': const <String>[],
        'cooldownSec': 300,
        'quietPolicy': QuietPolicy.skip.name,
        'priority': 0,
      };

  /// 走一遍线格式，返回解析出的动作（不合法返回 null）。
  ActionConfig? parse(Map<String, dynamic> action) =>
      TaskWire.fromWire(wire(action: action))?.action;

  // ---------------- 用例 ----------------

  group('VW 振动线格式夹紧', () {
    test('VW-01 随机振动：越界参数被夹紧，且构造不抛（release 下 assert 已剥离）',
        () {
      final a = parse({
        'kind': 'randomVibrate',
        'durationSecMin': -5,
        'durationSecMax': 999999999,
        'pulseOnMsMin': 1,
        'pulseOnMsMax': 999999,
        'pulseOffMsMin': -3,
        'pulseOffMsMax': 999999,
        'amplitudeMin': -2,
        'amplitudeMax': 7,
        'maxPulses': 0,
        'rampUpSec': -1,
      });
      expect(a, isA<RandomVibrateAction>());
      final v = a! as RandomVibrateAction;
      // 关键：**构造成功**本身就是判据 —— 自相矛盾的参数在 debug 会抛。
      expect(v.durationSecMin, greaterThanOrEqualTo(1));
      expect(v.durationSecMax, lessThanOrEqualTo(VibrateLimits.maxDurationSec));
      expect(v.durationSecMin, lessThanOrEqualTo(v.durationSecMax));
      expect(v.pulseOnMsMin, greaterThanOrEqualTo(VibrateLimits.minPulseOnMs));
      expect(v.pulseOnMsMax, lessThanOrEqualTo(VibrateLimits.maxPulseOnMs));
      expect(v.pulseOnMsMin, lessThanOrEqualTo(v.pulseOnMsMax));
      expect(v.pulseOffMsMin, greaterThanOrEqualTo(0));
      expect(v.pulseOffMsMax, lessThanOrEqualTo(VibrateLimits.maxPulseOffMs));
      expect(v.amplitudeMin, greaterThanOrEqualTo(0));
      expect(v.amplitudeMax, lessThanOrEqualTo(1));
      expect(v.amplitudeMin, lessThanOrEqualTo(v.amplitudeMax));
      expect(v.maxPulses, inInclusiveRange(1, VibrateLimits.maxPulses));
      expect(v.rampUpSec, inInclusiveRange(0, VibrateLimits.maxRampSec));
    });

    test('VW-02 上下界反转被换回（对端发 amplitudeMin>amplitudeMax）', () {
      final a = parse({
        'kind': 'continuousVibrate',
        'amplitudeMin': 0.9,
        'amplitudeMax': 0.2,
        'durationSecMin': 30,
        'durationSecMax': 10,
      })! as ContinuousVibrateAction;
      // 换回后仍然"表达同一个意图"，但不再自相矛盾。
      expect(a.amplitudeMin, lessThanOrEqualTo(a.amplitudeMax));
      expect(a.amplitudeMin, closeTo(0.2, 1e-9));
      expect(a.amplitudeMax, closeTo(0.9, 1e-9));
      expect(a.durationSecMin, lessThanOrEqualTo(a.durationSecMax));
      expect(a.durationSecMin, 10);
      expect(a.durationSecMax, 30);
    });

    test('VW-03 持续振动：抖动/锐度/占空比/渐强渐弱全部夹紧', () {
      final a = parse({
        'kind': 'continuousVibrate',
        'jitterMs': 99999999,
        'sharpnessMin': 5,
        'sharpnessMax': -5,
        'dutyCyclePct': 0,
        'rampUpSec': 99999,
        'rampDownSec': -7,
      })! as ContinuousVibrateAction;
      expect(a.jitterMs, inInclusiveRange(0, VibrateLimits.maxJitterMs));
      expect(a.sharpnessMin, greaterThanOrEqualTo(0));
      expect(a.sharpnessMax, lessThanOrEqualTo(1));
      expect(a.sharpnessMin, lessThanOrEqualTo(a.sharpnessMax));
      expect(a.dutyCyclePct, inInclusiveRange(10, 100));
      expect(a.rampUpSec, inInclusiveRange(0, VibrateLimits.maxRampSec));
      expect(a.rampDownSec, inInclusiveRange(0, VibrateLimits.maxRampSec));
    });

    test('VW-04 入站 respectDnd 一律强制 true（远程不得绕过本机勿扰护栏）', () {
      for (final kind in ['randomVibrate', 'continuousVibrate']) {
        final a = parse({'kind': kind, 'respectDnd': false})!;
        final respect = switch (a) {
          final RandomVibrateAction v => v.respectDnd,
          final ContinuousVibrateAction v => v.respectDnd,
          _ => fail('kind=$kind 解析成了 ${a.runtimeType}'),
        };
        expect(respect, isTrue,
            reason: 'kind=$kind 让对端关掉了「遵循勿扰」—— 与 quietExempt 同类红线');
      }
      // 缺失也必须是 true（fail-safe 一侧，不能因为"没写"就当成 false）。
      expect((parse({'kind': 'randomVibrate'})! as RandomVibrateAction).respectDnd,
          isTrue);
    });

    test('VW-05 inboundDndDowngrade 能识别"试图关闭勿扰"，含嵌套动作', () {
      expect(TaskWire.inboundDndDowngrade({'kind': 'randomVibrate'}), isFalse);
      expect(TaskWire.inboundDndDowngrade({'kind': 'randomVibrate', 'respectDnd': true}),
          isFalse);
      expect(TaskWire.inboundDndDowngrade({'kind': 'randomVibrate', 'respectDnd': false}),
          isTrue);
      // 畸形值不算"想关"（夹紧后同样是 true，不构成下放）。
      expect(TaskWire.inboundDndDowngrade({'kind': 'randomVibrate', 'respectDnd': 'no'}),
          isFalse);
      // composite 的 primary 里藏一个 —— 不递归就漏。
      expect(
          TaskWire.inboundDndDowngrade({
            'kind': 'composite',
            'primary': {'kind': 'continuousVibrate', 'respectDnd': false},
          }),
          isTrue);
      // 非动作输入不炸。
      expect(TaskWire.inboundDndDowngrade(null), isFalse);
      expect(TaskWire.inboundDndDowngrade('nope'), isFalse);
    });
  });

  group('VW 嵌套动作必须递归夹紧（BUG-072）', () {
    test('VW-06 randomFrom 里的候选动作同样被夹紧', () {
      final a = parse({
        'kind': 'randomFrom',
        'candidates': [
          {
            'weight': 1.0,
            'action': {
              'kind': 'continuousVibrate',
              'amplitudeMin': 5,
              'amplitudeMax': -1,
              'durationSecMax': 999999999,
            }
          },
          {
            'weight': 2.0,
            'action': {'kind': 'vibrate', 'patternMs': [0, 100]},
          },
        ],
      });
      // 变异证伪记录（2026-09-22 实测）：把 `case 'randomFrom':` 改名使其落回
      // `default:` → 本用例红。注意失败形态是 `Actual: <null>` 而不是"未夹紧的值"：
      // **debug 下 `ActionConfig.fromJson` 的 assert 会先抛 → fromWire 捕获后
      // 拒绝整条任务**；只有 release（assert 被剥离）才会变成"自相矛盾动作
      // 静默写进 DB"。两种形态都被本用例覆盖，所以它既是 debug 锁也是 release 锁。
      expect(a, isA<ActionSetAction>());
      final set = a! as ActionSetAction;
      final inner = set.candidates.first.action;
      expect(inner, isA<ContinuousVibrateAction>());
      final c = inner as ContinuousVibrateAction;
      expect(c.amplitudeMin, greaterThanOrEqualTo(0));
      expect(c.amplitudeMax, lessThanOrEqualTo(1));
      expect(c.amplitudeMin, lessThanOrEqualTo(c.amplitudeMax));
      expect(c.durationSecMax, lessThanOrEqualTo(VibrateLimits.maxDurationSec));
    });

    test('VW-07 动作集结构非法一律拒绝（候选数越界 / 缺 action）', () {
      ActionConfig? one(List<Map<String, dynamic>> cs) =>
          parse({'kind': 'randomFrom', 'candidates': cs});

      expect(
          one([
            {'weight': 1, 'action': {'kind': 'vibrate'}}
          ]),
          isNull,
          reason: '只有 1 个候选没有随机意义，且违反模型 assert');

      expect(
          one([
            for (var i = 0; i < TaskWire.maxActionSetCandidates + 1; i++)
              {'weight': 1, 'action': {'kind': 'vibrate'}}
          ]),
          isNull);

      expect(one([
        {'weight': 1},
        {'weight': 1, 'action': {'kind': 'vibrate'}},
      ]), isNull);

      // 权重是畸形值 → 夹到合法区间而不是整条拒绝。
      final ok = one([
        {'weight': 'heavy', 'action': {'kind': 'vibrate'}},
        {'weight': 1e400, 'action': {'kind': 'vibrate'}},
      ]);
      expect(ok, isA<ActionSetAction>());
      for (final c in (ok! as ActionSetAction).candidates) {
        expect(c.weight.isFinite, isTrue, reason: '权重必须是有限数（Infinity 会让选中逻辑失效）');
        expect(c.weight, greaterThanOrEqualTo(0));
      }
    });

    test('VW-08 composite 的 primary 也被夹紧', () {
      final a = parse({
        'kind': 'composite',
        'primary': {
          'kind': 'randomVibrate',
          'amplitudeMin': 9,
          'amplitudeMax': 9,
          'maxPulses': 99999,
        },
      })! as CompositeAction;
      final p = a.primary as RandomVibrateAction;
      expect(p.amplitudeMax, lessThanOrEqualTo(1));
      expect(p.maxPulses, lessThanOrEqualTo(VibrateLimits.maxPulses));
    });
  });

  group('VW 覆盖锁：新动作 kind 不得静默落进 default', () {
    /// 取出 `_sanitizeActionMap` 的函数体文本。
    ///
    /// ⚠️ 起点必须包含 `) {` —— 只找"签名后第一个 `{`"会被泛型实参里的
    /// 括号/花括号骗到（本仓库有过一次这样的工具自伤）。
    String sanitizeBody(String src) {
      const sig = '_sanitizeActionMap(Map<String, dynamic> j) {';
      final start = src.indexOf(sig);
      if (start < 0) {
        throw StateError('找不到 `$sig` —— 函数被改名/改签名了，锁已失效，请同步更新');
      }
      final open = start + sig.length - 1;
      var depth = 0;
      for (var i = open; i < src.length; i++) {
        final ch = src[i];
        if (ch == '{') {
          depth++;
        } else if (ch == '}') {
          depth--;
          if (depth == 0) return src.substring(open, i + 1);
        }
      }
      throw StateError('`_sanitizeActionMap` 函数体未闭合');
    }

    final src = File('lib/remote/task_wire.dart').readAsStringSync();
    final body = sanitizeBody(src);

    /// 每个具体动作类型的线格式 kind（**从 `toJson()` 现取**，不抄字面量）。
    final probes = <ActionConfig>[
      const PlayAudioAction(),
      const TtsAction(text: 'x'),
      const NotifyAction(title: 't', body: 'b'),
      const RecordEvidenceAction(),
      const VibrateAction(),
      const RandomVibrateAction(),
      const ContinuousVibrateAction(),
      const CompositeAction(primary: VibrateAction()),
      // ⚠️ 这两个**不能加 `const`**：构造函数体里有 `tracks.length` /
      // `candidates.length` 断言，常量求值期访问不了 `.length`。
      SoundscapeAction(tracks: const [SoundscapeTrack(presetCategory: 'nature')]),
      ActionSetAction(candidates: const [
        ActionSetCandidate(weight: 1, action: VibrateAction()),
        ActionSetCandidate(weight: 1, action: VibrateAction()),
      ]),
    ];

    test('VW-09 防空转哨兵：`lib/domain/models/action.dart` 里的子类数 == 探针数', () {
      // 新增一个 ActionConfig 子类而没回来登记 → 这条会红。
      // 没有它，下面的"每个 kind 都有 case"会在新子类上变成恒真。
      final decls = RegExp(r'^class \w+ extends ActionConfig \{',
              multiLine: true)
          .allMatches(File('lib/domain/models/action.dart').readAsStringSync())
          .length;
      expect(decls, probes.length,
          reason: 'ActionConfig 子类数（$decls）与探针数（${probes.length}）不一致 —— '
              '新增/删除子类后请同步本文件的 `probes`，否则覆盖锁会静默失效');
    });

    test('VW-10 每个动作 kind 在 `_sanitizeActionMap` 都有显式 `case`', () {
      final kinds = [for (final p in probes) p.toJson()['kind'] as String];
      final missing = [
        for (final k in kinds)
          if (!body.contains("case '$k':")) k,
      ];
      expect(missing, isEmpty,
          reason: '这些动作 kind 没有夹紧分支 → 落进 `default:` 原样透传 → '
              'release 下 assert 被剥离，自相矛盾配置写入 DB 后物化期崩：$missing');
    });

    test('VW-11 覆盖锁不得恒真：故意把已知 kind 从 `case` 列表里剔掉会红', () {
      // 反向自检 —— 证明 VW-10 真的在检查东西，而不是 `body` 取空了。
      expect(body.length, greaterThan(200), reason: '函数体解析异常（太短）');
      final stripped = body.replaceAll("case 'randomVibrate':", '');
      expect(stripped.contains("case 'randomVibrate':"), isFalse);
      expect(body.contains("case 'randomVibrate':"), isTrue);
    });
  });
}
