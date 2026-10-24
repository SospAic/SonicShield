import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/data/prefs/json_list_codec.dart';

/// R96 覆盖率补齐：`lib/data/prefs/json_list_codec.dart`（DAT-09）。
///
/// ## 为什么需要它
///
/// prefs 里"一个键存一个 JSON 数组"的旧写法是
/// `jsonDecode(raw) as List` 外面套 `catch { return []; }` —— 任意一条
/// 坏记录都会让整表变空，而空表一旦被写回就是**永久丢数据**
/// （配对授权丢失 / 撤销名单失效 / 待发命令消失）。
/// `JsonListCodec` 把容错粒度改成**逐条**，本文件锁定这套口径：
///
/// - 整体不可解析 ⇒ `unparsable`，调用方**不得**把空表写回；
/// - 逐条坏 ⇒ `dropped` 计数 + `onBadItem` 留痕，好条目照常返回；
/// - 编解码对称：`encode` 的产物必须能被 `decode` 原样读回。
class _Item {
  _Item(this.id, this.name);

  final String id;
  final String name;

  /// 与线上 `PairedEndpoint.fromJson` 同型：类型不符返回 null（丢这一条）。
  static _Item? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;
    return _Item(id, name);
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is _Item && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

void main() {
  group('R96 JsonListCodec 覆盖率补齐', () {
    test('COV-01 raw 为 null ⇒ 空表、无丢失、不可写回判定不触发', () {
      final r = JsonListCodec.decode<_Item>(null, _Item.fromJson);

      expect(r.items, isEmpty);
      expect(r.dropped, 0);
      expect(r.unparsable, isFalse,
          reason: 'null 只是"没存过"，不是坏读，不应触发禁写回');
      expect(r.hasLoss, isFalse);
    });

    test('COV-02 raw 为空串/纯空白 ⇒ 与 null 同口径', () {
      for (final raw in const ['', '   ', '\n\t ']) {
        final r = JsonListCodec.decode<_Item>(raw, _Item.fromJson);
        expect(r.items, isEmpty, reason: 'raw=$raw');
        expect(r.dropped, 0);
        expect(r.unparsable, isFalse, reason: 'raw=$raw');
        expect(r.hasLoss, isFalse, reason: 'raw=$raw');
      }
    });

    test('COV-03 encode/decode 往返：顺序保持、无丢失', () {
      final items = [
        _Item('a', '甲'),
        _Item('b', '乙'),
        _Item('c', '丙'),
      ];

      final encoded = JsonListCodec.encode<_Item>(items, (i) => i.toJson());
      expect(encoded,
          '[{"id":"a","name":"甲"},{"id":"b","name":"乙"},{"id":"c","name":"丙"}]');

      final r = JsonListCodec.decode<_Item>(encoded, _Item.fromJson);
      expect(r.items, items, reason: '往返后必须原样且保持原顺序');
      expect(r.dropped, 0);
      expect(r.unparsable, isFalse);
      expect(r.hasLoss, isFalse);
    });

    test('COV-04 encode 空列表 ⇒ "[]"，可被 decode 回空表', () {
      final encoded =
          JsonListCodec.encode<_Item>(const <_Item>[], (i) => i.toJson());
      expect(encoded, '[]');

      final r = JsonListCodec.decode<_Item>(encoded, _Item.fromJson);
      expect(r.items, isEmpty);
      expect(r.dropped, 0);
      expect(r.unparsable, isFalse);
    });

    test('COV-05 损坏 JSON ⇒ unparsable，onBadItem 留痕，禁写回', () {
      Object? seen;
      final r = JsonListCodec.decode<_Item>(
        '[{"id":"a","name":"甲"', // 截断的 JSON
        _Item.fromJson,
        onBadItem: (e) => seen = e,
      );

      expect(r.items, isEmpty, reason: '整体不可解析时 items 必然为空');
      expect(r.dropped, 0);
      expect(r.unparsable, isTrue,
          reason: 'unparsable=true 时调用方不得把空表写回存储');
      expect(r.hasLoss, isTrue);
      expect(seen, isA<FormatException>(),
          reason: '损坏 JSON 必须经 onBadItem 留痕，不能静默吞掉');
    });

    test('COV-06 顶层不是数组 ⇒ unparsable，onBadItem 收到 FormatException', () {
      Object? seen;
      final r = JsonListCodec.decode<_Item>(
        '{"id":"a","name":"甲"}',
        _Item.fromJson,
        onBadItem: (e) => seen = e,
      );

      expect(r.items, isEmpty);
      expect(r.dropped, 0);
      expect(r.unparsable, isTrue);
      expect(r.hasLoss, isTrue);
      expect(seen, isA<FormatException>());
      expect((seen as FormatException).message, '顶层不是数组');
    });

    test('COV-07 顶层是字符串同样不是数组 ⇒ unparsable', () {
      final r = JsonListCodec.decode<_Item>('"hello"', _Item.fromJson);

      expect(r.unparsable, isTrue);
      expect(r.items, isEmpty);
      expect(r.hasLoss, isTrue);
    });

    test('COV-08 条目不是对象 ⇒ 只丢该条，好条目保留并计数', () {
      final bad = <Object>[];
      final r = JsonListCodec.decode<_Item>(
        '[1, {"id":"a","name":"甲"}, "oops"]',
        _Item.fromJson,
        onBadItem: bad.add,
      );

      expect(r.items, [_Item('a', '甲')],
          reason: '逐条容错：坏条目跳过，好条目必须保留（旧实现会整表变空）');
      expect(r.dropped, 2);
      expect(r.unparsable, isFalse,
          reason: '逐条失败不是整体不可解析，仍可安全写回');
      expect(r.hasLoss, isTrue);
      expect(bad.length, 2);
      expect(bad.first, isA<FormatException>());
      expect((bad.first as FormatException).message, '条目不是对象');
    });

    test('COV-09 parse 返回 null ⇒ 计 dropped 但不调 onBadItem', () {
      var onBadItemCalls = 0;
      final r = JsonListCodec.decode<_Item>(
        '[{"id":123}, {"id":"a","name":"甲"}]', // 第一条 id 类型不符
        _Item.fromJson,
        onBadItem: (_) => onBadItemCalls++,
      );

      expect(r.items, [_Item('a', '甲')]);
      expect(r.dropped, 1);
      expect(r.unparsable, isFalse);
      expect(r.hasLoss, isTrue);
      expect(onBadItemCalls, 0,
          reason: 'parse 返回 null 是"已知格式不符"，不是异常，不应留痕');
    });

    test('COV-10 parse 抛异常 ⇒ 计 dropped 并经 onBadItem 透传', () {
      Object? seen;
      final r = JsonListCodec.decode<_Item>(
        '[{"id":"boom","name":"x"}, {"id":"a","name":"甲"}]',
        (json) {
          if (json['id'] == 'boom') {
            throw StateError('模拟字段缺失');
          }
          return _Item.fromJson(json);
        },
        onBadItem: (e) => seen = e,
      );

      expect(r.items, [_Item('a', '甲')]);
      expect(r.dropped, 1);
      expect(r.unparsable, isFalse);
      expect(r.hasLoss, isTrue);
      expect(seen, isA<StateError>());
      expect((seen as StateError).message, '模拟字段缺失');
    });

    test('COV-11 多条坏条目累计 dropped（混合三类损坏）', () {
      final r = JsonListCodec.decode<_Item>(
        '[null, {"id":"a","name":"甲"}, 42, {"id":1,"name":"乙"}, {"id":"c","name":"丙"}]',
        _Item.fromJson,
      );

      expect(r.items, [_Item('a', '甲'), _Item('c', '丙')]);
      expect(r.dropped, 3);
      expect(r.unparsable, isFalse);
      expect(r.hasLoss, isTrue, reason: 'dropped>0 时 hasLoss 必须为 true');
    });
  });
}
