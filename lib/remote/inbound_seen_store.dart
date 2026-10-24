import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

/// 入站去重表的**落盘版本**（R94 / REM-15）。
///
/// ## 为什么内存表不够
///
/// `RcEndpointService._seen` 原本是纯内存 `Map`。攻击者抓到一条密文后，
/// 只需等目标进程被杀/重启，再在原始 `ts` 的 ±90s 窗口内重放 ——
/// 时间窗通过、去重表为空 ⇒ **同一条命令执行两次**。而 `sound.play` /
/// `vibrate.start` / `script.run` / `call.invite` 全都不是幂等的。
///
/// ## 设计
///
/// - 真源仍是 [InboundSeenTable]（查重 + 预占 + 窗口裁剪在**同一个同步段**内，
///   单 isolate 原子，与 `RcCodec.reserveInboundId` 同语义）；
/// - 本类只负责"启动载入 / 变更后节流落盘"；
/// - 窗口 10 分钟（远大于 ±90s 时间窗）：只要进程重启发生在窗口内，
///   重放一律被挡。
///
/// ## 为什么节流而不是每条都写
///
/// 流式对讲 2 条/秒、心跳与回执叠加时写入会变成高频磁盘 I/O（SharedPreferences
/// 每次 `setString` 都要序列化整张表）。节流到 [minFlushIntervalMs] 一次，
/// 最坏情况丢失最近 5 秒的去重记录 —— 而重放窗口是 90 秒，
/// 攻击者无法靠"掐准进程被杀前 5 秒"来稳定命中（且窗口内还有 ts 校验）。
class InboundSeenStore {
  InboundSeenStore(this._prefs, {this.windowMs = 10 * 60 * 1000})
      : _table = InboundSeenTable(windowMs: windowMs);

  /// 存储键。与 `rc_peer_keys` 同级别（应用私有目录）。
  static const storageKey = 'rc_seen_ids';

  /// 两次落盘之间的最小间隔。
  static const minFlushIntervalMs = 5000;

  final SharedPreferences _prefs;

  /// 去重窗口（毫秒）。
  final int windowMs;

  final InboundSeenTable _table;

  bool _dirty = false;
  int _lastFlushMs = 0;

  /// 当前表大小（诊断/测试用）。
  int get length => _table.length;

  /// 某 id 是否已在表内。
  bool contains(String id) => _table.contains(id);

  /// 可落盘快照（测试用）。
  Map<String, int> snapshot() => _table.snapshot();

  /// 启动时从存储恢复；顺带裁掉已出窗的条目。
  ///
  /// 存储被写坏 / 格式不符 ⇒ 按空表处理（**不**放行也不崩）：宁可漏挡一次
  /// 重放，也不能让"去重表损坏"变成"远程模块启动失败"。
  void load({int? nowMs}) {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final data = <String, int>{};
      decoded.forEach((k, v) {
        if (k is String && k.isNotEmpty && v is num) data[k] = v.toInt();
      });
      _table.restore(data, nowMs: nowMs);
    } on Object {
      // 坏值：保持空表。
    }
  }

  /// 首次见到返回 true（已预占）；重复返回 false（**不得执行副作用**）。
  bool reserve(String id, int nowMs) {
    final first = _table.reserve(id, nowMs);
    if (first) _dirty = true;
    return first;
  }

  /// 变更后按节流落盘（调用方 `unawaited` 即可）。
  Future<void> flushIfDue(int nowMs) async {
    if (!_dirty) return;
    if (_lastFlushMs != 0 && nowMs - _lastFlushMs < minFlushIntervalMs) return;
    await flush(nowMs: nowMs);
  }

  /// 立即落盘（服务停止 / 测试用）。
  Future<void> flush({int? nowMs}) async {
    if (!_dirty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // 落盘前先裁一次：否则长时间运行后表会膨胀到几千条。
    _table.restore(_table.snapshot(), nowMs: now);
    await _prefs.setString(storageKey, jsonEncode(_table.snapshot()));
    _dirty = false;
    _lastFlushMs = now;
  }
}
