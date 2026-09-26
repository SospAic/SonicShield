import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/remote_playback.dart';

import 'support/source_text.dart';

/// 假音源库：记录**每一次**解析调用，从而能断言"查了什么"，
/// 也能断言**没查什么** —— 后者才是 BUG-048 的关键
/// （点名未命中时**不得**回落到"任意一条"）。
class _Lib {
  _Lib({this.byId = const {}, this.byTag = const {}, this.anyPath});

  final Map<String, String> byId;
  final Map<String, String> byTag;
  final String? anyPath;

  final idQueries = <String>[];
  final tagQueries = <String>[];
  var anyQueries = 0;

  final played = <({String path, double volume, int durationMs, bool loop})>[];

  Future<String?> resolveId(String id) async {
    idQueries.add(id);
    return byId[id];
  }

  Future<String?> resolveTag(String tag) async {
    tagQueries.add(tag);
    return byTag[tag];
  }

  Future<String?> resolveAny() async {
    anyQueries++;
    return anyPath;
  }

  Future<bool> play(String path, double volume, int durationMs,
      {bool loop = false}) async {
    played
        .add((path: path, volume: volume, durationMs: durationMs, loop: loop));
    return true;
  }
}


void main() {
  group('PlaybackSelector 解析', () {
    test('空串 / 非字符串一律视为未点名（不产生"点名了空 ID"的必败请求）', () {
      final s = PlaybackSelector.of({
        'assetId': '',
        'preset': '   ',
        'category': 42,
      });
      expect(s.assetId, isNull);
      expect(s.preset, isNull);
      expect(s.category, isNull);
      expect(s.named, isNull, reason: '三者都无效 = 没点名');
    });

    test('优先级：assetId > preset > category', () {
      final all = PlaybackSelector.of(
          {'assetId': 'a-1', 'preset': 'p-1', 'category': 'c-1'}).named;
      expect(all!.kind, PlaybackTargetKind.asset);
      expect(all.value, 'a-1');

      final noId =
          PlaybackSelector.of({'preset': 'p-1', 'category': 'c-1'}).named;
      expect(noId!.kind, PlaybackTargetKind.tag);
      expect(noId.value, 'p-1', reason: 'preset 是协议字段名，优先于 v1 的 category');

      final onlyCat = PlaybackSelector.of({'category': 'c-1'}).named;
      expect(onlyCat!.value, 'c-1');
    });

    test('trim 掉首尾空白（避免把 " a-1 " 当成另一个不存在的 ID）', () {
      expect(PlaybackSelector.of({'assetId': '  a-1 '}).assetId, 'a-1');
    });
  });

  group('resolvePlayback 契约（BUG-048）', () {
    test('点名 assetId 且命中 → 播那一条，且不查 tag/any', () async {
      final lib = _Lib(
          byId: {'a-7': '/x/a7.wav'},
          byTag: {'nature': '/x/nature.wav'},
          anyPath: '/x/newest.wav');

      final r = await resolvePlayback(
        const PlaybackSelector(assetId: 'a-7'),
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
      );

      expect(r.path, '/x/a7.wav');
      expect(r.kind, PlaybackTargetKind.asset);
      expect(r.reason, contains('a-7'));
      expect(lib.idQueries, ['a-7']);
      expect(lib.tagQueries, isEmpty);
      expect(lib.anyQueries, 0, reason: '点名命中就不该再走兜底查询');
    });

    test('点名 assetId 未命中 → 失败，且**绝不**回落到任意一条（核心锁）', () async {
      final lib = _Lib(anyPath: '/x/newest.wav');

      final r = await resolvePlayback(
        const PlaybackSelector(assetId: 'missing'),
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
      );

      expect(r.path, isNull, reason: '点名了却找不到必须失败，不能换成别的音源');
      expect(r.found, isFalse);
      expect(r.reason, contains('无此音源'));
      expect(r.reason, contains('missing'));
      expect(lib.anyQueries, 0,
          reason: 'BUG-048 的实质：此前这里会静默播 /x/newest.wav 并回 ok=true');
    });

    test('点名分类未命中 → 失败，且**绝不**回落到任意一条', () async {
      final lib = _Lib(anyPath: '/x/newest.wav');

      final r = await resolvePlayback(
        const PlaybackSelector(category: 'alarms'),
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
      );

      expect(r.path, isNull);
      expect(r.reason, contains('分类无音源'));
      expect(lib.tagQueries, ['alarms']);
      expect(lib.anyQueries, 0, reason: '点"闹钟"没音源时不能响起"敲击声"');
    });

    test('点名 preset 走 tag 查询（协议字段名与 v1 category 同义）', () async {
      final lib = _Lib(byTag: {'nature': '/x/nature.wav'});

      final r = await resolvePlayback(
        const PlaybackSelector(preset: 'nature'),
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
      );

      expect(r.path, '/x/nature.wav');
      expect(r.kind, PlaybackTargetKind.tag);
      expect(lib.tagQueries, ['nature']);
    });

    test('完全未点名 → 才允许任意一条兜底（v1 兼容）', () async {
      final lib = _Lib(anyPath: '/x/newest.wav');

      final r = await resolvePlayback(
        const PlaybackSelector(),
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
      );

      expect(r.path, '/x/newest.wav');
      expect(r.kind, PlaybackTargetKind.any);
      expect(lib.anyQueries, 1);
    });

    test('未点名且库为空 → 失败并说明原因', () async {
      final lib = _Lib();

      final r = await resolvePlayback(
        const PlaybackSelector(),
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
      );

      expect(r.path, isNull);
      expect(r.reason, '音源库为空');
    });
  });

  group('performRemotePlay 执行（端点侧决策链）', () {
    test('assetId 命中 → 播放器收到该路径，音量/时长/循环原样传递', () async {
      final lib = _Lib(byId: {'a-7': '/x/a7.wav'}, anyPath: '/x/newest.wav');

      final r = await performRemotePlay(
        {'assetId': 'a-7', 'volume': 0.35, 'durationSec': 7, 'loop': true},
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
        play: lib.play,
      );

      expect(lib.played.single.path, '/x/a7.wav');
      expect(lib.played.single.volume, closeTo(0.35, 1e-9));
      expect(lib.played.single.durationMs, 7000);
      expect(lib.played.single.loop, isTrue);
      expect(r.ok, isTrue);
      expect(r.durationMs, 7000);
    });

    test('assetId 未命中 → **一次都不播放**，ok=false 且回执原因可读', () async {
      final lib = _Lib(anyPath: '/x/newest.wav');

      final r = await performRemotePlay(
        {'assetId': 'missing'},
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
        play: lib.play,
      );

      expect(lib.played, isEmpty, reason: '解析失败时绝不能调用播放器 —— 这正是 BUG-048 的旧行为');
      expect(r.ok, isFalse);
      expect(r.reason, contains('无此音源'));
    });

    test('端点未装配播放能力 → 报失败而非静默成功', () async {
      final lib = _Lib(byId: {'a-7': '/x/a7.wav'});

      final r = await performRemotePlay(
        {'assetId': 'a-7'},
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
        play: null,
      );

      expect(r.ok, isFalse);
      expect(r.reason, '端点未装配播放能力');
    });

    test('播放器自身失败 → ok=false，但解析依据仍如实保留', () async {
      final lib = _Lib(byId: {'a-7': '/x/a7.wav'});

      final r = await performRemotePlay(
        {'assetId': 'a-7'},
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
        play: (p, v, d, {loop = false}) async => false,
      );

      expect(r.ok, isFalse);
      expect(r.reason, contains('a-7'));
    });

    test('默认音量 0.9 / 时长 5s（与改造前一致，不悄悄改默认值）', () async {
      final lib = _Lib(anyPath: '/x/newest.wav');

      final r = await performRemotePlay(
        const {},
        byId: lib.resolveId,
        byTag: lib.resolveTag,
        any: lib.resolveAny,
        play: lib.play,
      );

      expect(lib.played.single.volume, closeTo(0.9, 1e-9));
      expect(lib.played.single.durationMs, 5000);
      expect(lib.played.single.loop, isFalse);
      expect(r.ok, isTrue);
    });
  });

  // ---------------- 端点接线锁（源码契约） ----------------
  //
  // 为什么这里要读源码：`_playRemote` 依赖**私有** `_db` 与 MQTT 连接，
  // 宿主机无法实例化它；而"决策函数是否被正确接线"恰恰是 BUG-048 的回归面 ——
  // 只测 [resolvePlayback] 无法发现"`_playRemote` 又改回只读 `category`"
  // 这类**两端各自都对、链路却是断的**缺陷（本项目反复踩过的坑）。
  // 因此退一步锁**接线本身**：方法体里必须出现新调用，且不得再出现旧写法。
  group('端点接线锁（源码契约）', () {
    final src = File('lib/remote/endpoint_service.dart').readAsStringSync();

    test('_playRemote 走 performRemotePlay 并注入 byId/byTag/any/play', () {
      final body = methodBody(src, 'Future<void> _playRemote(');

      expect(body, contains('performRemotePlay('));
      expect(body, contains('byId: _assetPathById'),
          reason: 'assetId 必须按 ID 精确解析');
      expect(body, contains('byTag:'), reason: 'preset/category 走标签解析');
      expect(body, contains('any: _anyAssetPath'), reason: '仅未点名时才兜底');
      expect(body, contains('play: playHandler'));
    });

    test('_playRemote 不得再出现 BUG-048 的旧写法', () {
      final body = methodBody(src, 'Future<void> _playRemote(');

      expect(body, isNot(contains("payload['category']")),
          reason: '旧写法：只读 category → assetId/preset 被静默忽略');
      expect(body, isNot(contains('??= await _anyAssetPath()')),
          reason: '旧写法：解析失败静默回落到"库里最新一条"');
    });

    test('_assetPathById 按主键精确查询（不是模糊匹配）', () {
      final body = methodBody(src, 'Future<String?> _assetPathById(');

      expect(body, contains('audio_assets'));
      expect(body, contains("where: 'id = ?'"));
      expect(body, isNot(contains('LIKE')), reason: '按 ID 取音源不能是模糊匹配');
    });
  });
}
