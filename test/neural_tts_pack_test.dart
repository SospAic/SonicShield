import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/services/neural_tts.dart';

/// 神经 TTS 引擎（`lib/services/neural_tts.dart`）的**可测面锁**。
///
/// ## 为什么这个文件此前是 1.4% 覆盖
///
/// `NeuralTtsEngine` 的三条主链路（`getApplicationSupportDirectory` /
/// `rootBundle.load` / `sherpa.OfflineTts` 原生构造）都强依赖平台侧，单元测试
/// 环境里全部走不通，于是历史上只被「资产打包锁」从**源码文本**角度检查过，
/// 真正的代码行几乎零覆盖（70 行里只命中 1 行）。
///
/// 但其中有两块是**纯逻辑**，完全可测：
///
/// 1. [encodeWav] —— Float32 PCM → 16-bit WAV 的字节拼装，纯 `ByteData` 运算；
/// 2. 各入口的**早返回 / 失败兜底** —— `speak('')`、`ensureLoaded()` 抛错、
///    `dispose()` 空指针幂等，这些正是「永不崩溃契约」的落点。
///
/// ## 永不崩溃契约（本文件守护的性质）
///
/// 模型缺失 / 拷贝失败 / 合成抛错 / 播放异常 —— 任何一步都只让 `speak` 返回
/// `false`，绝不向上抛。若哪天有人把 `on Object { return false; }` 改成 `rethrow`，
/// 这些用例会立刻变红。
void main() {
  // NTT-09/10 需要 `TestDefaultBinaryMessengerBinding`（mock 方法通道），
  // 普通 `test()` 不会自动初始化绑定，必须显式来一次。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NTT · encodeWav 字节布局', () {
    test('NTT-01 WAV 头 44 字节：RIFF/WAVE/fmt /data 四段魔数与长度字段', () {
      final samples = Float32List.fromList(<double>[0.0, 0.5, -0.5]);
      final bytes = encodeWav(samples, 16000);
      final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

      // 总长 = 44 字节头 + 每样本 2 字节
      expect(bytes.length, 44 + samples.length * 2);

      expect(bd.getUint32(0, Endian.little), 0x52494646); // 'RIFF'
      expect(bd.getUint32(8, Endian.little), 0x57415645); // 'WAVE'
      expect(bd.getUint32(12, Endian.little), 0x666d7420); // 'fmt '
      expect(bd.getUint32(36, Endian.little), 0x64617461); // 'data'

      // RIFF chunk size = 36 + 数据长度；data chunk size = 数据长度
      expect(bd.getUint32(4, Endian.little), 36 + samples.length * 2);
      expect(bd.getUint32(40, Endian.little), samples.length * 2);

      // fmt chunk：16 字节 / PCM=1 / 单声道=1 / 16bit / blockAlign=2
      expect(bd.getUint32(16, Endian.little), 16);
      expect(bd.getUint16(20, Endian.little), 1);
      expect(bd.getUint16(22, Endian.little), 1);
      expect(bd.getUint16(32, Endian.little), 2);
      expect(bd.getUint16(34, Endian.little), 16);

      // 采样率与字节率（byteRate = sampleRate × 2）
      expect(bd.getUint32(24, Endian.little), 16000);
      expect(bd.getUint32(28, Endian.little), 16000 * 2);
    });

    test('NTT-02 PCM 量化：clamp 到 [-1,1] 后 ×32767 再四舍五入', () {
      final samples = Float32List.fromList(<double>[
        0.0, // 0
        0.5, // 16383.5 → 16384（Dart round 为 half-away-from-zero）
        -0.5, // -16383.5 → -16384
        1.0, // 32767
        -1.0, // -32767
        2.0, // 超上界 → clamp 到 1.0 → 32767
        -2.0, // 超下界 → clamp 到 -1.0 → -32767
      ]);
      final bytes = encodeWav(samples, 16000);
      final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

      const expected = <int>[0, 16384, -16384, 32767, -32767, 32767, -32767];
      for (var i = 0; i < expected.length; i++) {
        expect(
          bd.getInt16(44 + i * 2, Endian.little),
          expected[i],
          reason: '第 $i 个样本（输入 ${samples[i]}）',
        );
      }
    });

    test('NTT-03 空样本：只有 44 字节头，两个长度字段均为 0', () {
      final bytes = encodeWav(Float32List(0), 22050);
      final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

      expect(bytes.length, 44);
      expect(bd.getUint32(4, Endian.little), 36); // 36 + 0
      expect(bd.getUint32(40, Endian.little), 0);
      expect(bd.getUint32(24, Endian.little), 22050);
    });

    test('NTT-04 采样率逐值写进头（8k / 44.1k / 48k）', () {
      for (final rate in <int>[8000, 44100, 48000]) {
        final bytes = encodeWav(Float32List(0), rate);
        final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
        expect(bd.getUint32(24, Endian.little), rate, reason: 'sampleRate=$rate');
        expect(
          bd.getUint32(28, Endian.little),
          rate * 2,
          reason: 'byteRate=$rate×2',
        );
      }
    });
  });

  group('NTT · 引擎构造与永不崩溃契约', () {
    test('NTT-05 默认模型目录与资产前缀', () {
      final engine = NeuralTtsEngine();
      expect(engine.modelDir, 'vits-piper-zh_CN-xiao_ya-medium');
      expect(engine.assetPrefix, 'assets/tts');
      engine.dispose();
    });

    test('NTT-06 未加载时 ready=false，dispose 幂等不崩', () {
      final engine = NeuralTtsEngine();
      expect(engine.ready, isFalse);

      // 连续 dispose 两次：`_tts?.free()` 对 null 不执行，且不得抛。
      engine.dispose();
      engine.dispose();
      expect(engine.ready, isFalse);
    });

    test('NTT-07 speak 对空/纯空白文本直接返回 false（不触达引擎）', () async {
      final engine = NeuralTtsEngine();
      expect(await engine.speak('', 1.0), isFalse);
      expect(await engine.speak('   ', 1.0), isFalse);
      expect(await engine.speak('\n\t ', 1.0), isFalse);
      engine.dispose();
    });

    test('NTT-08 ensureLoaded 在平台侧不可用时不抛，返回 false 并短路', () async {
      // 测试环境没有 path_provider 实现 ⇒ getApplicationSupportDirectory() 抛
      // MissingPluginException ⇒ 必须被 catch 成 false（永不崩溃契约）。
      final engine = NeuralTtsEngine();
      expect(await engine.ensureLoaded(), isFalse);
      expect(engine.ready, isFalse);

      // 第二次调用命中 `_failed` 短路分支，仍然只是 false。
      expect(await engine.ensureLoaded(), isFalse);

      // 引擎已标记失败 ⇒ speak 也应静默失败而不是抛。
      expect(await engine.speak('测试', 0.8), isFalse);
      engine.dispose();
    });
  });

  group('NTT · ensureLoaded 前置链路（mock path_provider 通道）', () {
    /// 把 `getApplicationSupportDirectory()` 指到 [dir]。
    ///
    /// path_provider 2.x 的默认实现走 `plugins.flutter.io/path_provider`
    /// 方法通道；测试环境里没有平台侧实现，所以这里用
    /// `setMockMethodCallHandler` 顶掉，并在 tearDown 里**务必置空**——
    /// 否则 NTT-08 那种「依赖通道缺失」的用例会被污染。
    void mockSupportDir(Directory dir) {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => dir.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    test('NTT-09 模型目录已存在 ⇒ 跳过拷贝，走到 sherpa 配置组装后安全失败', () async {
      final tmp = await Directory.systemTemp.createTemp('ntt_case09');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } on Object {
          // 清理失败不影响断言
        }
      });

      // 自定义 modelDir/assetPrefix，同时验证构造参数真的被拼进路径
      final engine = NeuralTtsEngine(
        modelDir: 'probe-model',
        assetPrefix: 'custom/assets',
      );

      // 预建目标目录 ⇒ `dest.exists()` 为 true ⇒ 不进入 rootBundle 拷贝分支
      final dest = Directory(
        '${tmp.path}${Platform.pathSeparator}sonic_shield_tts'
        '${Platform.pathSeparator}probe-model',
      );
      await dest.create(recursive: true);
      expect(dest.existsSync(), isTrue);

      mockSupportDir(tmp);

      // 走到 `sherpa.OfflineTts(cfg)`：测试环境原生库不可用 ⇒ 抛异常 ⇒
      // 被 `on Object` 兜住返回 false（永不崩溃契约，探针已验证不会崩进程）。
      expect(await engine.ensureLoaded(), isFalse);
      expect(engine.ready, isFalse);

      // 失败后已置 _failed ⇒ 再次调用走短路，仍是 false
      expect(await engine.ensureLoaded(), isFalse);
      engine.dispose();
    });

    test('NTT-10 模型目录不存在 ⇒ 进入拷贝分支，rootBundle 缺失也安全失败', () async {
      final tmp = await Directory.systemTemp.createTemp('ntt_case10');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } on Object {
          // 清理失败不影响断言
        }
      });

      // 不预建 `sonic_shield_tts/<modelDir>` ⇒ 走 create + 逐文件 rootBundle.load。
      // 单元测试环境没有真实 asset bundle ⇒ 第一次 load 就抛 ⇒ catch 兜住。
      mockSupportDir(tmp);

      final engine = NeuralTtsEngine();
      expect(await engine.ensureLoaded(), isFalse);
      expect(engine.ready, isFalse);

      // 目录被创建过（create 在 load 之前执行），证明确实进了拷贝分支
      final dest = Directory(
        '${tmp.path}${Platform.pathSeparator}sonic_shield_tts'
        '${Platform.pathSeparator}vits-piper-zh_CN-xiao_ya-medium',
      );
      expect(dest.existsSync(), isTrue);
      engine.dispose();
    });
  });
}
