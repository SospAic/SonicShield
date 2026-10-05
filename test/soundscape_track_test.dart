import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/services/background_engine.dart';

import 'support/source_text.dart';

/// BUG-059 回归锁：声景轨道**点名了就必须满足，满足不了就跳过 + 留痕**，
/// 绝不拿"库里任意一条"顶上。
///
/// 修之前 `soundscapeAndLog` 的解析链是
/// `assetId → presetCategory → pickAnyAssetPath()`。
/// 而 [SoundscapeTrack] 断言 assetId / presetCategory **必居其一**，
/// 所以第三级**只可能在"点名了却没找到"时触发** —— 真实效果：
/// 用户挑的音源被删了，任务却**静默改播一条完全不相干的声音**，且不报错。
const _src = 'lib/services/background_engine.dart';

void main() {
  test('SCT-01 点名具体音源优先（assetId > presetCategory）', () {
    expect(soundscapeTrackPath(byId: '/a.mp3', byCategory: '/b.mp3'), '/a.mp3');
  });

  test('SCT-02 没点名音源时按分类取', () {
    expect(soundscapeTrackPath(byId: null, byCategory: '/b.mp3'), '/b.mp3');
  });

  test('SCT-03 两个都没解析到 → null（绝不编造一条）', () {
    // 核心：这是 BUG-059 的反例。返回"库里任意一条"会让用户听到
    // 自己**根本没点名**的声音，而且无从发现配置已经坏了。
    expect(soundscapeTrackPath(byId: null, byCategory: null), isNull);
  });

  test('SCT-04 前提锁：SoundscapeTrack 必居其一（第三级只在点名失败时触发）', () {
    // 这条断言是 SCT-03 的**前提**：正因为 assetId/category 必有其一，
    // 第三级兜底才不可能是"用户没点名"的情形 —— 它只会在点名失败时出现。
    // ⚠️ 必须用**非 const** 调用：`const` 构造的 assert 在**编译期**就失败，
    // 写出来会直接编译不过，测不到运行时行为。
    // ignore: prefer_const_constructors —— 故意不用 const，见上方说明
    expect(() => SoundscapeTrack(), throwsA(isA<AssertionError>()));
    // ignore: prefer_const_constructors
    expect(() => SoundscapeTrack(assetId: 'a'), returnsNormally);
    // ignore: prefer_const_constructors
    expect(() => SoundscapeTrack(presetCategory: 'ambient'), returnsNormally);
  });

  test('SCT-05 源码锁：解析链里不得再出现"任意一条"兜底', () {
    final src = File(_src).readAsStringSync();
    // 1) 兜底函数本身必须已经不存在（不是"留着不用"，而是真的删掉）。
    // ⚠️ 只查**声明**，不能查"文件里是否出现过这个名字" ——
    // 文档注释里为了说明历史必然提到它（第一版就在这里自伤了一次）。
    expect(src.contains('Future<String?> pickAnyAssetPath('), isFalse,
        reason: '`pickAnyAssetPath` 的**声明**必须已删除 —— 留着不用等于埋雷，'
            '下一个人看到会以为声景还在用它兜底');

    // 2) `soundscapeTrackPath` 的签名里不得出现第三级入参。
    const marker = 'String? soundscapeTrackPath({';
    final i = src.indexOf(marker);
    expect(i >= 0, isTrue, reason: '找不到 soundscapeTrackPath');
    // 从 `({` **之后**开始取，否则函数名本身也会被当成入参抓进来。
    final sig = src.substring(i + marker.length, src.indexOf('}) =>', i));
    // ⚠️ 不能只查"参数名里含 any" —— 换个名字（fallback / fallbackPath）就绕过了。
    // 要断言**入参集合恰好是 {byId, byCategory}**：多一个就是重新引入兜底通道。
    // ⚠️ `?` 必须转义：不转义的话 `String?` 里的 `?` 是**正则量词**
    // （"前一个字符可有可无"），会匹配成 `Strin`，永远抓不到参数 → **恒红**。
    final params = RegExp(r'String\?\s+(\w+)')
        .allMatches(sig)
        .map((m) => m.group(1)!)
        .toSet();
    expect(params.isNotEmpty, isTrue, reason: '没解析出任何入参 —— 正则失效了（恒红的锁比没锁更坏）');
    expect(params, {'byId', 'byCategory'},
        reason: '`soundscapeTrackPath` 的入参必须**恰好**是 byId / byCategory —— '
            '多一个（哪怕叫别的名字）就是重新开了兜底通道。'
            '实际入参: $params');

    // 3) 声景执行必须调用这个纯函数（不能有人绕过它直接 `??=`）。
    // 花括号配对取方法体：不再写死 `indexOf('\n  }', j)`（A12）。
    // ⚠️ P1-07 后 `soundscapeAndLog` 改为返回 `ExecutionOutcome`（把真实成败
    // 带出给 occurrence/ack），锚点随之更新 —— 判据本身不变。
    final body = methodBody(
        stripComments(src), 'Future<ExecutionOutcome> soundscapeAndLog(');
    expect(body.contains('soundscapeTrackPath('), isTrue,
        reason: '`soundscapeAndLog` 必须经 `soundscapeTrackPath` 解析轨道');
    expect(body.contains('??='), isFalse,
        reason: '`soundscapeAndLog` 里不得再出现 `??=` 兜底');
    expect(body.contains('pickAnyAssetPath'), isFalse,
        reason: '`soundscapeAndLog` 不得再调用"任意一条"兜底');
  });
}
