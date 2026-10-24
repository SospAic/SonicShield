import 'dart:convert';

/// 逐条容错的 JSON 列表解码结果（DAT-09）。
class JsonListDecode<T> {
  const JsonListDecode({
    required this.items,
    required this.dropped,
    required this.unparsable,
  });

  /// 成功解析的条目（**保持原顺序**）。
  final List<T> items;

  /// 逐条解析失败、被跳过的条数（>0 时调用方应留痕/提示）。
  final int dropped;

  /// 整体不可解析（不是合法 JSON、或顶层不是数组）。
  ///
  /// ⚠️ 为 true 时 [items] 必然为空，但**绝不能**把空表写回存储：
  /// 那会把"一次坏读"固化成"永久丢失"（见 [JsonListCodec] 的说明）。
  final bool unparsable;

  /// 是否有任何数据被丢弃（逐条或整体）。
  bool get hasLoss => dropped > 0 || unparsable;
}

/// prefs 里"JSON 列表"的容错编解码（DAT-09）。
///
/// ## 为什么需要它
/// `RemoteStore` 的配对表 / 撤销名单 / 待发命令队列 / 已存脚本都是
/// "一个 prefs 键存一个 JSON 数组"。旧实现是
/// `(jsonDecode(raw) as List).map(X.fromJson).toList()` 外面套一个
/// `catch { return []; }` —— 容错粒度选在**整个集合**：**任意一条**记录缺字段
/// （`PairedEndpoint.fromJson` 对 `deviceId`/`secret` 做裸 `as String`）
/// 就让整表变成空列表。
///
/// 后果不止"显示为空"：下一次 `addPaired`/`touchPaired`/`renamePaired`
/// 会用这个空列表 + 新条目**整体重写** prefs ⇒ 其余配对关系（授权）
/// **永久丢失**；撤销名单变空 ⇒ 被撤销的设备重新获得配对资格（安全方向错误）；
/// outbox 变空 ⇒ 待发命令静默消失。
///
/// ## 正确口径（与 R90-09 在 DB 侧学到的教训一致）
/// - **逐条** try/catch：坏的跳过并计数（[JsonListDecode.dropped]），好的照常返回；
/// - 只有**整体**无法解析时才回落空表，并置 [JsonListDecode.unparsable]；
/// - 无论哪种丢失，调用方都应**先留痕**再决定是否写回 —— 尤其是
///   `unparsable` 时**不得**把空表持久化（那等于把一次坏读变成永久丢数据）。
///
/// ## 接法（供 `lib/remote/remote_store.dart` 等调用方）
/// ```dart
/// final r = JsonListCodec.decode<PairedEndpoint>(
///   prefs.getString(_kPaired), PairedEndpoint.fromJson,
///   onBadItem: (e) => log('配对表有坏条目：$e'),
/// );
/// // r.unparsable ⇒ 只读空表，禁止写回；r.dropped>0 ⇒ 写回时保留好条目。
/// ```
class JsonListCodec {
  const JsonListCodec._();

  /// 容错解码：[parse] 返回 null 或抛异常都只丢**这一条**。
  static JsonListDecode<T> decode<T>(
    String? raw,
    T? Function(Map<String, dynamic> json) parse, {
    void Function(Object error)? onBadItem,
  }) {
    final empty = JsonListDecode<T>(
      items: const [],
      dropped: 0,
      unparsable: false,
    );
    if (raw == null || raw.trim().isEmpty) return empty;

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object catch (e) {
      onBadItem?.call(e);
      return JsonListDecode<T>(items: const [], dropped: 0, unparsable: true);
    }
    if (decoded is! List) {
      onBadItem?.call(FormatException('顶层不是数组', raw));
      return JsonListDecode<T>(items: const [], dropped: 0, unparsable: true);
    }

    final out = <T>[];
    var dropped = 0;
    for (final e in decoded) {
      if (e is! Map<String, dynamic>) {
        dropped++;
        onBadItem?.call(FormatException('条目不是对象', e));
        continue;
      }
      try {
        final v = parse(e);
        if (v == null) {
          dropped++;
          continue;
        }
        out.add(v);
      } on Object catch (err) {
        dropped++;
        onBadItem?.call(err);
      }
    }
    return JsonListDecode<T>(
      items: out,
      dropped: dropped,
      unparsable: false,
    );
  }

  /// 编码为 prefs 字符串（对称入口，避免调用方各自 `jsonEncode`）。
  static String encode<T>(
    Iterable<T> items,
    Map<String, dynamic> Function(T item) toJson,
  ) =>
      jsonEncode([for (final i in items) toJson(i)]);
}
