import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/device_group.dart';
import 'package:sonic_shield/remote/remote_store.dart';

import 'support/source_text.dart';

/// Q6.B「设备组 + 群发命令」回归锁。
///
/// 锁三件事：
/// 1. 模型与存取往返（`rc:group:<id>` 一组一条，坏条目跳过不崩）；
/// 2. 判定纯函数穷举（[resolveGroupTargets] 的交集/去重/保序，
///    [validateGroupName] 的边界）；
/// 3. 接线源码锁（剥注释后 `device_list_screen.dart` 必须真的调用
///    `resolveGroupTargets` 与 `sendTo`）——组名单元测得再好，
///    UI 绕开判定直接拿 memberIds 发，锁也白搭。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PairedEndpoint ep(String id) => PairedEndpoint(
        deviceId: id,
        name: '设备$id',
        secret: 's-$id',
        pairedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  group('Q6.G 模型与存取往返', () {
    test('G1 toJson/fromJson 往返等值', () {
      const g = DeviceGroup(
          id: 'g1', name: '展厅', memberIds: ['a', 'b', 'c']);
      final back = DeviceGroup.fromJson(g.toJson());
      expect(back.id, 'g1');
      expect(back.name, '展厅');
      expect(back.memberIds, ['a', 'b', 'c']);
    });

    test('G2 存取往返：save -> groups 读回同一组', () async {
      SharedPreferences.setMockInitialValues({});
      final s = DeviceGroupStore(await SharedPreferences.getInstance());
      await s.save(const DeviceGroup(
          id: 'gA', name: '一楼', memberIds: ['a', 'b']));
      await s.save(const DeviceGroup(id: 'gB', name: '二楼', memberIds: ['c']));
      final all = s.groups();
      expect(all.map((g) => g.name), ['一楼', '二楼']); // 按组名确定序
      final a = s.byId('gA');
      expect(a, isNotNull);
      expect(a!.memberIds, ['a', 'b']);
      expect(s.byId('不存在'), isNull);
      expect(s.byId(''), isNull, reason: '空 id 直接返回 null，不查表');
    });

    test('G3 同 id 覆盖 + delete 生效', () async {
      SharedPreferences.setMockInitialValues({});
      final s = DeviceGroupStore(await SharedPreferences.getInstance());
      await s.save(const DeviceGroup(id: 'g1', name: '旧名', memberIds: ['a']));
      await s.save(const DeviceGroup(id: 'g1', name: '新名', memberIds: []));
      expect(s.groups().length, 1);
      expect(s.groups().first.name, '新名');
      await s.delete('g1');
      expect(s.groups(), isEmpty);
    });

    test('G4 坏 JSON 条目跳过不崩', () async {
      SharedPreferences.setMockInitialValues({
        'rc:group:bad': '{不是 JSON',
        'rc:group:ok':
            '{"id":"g1","name":"好组","memberIds":["a"]}',
        'rc:other': '无关键',
      });
      final s = DeviceGroupStore(await SharedPreferences.getInstance());
      final all = s.groups();
      expect(all.length, 1);
      expect(all.first.name, '好组');
    });
  });

  group('Q6.R resolveGroupTargets（穷举）', () {
    test('R1 空组 -> 空表', () {
      const g = DeviceGroup(id: 'g', name: 'x', memberIds: []);
      expect(resolveGroupTargets(g, [ep('a'), ep('b')]), isEmpty);
    });

    test('R2 全命中：按组内名单原序输出', () {
      const g = DeviceGroup(id: 'g', name: 'x', memberIds: ['c', 'a']);
      final out = resolveGroupTargets(g, [ep('a'), ep('b'), ep('c')]);
      expect(out, ['c', 'a'], reason: '保序 = 组内名单序，不是配对表序');
    });

    test('R3 部分离线：剔除未配对成员', () {
      const g = DeviceGroup(
          id: 'g', name: 'x', memberIds: ['a', 'gone', 'b']);
      expect(resolveGroupTargets(g, [ep('a'), ep('b')]), ['a', 'b']);
    });

    test('R4 重复成员：去重且只留首现位置', () {
      const g = DeviceGroup(
          id: 'g', name: 'x', memberIds: ['a', 'b', 'a', 'b', 'a']);
      expect(resolveGroupTargets(g, [ep('a'), ep('b')]), ['a', 'b'],
          reason: '去重避免同一台被连发两条 Ping');
    });

    test('R5 配对表为空（全部离线）-> 空表', () {
      const g = DeviceGroup(id: 'g', name: 'x', memberIds: ['a']);
      expect(resolveGroupTargets(g, const <PairedEndpoint>[]), isEmpty);
    });
  });

  group('Q6.V validateGroupName（边界）', () {
    test('V1 空串 / 纯空白 -> 错误文案', () {
      expect(validateGroupName(''), isNotEmpty);
      expect(validateGroupName('   '), isNotEmpty);
    });

    test('V2 恰 20 字合法，21 字报错', () {
      expect(validateGroupName('一' * 20), '');
      expect(validateGroupName('一' * 21), isNotEmpty);
    });

    test('V3 首尾空白会被 trim，trim 后合法即通过', () {
      expect(validateGroupName('  展厅  '), '');
    });
  });

  group('Q6.L 接线源码锁（剥注释后扫描 device_list_screen.dart）', () {
    final src = File('lib/features/remote/device_list_screen.dart')
        .readAsStringSync();

    /// 剥 `//` 与 `/* */` 注释；字符串字面量保留（接线必然出现在代码里，
    /// 而本项目注释里会写"必须调用 resolveGroupTargets"这类说明文字，
    /// 不剥会把锁自己的说明当成违规，逼人删注释 —— 锁变负资产）。
    ///
    /// 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。
    final code = stripComments(src);

    test('L1 正例：UI 走 resolveGroupTargets 取群发目标', () {
      expect(code.contains('resolveGroupTargets'), isTrue,
          reason: '组名单只是收藏，群发目标必须经判定纯函数 ∩ 当前配对表');
    });

    test('L2 正例：逐台 sendTo 群发', () {
      expect(code.contains('sendTo'), isTrue,
          reason: '群发必须逐台走 RcEndpointService.sendTo（含 outbox 语义）');
    });

    test('L3 反例：群发路径不得直接读 memberIds 绕过判定', () {
      final i = code.indexOf('_groupPing');
      expect(i, greaterThanOrEqualTo(0));
      final body = code.substring(i, code.indexOf('@override', i));
      expect(body.contains('memberIds'), isFalse,
          reason: '群发目标只能来自 resolveGroupTargets —— '
              '直接拿组名单发/计数，会把已解配对的成员算进"已发 N 台"');
    });

    test('L4 反例：建组名必须过 validateGroupName，不得绕开', () {
      expect(code.contains('validateGroupName'), isTrue,
          reason: '判定与接线分离的前提是接线真的调用判定');
    });
  });
}
