import 'dart:async';

/// 远程播放（`sound.play`）的**选择器解析与执行**（BUG-048）。
///
/// ## 缺陷
///
/// 协议把 `sound.play` 的 payload 声明为
/// `{preset|assetId|category, volume, durationSec, loop}`（见 `RcCmd.soundPlay`），
/// 但端点侧此前**只读 `category`**：
///
/// ```dart
/// final category = msg.payload['category'] as String?;   // assetId / preset 被丢弃
/// var path = await _resolvePreset(category);
/// path ??= await _anyAssetPath();                        // 解析不到 → 库里最新一条
/// ```
///
/// 两个后果，都是**用户可见的静默错误**：
///
/// 1. 控制器点名播放 `assetId=A`，端点播的是**另一段声音**，而回执仍为 `ok=true`
///    —— 使用者看到"成功"、听到的不是自己要的，且没有任何地方提示发生了替换。
/// 2. 点名的分类没有匹配音源时，同样静默换成任意一条 ——
///    点"闹钟"却响起敲击声。
///
/// 这与 BUG-041（`unknown` 被当成 `false`）是同一类缺陷：
/// **无法满足请求时，必须让失败可见，而不是悄悄换一个能满足的结果。**
///
/// ## 契约
///
/// - **点名了就必须播那一条**：`assetId` / `preset` / `category` 任一非空时
///   只按它解析；解析不到返回"没找到"，**绝不回落到任意一条**。
/// - **没点名才允许兜底**：payload 完全不带选择器时取任意一条
///   （v1 兼容用法；`tool/rc_e2e_controller.dart` 的 RC-09 即此形态）。
///
/// 本文件刻意**不依赖数据库与平台通道**：解析器由调用方注入，
/// 因此"点名被静默替换"这一缺陷可在宿主机上完整复现并锁定。
/// （同类做法：`ConditionEnv` / `AssetLibraryImporter`。）

/// 点名的对象种类。
enum PlaybackTargetKind {
  /// 具体音源（`assetId`）——唯一确定一条。
  asset,

  /// 分类标签（`preset` / `category`）——在该分类内随机取一条。
  tag,

  /// 未点名，任意一条。
  any,
}

/// `sound.play` 的音源选择器。
class PlaybackSelector {
  const PlaybackSelector({this.assetId, this.preset, this.category});

  /// 精确音源 ID（最精确的选择方式）。
  final String? assetId;

  /// 预置分类（协议字段名）。
  final String? preset;

  /// 分类（v1 旧字段名，与 [preset] 同义）。
  final String? category;

  /// 从 `sound.play` payload 解析。
  ///
  /// 空串与非字符串一律视为**未点名**：`{'assetId': ''}` 与 `{}` 等价，
  /// 否则会把"没给选择器"误判成"点名了一个空 ID"而必然失败。
  factory PlaybackSelector.of(Map<String, dynamic> payload) => PlaybackSelector(
        assetId: _nonEmpty(payload['assetId']),
        preset: _nonEmpty(payload['preset']),
        category: _nonEmpty(payload['category']),
      );

  static String? _nonEmpty(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// 点名依据；未点名时为 null。优先级 `assetId` > `preset` > `category`。
  ///
  /// 三者同传时以 `assetId` 为准：它唯一确定一条音源，
  /// 而 `preset` / `category` 只是"在该分类内随机取一条"。
  PlaybackTarget? get named {
    final id = assetId;
    if (id != null) return PlaybackTarget(PlaybackTargetKind.asset, id);
    final tag = preset ?? category;
    if (tag != null) return PlaybackTarget(PlaybackTargetKind.tag, tag);
    return null;
  }
}

/// 点名的对象。
class PlaybackTarget {
  const PlaybackTarget(this.kind, this.value);

  final PlaybackTargetKind kind;
  final String value;
}

/// 解析结果。[path] 为 null 表示**没找到**，调用方必须据此失败。
class PlaybackResolution {
  const PlaybackResolution({
    required this.path,
    required this.kind,
    required this.reason,
  });

  final String? path;
  final PlaybackTargetKind kind;

  /// 人类可读依据，写进端点审计日志（"播了哪一条、凭什么"）。
  final String reason;

  bool get found => path != null;
}

/// 解析 `sound.play` 请求 → 本地音源路径。
///
/// [byId] / [byTag] / [any] 由调用方注入（生产走 DB，测试走内存）。
Future<PlaybackResolution> resolvePlayback(
  PlaybackSelector selector, {
  required Future<String?> Function(String assetId) byId,
  required Future<String?> Function(String tag) byTag,
  required Future<String?> Function() any,
}) async {
  final named = selector.named;
  if (named == null) {
    final path = await any();
    return PlaybackResolution(
      path: path,
      kind: PlaybackTargetKind.any,
      reason: path == null ? '音源库为空' : '任意音源',
    );
  }
  if (named.kind == PlaybackTargetKind.asset) {
    final path = await byId(named.value);
    return PlaybackResolution(
      path: path,
      kind: PlaybackTargetKind.asset,
      reason: path == null ? '无此音源：${named.value}' : '音源 ${named.value}',
    );
  }
  final path = await byTag(named.value);
  return PlaybackResolution(
    path: path,
    kind: PlaybackTargetKind.tag,
    reason: path == null ? '分类无音源：${named.value}' : '分类 ${named.value}',
  );
}

/// 一次远程播放的完整结果（审计与回执都用它）。
class RemotePlayOutcome {
  const RemotePlayOutcome({
    required this.ok,
    required this.reason,
    required this.volume,
    required this.durationMs,
    this.path,
  });

  /// 是否**真的播放成功**（解析到音源且播放器返回成功）。
  final bool ok;

  /// 人类可读依据（含失败原因）。
  final String reason;

  final String? path;
  final double volume;
  final int durationMs;
}

/// 执行一次远程播放请求：解析 → 播放 → 汇总结果。
///
/// 端点侧 `_playRemote` 只剩「取 payload → 调本函数 → 写审计 / 回执」，
/// 于是整条决策链在宿主机上可断言（含"点名解析不到时**不得调用播放器**"）。
///
/// [play] 为 null 表示端点未注入播放能力（如后台未装配）：此时不播放，
/// 结果按失败处理 —— 静默成功会让控制端以为"已经响了"。
Future<RemotePlayOutcome> performRemotePlay(
  Map<String, dynamic> payload, {
  required Future<String?> Function(String assetId) byId,
  required Future<String?> Function(String tag) byTag,
  required Future<String?> Function() any,
  Future<bool> Function(String path, double volume, int durationMs,
          {bool loop})?
      play,
}) async {
  final volume =
      ((payload['volume'] as num?)?.toDouble() ?? 0.9).clamp(0.0, 1.0).toDouble();
  final durationSec = (payload['durationSec'] as num?)?.toInt() ?? 5;
  final loop = payload['loop'] as bool? ?? false;

  final r = await resolvePlayback(
    PlaybackSelector.of(payload),
    byId: byId,
    byTag: byTag,
    any: any,
  );

  var ok = false;
  var reason = r.reason;
  if (r.path == null) {
    // 保留解析原因（"无此音源：X" / "音源库为空"）—— 这就是回执要说的失败理由。
  } else if (play == null) {
    // 解析成功但没有播放能力：必须报失败，否则控制端以为"已经响了"。
    reason = '端点未装配播放能力';
  } else {
    ok = await play(r.path!, volume, durationSec * 1000, loop: loop);
  }

  return RemotePlayOutcome(
    ok: ok,
    reason: reason,
    volume: volume,
    durationMs: durationSec * 1000,
    path: r.path,
  );
}
