// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/controller_service.dart';

import 'support/source_text.dart';

/// **远程音量模块锁**（v1.9，Y1）。
///
/// ## 缺陷形状（改造前）
///
/// `lib/features/remote/remote_console_tab.dart` 的「守卫与音量」区只有一个
/// **写死按钮**：
///
/// ```dart
/// OutlinedButton(
///     onPressed: _allowed(RcCmd.volumeSet)
///         ? () => _send(RcCmd.volumeSet, {'media': 0.8}, '媒体音量 80%')
///         : null,
///     child: const Text('音量 80%')),
/// ```
///
/// —— 音量只能设 80%，payload 在 UI 里就地拼装，端点对 `media` 又不做
/// 范围校验（`as num?` 后直接透传原生），边界契约没人负责。
///
/// ## 改造（判定与接线分离）
///
/// payload 形状 / 文案 / 档位收进 `controller_service.dart` 的三个**纯函数**
/// （`volumePayloadForPercent` / `volumeLabelForPercent` / `volumeQuickSteps`），
/// 控制台只负责接线。
///
/// ## 本锁锁什么
///
/// | 组 | 不变量 |
/// |---|---|
/// | FN    | 0–100 → payload/文案正确；越界钳制；0 显示「静音」；档位恰为 [0,25,50,75,100] |
/// | WIRE  | 控制台接线三个纯函数 + 仍用 `_allowed(RcCmd.volumeSet)` 门禁 + 写死 `{'media': 0.8}` 已消失 |
/// | 90    | 判定器对旧写法/去门禁/绕函数三种反例**必须判红**（非恒真铁律） |
///
/// ⚠️ **诚实声明本锁的能力边界**：WIRE 组是**源码文本锁**，能抓住「有人把
/// 滑杆改回写死 80%」「有人绕开纯函数就地拼 payload」「有人拆掉协助会话
/// 门禁」这类回归；抓不住「滑杆松手事件在真机上是否真的触发」——后者靠
/// widget 测试（既有 `remote_console_tab_test.dart` 覆盖其它入口的同类路径）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final consoleSrc =
      File('lib/features/remote/remote_console_tab.dart').readAsStringSync();

  // **剥掉注释**再做文本扫描 —— 这是接线锁能被信任的前提。
  //
  // 本项目刻意在注释里写明锁的理由（例如"不要写死 media"），若不剥注释，
  // 锁会把自己的**说明文字**当成违规（假红），于是下一个人只会去删注释。
  // 字符串字面量整段保留（字符串里的违规仍是代码级违规）。
  //
  // 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源）。

  /// 接线判定器：音量在控制台的接线是否合规。
  ///
  /// 返回 null = 通过；否则返回**具体缺失项**（便于定位，也便于反面样本断言）。
  String? judgeVolumeWiring(String src) {
    // ① 三个纯函数必须真的被引用（判定与接线分离；写死任意一个都算缺线）。
    for (final fn in const [
      'volumePayloadForPercent',
      'volumeLabelForPercent',
      'volumeQuickSteps',
    ]) {
      if (!src.contains(fn)) return '控制台未接线纯函数 $fn';
    }
    // ② 门禁必须仍是 `_allowed(RcCmd.volumeSet)`：协助会话按端点放行的
    //    volume 位灰化 —— 另造一套门禁会与其它按钮漂移。
    if (!src.contains('_allowed(RcCmd.volumeSet)')) {
      return '音量面板丢失 _allowed(RcCmd.volumeSet) 门禁（协助会话权限位灰化失效）';
    }
    // ③ 写死的 media 字面量不得回来：payload 必须只出自
    //    volumePayloadForPercent（就地拼装 = 边界契约没人负责）。
    if (src.contains("'media'")) {
      return "写死的 'media' 字面量回到控制台（payload 必须只出自 volumePayloadForPercent）";
    }
    return null;
  }

  // ════════════════════════════════════════════════════ FN · 纯函数行为
  group('VL-FN 纯函数行为（穷举）', () {
    test('VL-01 快捷档位 payload 与文案（0/25/50/75/100）', () {
      expect(volumePayloadForPercent(0), {'media': 0.0});
      expect(volumePayloadForPercent(25), {'media': 0.25});
      expect(volumePayloadForPercent(50), {'media': 0.5});
      expect(volumePayloadForPercent(75), {'media': 0.75});
      expect(volumePayloadForPercent(100), {'media': 1.0});

      expect(volumeLabelForPercent(0), '静音');
      expect(volumeLabelForPercent(25), '媒体音量 25%');
      expect(volumeLabelForPercent(50), '媒体音量 50%');
      expect(volumeLabelForPercent(75), '媒体音量 75%');
      expect(volumeLabelForPercent(100), '媒体音量 100%');
    });

    test('VL-02 越界钳制（-5 → 0，105 → 100）', () {
      expect(volumePayloadForPercent(-5), {'media': 0.0},
          reason: '端点对 media 不做范围校验，钳制必须在控制端完成');
      expect(volumePayloadForPercent(105), {'media': 1.0});
      expect(volumeLabelForPercent(-5), '静音');
      expect(volumeLabelForPercent(105), '媒体音量 100%');
    });

    test('VL-03 0 必须显示「静音」（不得显示"媒体音量 0%"）', () {
      expect(volumeLabelForPercent(0), '静音');
      expect(volumeLabelForPercent(0).contains('0%'), isFalse);
    });

    test('VL-04 快捷档位恰为 [0, 25, 50, 75, 100]', () {
      expect(volumeQuickSteps(), [0, 25, 50, 75, 100]);
    });

    test('VL-05 每个档位的 payload 都落在端点可解析的 0..1', () {
      // 端点读取形状（已核实）：`(payload['media'] as num?)?.toDouble()`。
      for (final s in volumeQuickSteps()) {
        final media = volumePayloadForPercent(s)['media'];
        expect(media, isA<num>());
        expect((media as num).toDouble(), inInclusiveRange(0.0, 1.0));
      }
    });
  });

  // ══════════════════════════════════════════════ WIRE · 接线锁（源码文本）
  group('VL-WIRE 接线锁（源码文本锁，剥注释后扫描）', () {
    test('VL-10 判定器锚定到真实接线（当前源码应通过）', () {
      final verdict = judgeVolumeWiring(stripComments(consoleSrc));
      expect(verdict, isNull,
          reason: '当前源码应通过判定，缺：$verdict（锚点丢了 → 本锁整组空转）');
    });

    test('VL-11 三个纯函数均被控制台引用', () {
      final src = stripComments(consoleSrc);
      expect(src.contains('volumePayloadForPercent'), isTrue);
      expect(src.contains('volumeLabelForPercent'), isTrue);
      expect(src.contains('volumeQuickSteps'), isTrue);
    });

    test('VL-12 _allowed(RcCmd.volumeSet) 门禁仍在（剥注释后）', () {
      expect(stripComments(consoleSrc).contains('_allowed(RcCmd.volumeSet)'),
          isTrue,
          reason: '协助会话按端点放行的 volume 位灰化 —— 拆掉门禁等于'
              '未授权的对端也能在 UI 上发音量命令');
    });

    test("VL-13 写死 {'media': 0.8} 已消失（剥注释后不得出现 'media' 字面量）",
        () {
      expect(stripComments(consoleSrc).contains("'media'"), isFalse,
          reason: 'payload 必须只出自 volumePayloadForPercent；'
              "就地拼 'media' = 边界契约没人负责（端点不校验范围）");
    });

    test('VL-14 iOS 平台边界小字仍在（I-4 诚实边界）', () {
      expect(stripComments(consoleSrc).contains('iOS 当前不支持'), isTrue,
          reason: 'iOS 上 volume.set 恒失败（已登记 I-4），'
              'UI 必须如实说明，否则使用者会以为坏了');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 非恒真证明：用**反面样本**验证检测器真的会判红
  // ══════════════════════════════════════════════════════════════════
  group('VL-90 判定器有效性（反面样本必须判红）', () {
    test('VL-90a 旧写法（写死 80% 按钮）→ 判红', () {
      const old = '''
            OutlinedButton(
                onPressed: _allowed(RcCmd.volumeSet)
                    ? () => _send(RcCmd.volumeSet, {'media': 0.8}, '媒体音量 80%')
                    : null,
                child: const Text('音量 80%')),
''';
      expect(judgeVolumeWiring(stripComments(old)), isNotNull,
          reason: '★ 若这条样本被判为"通过"，说明检测器恒真 —— 整组锁是假的');
    });

    test('VL-90b 接了纯函数但丢了 _allowed 门禁 → 判红', () {
      const gateless = '''
            Slider(
              onChanged: (v) => _sendVolume(v.round()),
              onChangeEnd: (v) => _sendVolume(v.round()),
            );
            volumeQuickSteps();
            volumeLabelForPercent(80);
            volumePayloadForPercent(80);
''';
      expect(judgeVolumeWiring(stripComments(gateless)), isNotNull,
          reason: '门禁锁必须真的生效（丢了协助会话权限位灰化 = 越权面）');
    });

    test('VL-90c 门禁与纯函数都在、但绕开函数就地写死 media → 判红', () {
      const bypass = '''
            OutlinedButton(
                onPressed: _allowed(RcCmd.volumeSet)
                    ? () {
                        volumeQuickSteps();
                        volumeLabelForPercent(80);
                        volumePayloadForPercent(80);
                        _send(RcCmd.volumeSet, {'media': 0.8}, '媒体音量 80%');
                      }
                    : null,
                child: const Text('音量 80%')),
''';
      expect(judgeVolumeWiring(stripComments(bypass)), isNotNull,
          reason: '三条都在却仍就地拼 payload = 改造被架空，必须判红');
    });
  });
}
