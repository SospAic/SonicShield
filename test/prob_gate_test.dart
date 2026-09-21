import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/condition.dart';

/// 概率门 hasAny 语义锁定（独立文件：避免宿主 dart 缓存与编辑器用例互扰）。
void main() {
  test('P<100 参与 hasAny', () {
    const c = TaskCondition(probabilityPct: 30);
    expect(c.hasAny, isTrue);
  });

  test('P=100 且无其它条件 → hasAny false（必执行无需条件）', () {
    const c = TaskCondition(probabilityPct: 100, skipInCall: false);
    expect(c.hasAny, isFalse);
  });

  test('describe 含概率文案', () {
    const c = TaskCondition(probabilityPct: 30);
    expect(c.describe(), contains('概率 30%'));
  });

  test('toJson 序列化概率字段（契约：非 null 即写，含 100）', () {
    const c = TaskCondition(probabilityPct: 30, skipInCall: false);
    expect(c.toJson()['probabilityPct'], 30);
    const c100 = TaskCondition(probabilityPct: 100, skipInCall: false);
    expect(c100.toJson()['probabilityPct'], 100);
  });
}
