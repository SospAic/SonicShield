import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/rc_script.dart';

import 'support/source_text.dart';

/// P0-2 回归锁（步骤级权限的**覆盖性**）。
///
/// 缺陷形状：`RcPermGate.requiredStepPerm` 一度**零调用点**，于是只放行
/// `script` 位的对端可借 `script.run` 完成**录音取证**（`denyAll`）等操作。
/// 该接线已由另一 agent 在 `endpoint_service.dart` 的 runner 里补齐
/// （`gateRcScriptStep`，其回归锁见 `endpoint_script_step_perm_test.dart`）——
/// **本文件不重复实现，只补一条"覆盖性"锁**：
///
/// 每个 [RcStepKind] 要么在 `requiredStepPerm` 里有明确映射，要么落在**显式**
/// 允许清单内。这样"新增一个步骤类型却忘了登记权限"会立刻变红，而不是默默
/// 落到某个 `_ => null`（= 免授权放行）上。
///
/// 变异证伪点：
/// - 删掉 `requiredStepPerm` 里任一条 arm → 对应 kind 落到"未登记" → 红；
/// - 新增 `_ => null` 兜底 → `SPL-02` 源码锁红（禁止 catch-all）；
/// - 把 `record` 从 `denyAll` 改成 `null` → `SPL-03` 红。
///
/// ⚠️ 这里**不能用** `source_text.dart` 的 `methodBody`：`requiredStepPerm` 是
/// **表达式体**（`=> switch (kind) {`），而 `methodBody` 对表达式体显式抛错
/// （它的契约只服务块体）。故本文件自带一个"取 switch 体"的小工具，
/// 复用共享真源的 `stripComments`。
String _switchBody(String src, String marker) {
  final i = src.indexOf(marker);
  if (i < 0) throw StateError('找不到 `$marker`');
  final open = src.indexOf('{', i);
  if (open < 0) throw StateError('`$marker` 之后找不到 `{`');
  final m = RegExp(r'\n\s*\};').firstMatch(src.substring(open));
  if (m == null) throw StateError('`$marker` 的 switch 体未闭合');
  // 返回前**必须剥注释**：注释里出现的 `_ =>` 不是登记，否则禁止性断言会被
  // 一句说明注释打成假红（第 35 轮 W5 审计的同类缺陷）。
  return stripComments(src.substring(open + 1, open + m.start));
}

/// 明确允许"无需权限位"的步骤类型（只读/无害）。
///
/// ⚠️ 这是**白名单**：新增类型若不在此列，就必须在 `requiredStepPerm` 里
/// 给出映射，否则测试红。
const _noPermNeeded = <RcStepKind>{RcStepKind.delay, RcStepKind.notify};

void main() {
  group('SPL 步骤权限覆盖性（P0-2）', () {
    test('SPL-01 每个 RcStepKind 都被显式裁决（有映射 或 在白名单内）', () {
      final uncovered = <RcStepKind>[];
      for (final k in RcStepKind.values) {
        final need = RcPermGate.requiredStepPerm(k);
        if (need == null && !_noPermNeeded.contains(k)) uncovered.add(k);
      }
      expect(uncovered, isEmpty,
          reason: '以下步骤类型既无权限映射、也不在免授权白名单内 → '
              '它们会落到未定义的放行语义：$uncovered');
    });

    test('SPL-02 requiredStepPerm 不得有 catch-all 兜底（禁止静默放行）', () {
      final src = File('lib/remote/assist.dart').readAsStringSync();
      final body =
          _switchBody(src, 'static String? requiredStepPerm(RcStepKind kind)');
      expect(body.contains('_ =>'),
          isFalse,
          reason: '兜底 `_ =>` 会让"新增类型忘记登记"变成静默放行；'
              '枚举 switch 必须是穷尽的，新增类型应触发编译错误');
    });

    test('SPL-03 record（录音取证）在协助会话下一律拒绝', () {
      expect(RcPermGate.requiredStepPerm(RcStepKind.record),
          RcPermGate.denyAll);
      // 任何真实权限位都放行不了它。
      const allOn = AssistPerms(
        media: true,
        tts: true,
        vibrate: true,
        volume: true,
        location: true,
        video: true,
        script: true,
        audit: true,
      );
      expect(RcPermGate.hasPerm(allOn, RcPermGate.denyAll), isFalse);
      expect(gateRcScriptStep(RcStepKind.record, perms: allOn).allowed, isFalse);
    });

    test('SPL-04 白名单里的步骤在全拒权限下仍放行（不得误拒只读步骤）', () {
      for (final k in _noPermNeeded) {
        expect(RcPermGate.requiredStepPerm(k), isNull, reason: '$k 应为免授权');
        expect(gateRcScriptStep(k, perms: AssistPerms.none).allowed, isTrue,
            reason: '$k 只读；若实现直接 hasPerm(perms, null) 会误拒');
      }
    });
  });
}
