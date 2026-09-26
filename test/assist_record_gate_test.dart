import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/task_wire.dart';

import 'support/source_text.dart';

/// D-7 回归锁：`script` 位不得旁路 `record` 的拒绝（docs/22 §9 采集红线）。
///
/// 缺陷形状：命令级门控把 `task.upsert`/`task.runNow` 都映射到 `script` 位，
/// 而任务动作类型此前**没有任何协助会话裁决** —— 只放行 `script` 一个位的
/// 协助方可借 `task.upsert`（写入 `actionType:'recordEvidence'` 的任务）+
/// `task.runNow` 触发录音，绕开步骤级闸门对 `record` 的 `denyAll`。
///
/// 修复：判定（`TaskWire.requiredPermBitsForTaskAction`，纯函数）与接线
/// （`assist_host._onBusiness` 的 `_taskPayloadDeny`）分离。
///
/// 变异证伪点：
/// - 把接线从 `_onBusiness` 删掉 → RG-05 源码锁红；
/// - 把 `case 'record'` 的映射改成 `{}` → RG-01/RG-02 红；
/// - 把整个函数改成恒返回 `{}`（"只查 script" 的等价回归）→ RG-02 红；
/// - 过度加码（play/tts 也要位）→ RG-02 的放行臂红（防误伤正常协助流）。
// `stripComments` 见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源，
// 勿再在本文件复制 —— 此前仓内散落 16 份副本，修一处漏十五处）。

/// 手写一份 record 动作 JSON（不经过领域模型，防 toJson 漂移掩盖判定缺口）。
const _rawRecordAction = {'kind': 'record', 'seconds': 60};

const _rawPlayAction = {
  'kind': 'play',
  'volumeMin': 0.6,
  'volumeMax': 1.0,
};

void main() {
  group('RG D-7 任务动作录音闸门', () {
    test('RG-01 recordEvidence ⇒ 所需位集合为 {"record"}', () {
      // 经领域模型 toJson（真实序列化路径）。
      expect(TaskWire.requiredPermBitsForTaskAction(
          const RecordEvidenceAction(seconds: 60).toJson()),
          {'record'});
      // 手写线格式 JSON（对端可发任意形状）。
      expect(TaskWire.requiredPermBitsForTaskAction(_rawRecordAction),
          {'record'});
      expect(
          TaskWire.requiredPermBitsForTaskAction(
              ActionConfig.fromJson(_rawRecordAction).toJson()),
          {'record'});
    });

    test('RG-02 2×2 穷举：含 recordEvidence × record 位有/无', () {
      bool Function(String) granted(Set<String> bits) =>
          (String bit) => bits.contains(bit);
      // 含 recordEvidence：
      //   无 record 位 ⇒ 拒绝（缺位名必须明确指出）。
      expect(
          TaskWire.firstMissingPermBit(
              TaskWire.requiredPermBitsForTaskAction(_rawRecordAction),
              granted({})),
          'record');
      //   有 record 位 ⇒ 放行（反面断言：锁非恒真；模拟将来引入
      //   独立 record 位并显式授权后的合法对端）。
      expect(
          TaskWire.firstMissingPermBit(
              TaskWire.requiredPermBitsForTaskAction(_rawRecordAction),
              granted({'record'})),
          isNull);
      // 不含 recordEvidence（播放）：有无 record 位都放行（防过度加码）。
      expect(
          TaskWire.firstMissingPermBit(
              TaskWire.requiredPermBitsForTaskAction(_rawPlayAction),
              granted({})),
          isNull);
      expect(
          TaskWire.firstMissingPermBit(
              TaskWire.requiredPermBitsForTaskAction(_rawPlayAction),
              granted({'record'})),
          isNull);
    });

    test('RG-03 真实权限模型：8 位全开也放行不了 record，script 位救不了它', () {
      const scriptOnly = AssistPerms(script: true);
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
      for (final p in [AssistPerms.none, scriptOnly, allOn]) {
        expect(
            TaskWire.firstMissingPermBit(
                TaskWire.requiredPermBitsForTaskAction(_rawRecordAction),
                (bit) => RcPermGate.hasPerm(p, bit)),
            'record',
            reason: 'record 不是任何权限位：协助会话下录音一律拒绝（docs/22 §9）');
      }
      // 正常动作不受影响：script-only 协助方仍可写播放任务（向后兼容）。
      expect(
          TaskWire.firstMissingPermBit(
              TaskWire.requiredPermBitsForTaskAction(_rawPlayAction),
              (bit) => RcPermGate.hasPerm(scriptOnly, bit)),
          isNull);
    });

    test('RG-04 嵌套动作必须递归（composite / randomFrom 藏 record 也得拦）', () {
      final compositeRecord = {
        'kind': 'composite',
        'primary': _rawRecordAction,
      };
      expect(TaskWire.requiredPermBitsForTaskAction(compositeRecord),
          {'record'});
      final setWithRecord = {
        'kind': 'randomFrom',
        'candidates': [
          {'weight': 1.0, 'action': _rawPlayAction},
          {'weight': 1.0, 'action': _rawRecordAction},
        ],
      };
      expect(TaskWire.requiredPermBitsForTaskAction(setWithRecord), {'record'});
      // 不含 record 的嵌套动作不加码。
      final compositePlay = {
        'kind': 'composite',
        'primary': _rawPlayAction,
        'prefixNotify': {'kind': 'notify', 'title': 'a', 'body': 'b'},
      };
      expect(
          TaskWire.requiredPermBitsForTaskAction(compositePlay), isEmpty);
    });

    test('RG-05 源码锁：assist_host._onBusiness 确实接上了动作级裁决', () {
      final host = stripComments(
          File('lib/remote/assist_host.dart').readAsStringSync());
      // 接线点必须调用纯判定（注释被剥掉，剩下的才是真调用）。
      expect(host.contains('_taskPayloadDeny(s.perms, msg)'), isTrue,
          reason: 'D-7 裁决必须挂在 _onBusiness 的命令级门控之后；'
              '删掉这行 = 重新打开"script 位触发录音"的旁路');
      expect(host.contains('requiredPermBitsForTaskAction'), isTrue,
          reason: '裁决必须由 TaskWire.requiredPermBitsForTaskAction 推导所需位，'
              '不许改回只查 script');
      // 判定侧必须真的存在（防有人把实现一并删掉只留调用）。
      final wire = stripComments(
          File('lib/remote/task_wire.dart').readAsStringSync());
      expect(wire.contains('Set<String> requiredPermBitsForTaskAction'),
          isTrue);
      expect(wire.contains("case 'record':"), isTrue,
          reason: 'record → record 位的映射不得被移除');
    });
  });
}
