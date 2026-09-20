import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';

/// 声音守卫 DSP（rmsDbfs）纯函数测试：无平台依赖。
void main() {
  Uint8List pcm16(List<int> samples) {
    final b = BytesBuilder();
    final bd = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      bd.setInt16(i * 2, samples[i], Endian.little);
    }
    b.add(bd.buffer.asUint8List());
    return b.toBytes();
  }

  test('满量程方波 ≈ 0 dBFS', () {
    final full = pcm16(List.generate(1600, (_) => 32767));
    final db = SoundGuardService.rmsDbfs(full);
    expect(db, greaterThan(-1));
    expect(db, lessThanOrEqualTo(0));
  });

  test('全零 = 数字静音（-120 下限）', () {
    final silence = pcm16(List.filled(1600, 0));
    expect(SoundGuardService.rmsDbfs(silence), -120);
  });

  test('半幅正弦 ≈ -9 dBFS 量级（0.5 峰值 → RMS≈0.35 → -9dB）', () {
    final sine = pcm16(List.generate(
        1600, (i) => (16383 * sin(2 * pi * i / 1600 * 4)).round()));
    final db = SoundGuardService.rmsDbfs(sine);
    expect(db, inInclusiveRange(-14, -6), reason: '实测 $db dBFS');
  });

  test('空/短 buffer 安全不抛', () {
    expect(SoundGuardService.rmsDbfs(Uint8List(0)), -120);
    expect(SoundGuardService.rmsDbfs(Uint8List.fromList([1])), -120);
  });

  test('能量越高 dBFS 越大（单调性）', () {
    final loud = SoundGuardService.rmsDbfs(
        pcm16(List.generate(1600, (i) => (i % 2 == 0) ? 20000 : -20000)));
    final quiet = SoundGuardService.rmsDbfs(
        pcm16(List.generate(1600, (i) => (i % 2 == 0) ? 5000 : -5000)));
    expect(loud, greaterThan(quiet));
  });
}
