// ignore_for_file: avoid_print
/// 声盾预置音效库生成器（程序化音频合成）。
///
/// 设计原则：
/// - 纯 Dart 实现，`dart run tool/gen_sfx.dart` 一键生成，可进 CI 复现；
/// - 物理声学建模：冲击模态合成（mode synthesis）、共振峰人声合成
///   （formant synthesis）、统计噪声（白/粉/棕）、一阶/双二阶滤波；
/// - 输出 22.05kHz 单声道 16bit PCM WAV（体积友好，APK 可内置）；
/// - 同步产出 manifest.json 供应用内「导入预置音效」使用。
///
/// 法律属性：全部音效为程序化合成，无任何采样素材，无版权风险。
/// 真实录音扩展路径见 docs/11（CC0 资源包）。
library;

import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

const int sampleRate = 22050;
final Random _rng = Random(20260913); // 固定种子：完全可复现

// ============================================================
// 基础信号工具
// ============================================================

List<double> silence(double seconds) =>
    List.filled((seconds * sampleRate).round(), 0.0);

List<double> whiteNoise(double seconds) => List.generate(
    (seconds * sampleRate).round(), (_) => _rng.nextDouble() * 2 - 1);

/// 粉噪声（Paul Kellet 近似，-3dB/oct）。
List<double> pinkNoise(double seconds) {
  var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0;
  return List.generate((seconds * sampleRate).round(), (_) {
    final w = _rng.nextDouble() * 2 - 1;
    b0 = 0.99886 * b0 + w * 0.0555179;
    b1 = 0.99332 * b1 + w * 0.0750759;
    b2 = 0.96900 * b2 + w * 0.1538520;
    b3 = 0.86650 * b3 + w * 0.3104856;
    b4 = 0.55000 * b4 + w * 0.5329522;
    b5 = -0.7616 * b5 - w * 0.0168980;
    final v = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11;
    b6 = w * 0.115926;
    return v;
  });
}

/// 棕噪声（布朗运动积分，-6dB/oct）。
List<double> brownNoise(double seconds) {
  var last = 0.0;
  return List.generate((seconds * sampleRate).round(), (_) {
    final w = _rng.nextDouble() * 2 - 1;
    last = (last + 0.02 * w) / 1.02;
    return last * 3.5;
  });
}

List<double> sine(double freq, double seconds, {double amp = 1.0}) {
  final n = (seconds * sampleRate).round();
  return List.generate(n, (i) => amp * sin(2 * pi * freq * i / sampleRate));
}

/// 频率扫描（线性 chirp）。
List<double> sweep(double f0, double f1, double seconds, {double amp = 1.0}) {
  final n = (seconds * sampleRate).round();
  final out = List<double>.filled(n, 0);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final f = f0 + (f1 - f0) * t;
    phase += 2 * pi * f / sampleRate;
    out[i] = amp * sin(phase);
  }
  return out;
}

/// 抖频正弦（自然感：微小频率颤动）。
List<double> wobbleSine(double freq, double seconds,
    {double amp = 1.0, double wobbleHz = 5, double wobbleDepth = 0.02}) {
  final n = (seconds * sampleRate).round();
  final out = List<double>.filled(n, 0);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final f = freq * (1 + wobbleDepth * sin(2 * pi * wobbleHz * t));
    phase += 2 * pi * f / sampleRate;
    out[i] = amp * sin(phase);
  }
  return out;
}

/// 一阶低通。
List<double> lowpass(List<double> x, double cutoffHz) {
  const dt = 1 / sampleRate;
  final rc = 1 / (2 * pi * cutoffHz);
  final a = dt / (rc + dt);
  final out = List<double>.filled(x.length, 0);
  var y = 0.0;
  for (var i = 0; i < x.length; i++) {
    y += a * (x[i] - y);
    out[i] = y;
  }
  return out;
}

/// 一阶高通。
List<double> highpass(List<double> x, double cutoffHz) {
  final lp = lowpass(x, cutoffHz);
  return [for (var i = 0; i < x.length; i++) x[i] - lp[i]];
}

/// 简易带通 = 高通(低截) 再低通(高截)。
List<double> bandpass(List<double> x, double lo, double hi) =>
    lowpass(highpass(x, lo), hi);

/// 二阶谐振器（用于金属 ringing/管腔共鸣）。
List<double> resonator(List<double> x, double freq, double q) {
  final w0 = 2 * pi * freq / sampleRate;
  final r = exp(-w0 / (2 * q));
  final b1 = 2 * r * cos(w0);
  final b2 = -r * r;
  final a0 = 1 - b1 - b2;
  var y1 = 0.0, y2 = 0.0;
  final out = List<double>.filled(x.length, 0);
  for (var i = 0; i < x.length; i++) {
    final y = a0 * x[i] + b1 * y1 + b2 * y2;
    out[i] = y;
    y2 = y1;
    y1 = y;
  }
  return out;
}

/// 指数衰减包络（tau 为衰减常数秒）。
List<double> expDecayEnv(int n, double tau) =>
    List.generate(n, (i) => exp(-i / sampleRate / tau));

/// 攻击-衰减包络（attack 秒线性起振，随后指数衰减）。
List<double> attackDecayEnv(int n, double attackSec, double tau) {
  final a = (attackSec * sampleRate).round().clamp(1, n);
  return List.generate(n, (i) {
    final attack = i < a ? i / a : 1.0;
    return attack * exp(-(i - a < 0 ? 0 : i - a) / sampleRate / tau);
  });
}

/// 整段淡入淡出。
List<double> fadeEdges(List<double> x, double fadeInSec, double fadeOutSec) {
  final fi = (fadeInSec * sampleRate).round().clamp(0, x.length);
  final fo = (fadeOutSec * sampleRate).round().clamp(0, x.length);
  final out = [...x];
  for (var i = 0; i < fi; i++) {
    out[i] *= i / fi;
  }
  for (var i = 0; i < fo; i++) {
    out[x.length - 1 - i] *= i / fo;
  }
  return out;
}

/// 混合（就地叠加 src 到 dst，srcAmp 控制 src 电平）。
List<double> mixInto(List<double> dst, List<double> src,
    {double srcAmp = 1.0, int at = 0}) {
  for (var i = 0; i < src.length; i++) {
    final j = at + i;
    if (j >= 0 && j < dst.length) dst[j] += src[i] * srcAmp;
  }
  return dst;
}

List<double> mix(List<List<double>> parts) {
  final n = parts.fold<int>(0, (m, p) => max(m, p.length));
  final out = List<double>.filled(n, 0);
  for (final p in parts) {
    mixInto(out, p);
  }
  return out;
}

/// 归一化到峰值 peak。
List<double> normalize(List<double> x, [double peak = 0.92]) {
  var m = 0.0;
  for (final v in x) {
    final a = v.abs();
    if (a > m) m = a;
  }
  if (m < 1e-9) return x;
  final g = peak / m;
  return [for (final v in x) v * g];
}

// ============================================================
// 建模乐器/声源
// ============================================================

/// 冲击模态合成：一组模态频率带指数衰减 ringing，由短噪声脉冲激励。
List<double> strike({
  required List<double> modes, // 模态频率
  required double decay, // 衰减常数（秒）
  double dur = 1.2,
  double q = 18,
  double attackSec = 0.002,
}) {
  final n = (dur * sampleRate).round();
  final impulse = List<double>.filled(n, 0);
  final an = (attackSec * sampleRate).round().clamp(1, n);
  for (var i = 0; i < an; i++) {
    impulse[i] = (_rng.nextDouble() * 2 - 1) * (1 - i / an);
  }
  final out = List<double>.filled(n, 0);
  for (final f in modes) {
    mixInto(out, resonator(impulse, f, q));
  }
  final env = expDecayEnv(n, decay);
  return [for (var i = 0; i < n; i++) out[i] * env[i]];
}

/// 木质敲击（快衰减 + 低中频模态）。
List<double> woodKnock(double base, double dur) => strike(
      modes: [base, base * 2.7, base * 4.9],
      decay: dur * 0.35,
      dur: dur,
      q: 12,
    );

/// 摩擦拖拽：带通噪声 + 缓慢幅度起伏（人为节奏）。
List<double> frictionDrag(double seconds,
    {double lo = 180,
    double hi = 1400,
    double wobble = 2.2,
    double amp = 1.0}) {
  final n = (seconds * sampleRate).round();
  final raw = bandpass(whiteNoise(seconds), lo, hi);
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final m = 0.55 + 0.45 * sin(2 * pi * wobble * t + sin(2 * pi * 0.7 * t));
    out[i] = raw[i] * m * amp;
  }
  return out;
}

/// 共振峰人声近似（3 共振峰 + 基频 + 开口噪声）。
/// 不是真实人声录音，是"类人声"合成（合规与版权双安全）。
List<double> formantVoice({
  required double f0,
  required double dur,
  required List<List<double>> formants, // [(freq, bw, amp), ...]
  double vibrato = 5,
  double vibDepth = 0.03,
  double breath = 0.15,
}) {
  final n = (dur * sampleRate).round();
  final glottal = wobbleSine(f0, dur, wobbleHz: vibrato, wobbleDepth: vibDepth);
  // 基频谐波激励 → 各共振峰带通。
  final out = List<double>.filled(n, 0);
  for (final fm in formants) {
    mixInto(out, resonator(glottal, fm[0], fm[0] / fm[1]), srcAmp: fm[2]);
  }
  if (breath > 0) {
    mixInto(out, bandpass(whiteNoise(dur), 1800, 5200), srcAmp: breath);
  }
  return out;
}

/// 雨声：宽带噪声底 + 随机雨滴脉冲群。
List<double> rain(double seconds, {int dropsPerSec = 90, double heavy = 1.0}) {
  final n = (seconds * sampleRate).round();
  final bed = bandpass(whiteNoise(seconds), 400, 3200);
  final out = List<double>.filled(n, 0);
  mixInto(out, bed, srcAmp: 0.5 * heavy);
  final drops = (dropsPerSec * seconds * heavy).round();
  for (var d = 0; d < drops; d++) {
    final at = _rng.nextInt(n - 400);
    final dur = 0.004 + _rng.nextDouble() * 0.012;
    final drop = highpass(
        strike(
          modes: [2400 + _rng.nextDouble() * 3600],
          decay: dur,
          dur: dur * 2.2,
          q: 6,
        ),
        1200);
    mixInto(out, drop, srcAmp: 0.35 + _rng.nextDouble() * 0.4, at: at);
  }
  return out;
}

/// 风：粉噪声 + 缓慢多正弦幅度调制。
List<double> wind(double seconds) {
  final n = (seconds * sampleRate).round();
  final raw = lowpass(pinkNoise(seconds), 900);
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final m = 0.5 +
        0.28 * sin(2 * pi * 0.17 * t) +
        0.16 * sin(2 * pi * 0.41 * t + 1.3) +
        0.10 * sin(2 * pi * 0.83 * t + 2.1);
    out[i] = raw[i] * m;
  }
  return out;
}

/// 波浪：棕噪声 + 周期性涌动包络。
List<double> waves(double seconds, {double period = 6}) {
  final n = (seconds * sampleRate).round();
  final raw = bandpass(brownNoise(seconds), 120, 1800);
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final ph = (t % period) / period;
    final swell = pow(sin(pi * ph), 2.2).toDouble();
    out[i] = raw[i] * (0.25 + 0.75 * swell);
  }
  return out;
}

// ============================================================
// WAV 写出与登记
// ============================================================

final List<Map<String, dynamic>> manifest = [];

void emit(String category, String id, String name, String desc, List<double> x,
    {double peak = 0.9}) {
  final norm = fadeEdges(
      normalize(x, peak), 0.008, min(0.05, x.length / sampleRate / 3));
  final fileName = 'presets/${category}_$id.wav';
  final f = File('assets/audio/$fileName');
  f.createSync(recursive: true);
  final n = norm.length;
  final bytes = BytesBuilder();
  // RIFF header
  bytes.add(utf8.encode('RIFF'));
  bytes.add(_u32(36 + n * 2));
  bytes.add(utf8.encode('WAVEfmt '));
  bytes.add(_u32(16));
  bytes.add(_u16(1)); // PCM
  bytes.add(_u16(1)); // mono
  bytes.add(_u32(sampleRate));
  bytes.add(_u32(sampleRate * 2));
  bytes.add(_u16(2)); // block align
  bytes.add(_u16(16)); // bits
  bytes.add(utf8.encode('data'));
  bytes.add(_u32(n * 2));
  for (final v in norm) {
    final s = (v.clamp(-1.0, 1.0) * 32767).round();
    bytes.addByte(s & 0xff);
    bytes.addByte((s >> 8) & 0xff);
  }
  f.writeAsBytesSync(bytes.toBytes());
  manifest.add({
    'id': '${category}_$id',
    'category': category,
    'name': name,
    'desc': desc,
    'file': fileName,
    'durationMs': (n / sampleRate * 1000).round(),
  });
}

List<int> _u32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];

// ============================================================
// 音效库定义（13 类：12 类 × 5 条 + annoy 10 条 = 70 种）
// ============================================================

void main() {
  Directory('assets/audio/presets').createSync(recursive: true);

  // ---------- 1. knocks 敲击 ----------
  emit('knocks', 'door_single', '敲门（单下）', '中低频木门敲击', woodKnock(140, 0.5));
  emit('knocks', 'door_triple', '敲门（三连）', '礼貌三连敲节奏', () {
    final out = silence(1.6);
    mixInto(out, woodKnock(140, 0.5), at: 0);
    mixInto(out, woodKnock(140, 0.5), at: (0.32 * sampleRate).round());
    mixInto(out, woodKnock(150, 0.5), at: (0.64 * sampleRate).round());
    return out;
  }());
  emit('knocks', 'table', '敲桌', '硬质桌面清脆敲击', woodKnock(210, 0.35));
  emit('knocks', 'knuckle_rapid', '急促指关节', '快速连续指关节敲击', () {
    final out = silence(1.2);
    for (var i = 0; i < 6; i++) {
      mixInto(out, woodKnock(230 + _rng.nextDouble() * 40, 0.22),
          at: (i * 0.16 * sampleRate).round());
    }
    return out;
  }());
  emit(
      'knocks',
      'window',
      '敲窗',
      '玻璃窗轻敲（高频轻脆）',
      strike(
        modes: [820, 1690, 3100],
        decay: 0.12,
        dur: 0.4,
        q: 22,
      ));

  // ---------- 2. impacts 撞击 ----------
  emit('impacts', 'thud_heavy', '重物落地', '低频沉重闷响', () {
    final n = (1.0 * sampleRate).round();
    final body = lowpass(whiteNoise(1.0), 160);
    final env = attackDecayEnv(n, 0.004, 0.09);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      out[i] = body[i] * env[i];
    }
    mixInto(out, strike(modes: [62, 96], decay: 0.22, dur: 1.0, q: 8),
        srcAmp: 0.8);
    return out;
  }());
  emit('impacts', 'cabinet', '柜门碰撞', '木质柜门合上', woodKnock(105, 0.55));
  emit('impacts', 'ball_bounce', '球体弹跳', '弹性球两次落地', () {
    final out = silence(1.0);
    mixInto(out, strike(modes: [180, 420], decay: 0.06, dur: 0.3, q: 14));
    mixInto(out, strike(modes: [180, 420], decay: 0.05, dur: 0.25, q: 14),
        srcAmp: 0.6, at: (0.34 * sampleRate).round());
    return out;
  }());
  emit('impacts', 'books_drop', '书本摔落', '一摞书落地（多层冲击）', () {
    final out = silence(1.1);
    mixInto(out, woodKnock(90, 0.4));
    mixInto(out, woodKnock(120, 0.35),
        srcAmp: 0.8, at: (0.09 * sampleRate).round());
    mixInto(out, lowpass(whiteNoise(0.3), 500),
        srcAmp: 0.5, at: (0.12 * sampleRate).round());
    return out;
  }());
  emit('impacts', 'muffled_boom', '隔壁闷响', '墙体另一侧的低频闷响', () {
    final out =
        lowpass(strike(modes: [48, 74, 110], decay: 0.3, dur: 1.2, q: 7), 300);
    return out;
  }());

  // ---------- 3. drags 摩擦拖拽 ----------
  emit('drags', 'chair_short', '拖椅子（短促）', '椅腿与地板摩擦', frictionDrag(1.1));
  emit('drags', 'chair_long', '拖椅子（长距离）', '持续拖拽 3 秒',
      frictionDrag(3.0, wobble: 1.4));
  emit('drags', 'box_slide', '拖箱子', '纸箱/木箱在地板滑动',
      frictionDrag(2.0, lo: 120, hi: 900, wobble: 1.0));
  emit('drags', 'floor_scrape', '地板刮擦', '重物刮过地面（刺耳高频）',
      frictionDrag(1.6, lo: 900, hi: 4200, wobble: 3.5));
  emit('drags', 'desk_push', '桌面推物', '物体被推过桌面', () {
    final raw = frictionDrag(1.2, lo: 500, hi: 2600, wobble: 2.8);
    final out = List<double>.filled(raw.length, 0);
    for (var i = 0; i < raw.length; i++) {
      final t = i / raw.length;
      out[i] = raw[i] * (0.3 + 0.7 * t); // 渐强
    }
    return out;
  }());

  // ---------- 4. doors 门窗 ----------
  emit('doors', 'creak', '开门吱呀', '铰链摩擦的吱呀声', () {
    final out = silence(1.8);
    final sweepNoise = bandpass(
        List.generate((1.8 * sampleRate).round(), (i) {
          
          return _rng.nextDouble() * 2 - 1;
        }),
        600,
        2600);
    for (var i = 0; i < out.length; i++) {
      final t = i / out.length;
      final f = 500 + 900 * sin(t * pi); // 频率起伏模拟铰链粘滑
      final m = 0.4 + 0.6 * sin(t * pi * 3.2).abs();
      out[i] = sweepNoise[i] * m * 0.9 * (0.5 + 0.5 * sin(t * pi));
      // 粘滑抖动
      if (sin(2 * pi * f * t / 100) > 0.7) out[i] *= 0.55;
    }
    return out;
  }());
  emit('doors', 'slam', '关门砰', '门板大力关上', () {
    final n = (0.9 * sampleRate).round();
    final body = lowpass(whiteNoise(0.9), 220);
    final env = attackDecayEnv(n, 0.003, 0.07);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      out[i] = body[i] * env[i];
    }
    mixInto(out, strike(modes: [88, 150, 320], decay: 0.12, dur: 0.9, q: 10),
        srcAmp: 0.7);
    return out;
  }());
  emit('doors', 'latch', '锁扣', '门锁扣上脆响',
      strike(modes: [1250, 2400, 3600], decay: 0.05, dur: 0.25, q: 20));
  emit('doors', 'doorbell', '门铃（叮咚）', '双音电子门铃', () {
    final out = silence(1.6);
    mixInto(out,
        fadeEdges(mix([sine(659, 0.9), sine(1319, 0.9, amp: 0.4)]), 0.01, 0.6));
    mixInto(out,
        fadeEdges(mix([sine(523, 0.9), sine(1047, 0.9, amp: 0.4)]), 0.01, 0.6),
        srcAmp: 0.95, at: (0.5 * sampleRate).round());
    return out;
  }());
  emit('doors', 'knob_rattle', '拧门把手', '把手转动金属声', () {
    final out = silence(0.9);
    mixInto(out, strike(modes: [900, 1700], decay: 0.04, dur: 0.2, q: 16));
    mixInto(out, strike(modes: [1100, 2100], decay: 0.04, dur: 0.2, q: 16),
        srcAmp: 0.7, at: (0.22 * sampleRate).round());
    return out;
  }());

  // ---------- 5. glass 陶瓷玻璃 ----------
  emit(
      'glass',
      'clink',
      '玻璃轻碰',
      '两只杯子轻碰',
      strike(
        modes: [1980, 3150, 4400, 5300],
        decay: 0.28,
        dur: 0.7,
        q: 40,
      ));
  emit('glass', 'shatter', '玻璃碎裂', '落地碎裂（噪声簇+高频爆）', () {
    final out = silence(1.3);
    mixInto(out, strike(modes: [2600, 3800, 5200], decay: 0.18, dur: 0.6, q: 8),
        srcAmp: 0.7);
    for (var i = 0; i < 26; i++) {
      final at = (0.02 + _rng.nextDouble() * 0.5) * sampleRate ~/ 1;
      mixInto(
          out,
          strike(
            modes: [1800 + _rng.nextDouble() * 5000],
            decay: 0.05 + _rng.nextDouble() * 0.12,
            dur: 0.35,
            q: 30,
          ),
          srcAmp: 0.3 + _rng.nextDouble() * 0.6,
          at: at);
    }
    return out;
  }());
  emit(
      'glass',
      'cup_set',
      '杯放桌面',
      '瓷杯轻放磕碰',
      strike(
        modes: [1150, 2300, 3400],
        decay: 0.12,
        dur: 0.4,
        q: 26,
      ));
  emit(
      'glass',
      'bottle_cap',
      '瓶盖',
      '汽水瓶盖脆响',
      strike(
        modes: [2900, 4300, 6100],
        decay: 0.04,
        dur: 0.2,
        q: 24,
      ));
  emit(
      'glass',
      'ceramic_knock',
      '瓷碗磕',
      '碗沿轻磕',
      strike(
        modes: [1560, 2900, 4700],
        decay: 0.2,
        dur: 0.5,
        q: 34,
      ));

  // ---------- 6. human 人声近似 ----------
  emit('human', 'cough', '咳嗽', '两声短促咳嗽', () {
    List<double> one(double at) {
      const d = 0.28;
      final burst = bandpass(whiteNoise(d), 500, 2400);
      final n = (d * sampleRate).round();
      final env = attackDecayEnv(n, 0.012, 0.06);
      return [for (var i = 0; i < n; i++) burst[i] * env[i]];
    }

    final out = silence(1.1);
    mixInto(out, one(0));
    mixInto(out, one(0), srcAmp: 0.85, at: (0.36 * sampleRate).round());
    return out;
  }());
  emit('human', 'throat_clear', '清嗓', '单声清嗓', () {
    const d = 0.32;
    final n = (d * sampleRate).round();
    final burst = bandpass(whiteNoise(d), 700, 3000);
    final env = attackDecayEnv(n, 0.02, 0.08);
    return [for (var i = 0; i < n; i++) burst[i] * env[i]];
  }());
  emit('human', 'sneeze', '喷嚏', '快速吸气+喷发', () {
    final out = silence(0.8);
    mixInto(out, bandpass(whiteNoise(0.12), 900, 4000), srcAmp: 0.5);
    const d = 0.25;
    final n = (d * sampleRate).round();
    final burst = bandpass(whiteNoise(d), 600, 2600);
    final env = attackDecayEnv(n, 0.008, 0.05);
    mixInto(out, [for (var i = 0; i < n; i++) burst[i] * env[i]],
        srcAmp: 1.0, at: (0.14 * sampleRate).round());
    return out;
  }());
  emit('human', 'sigh', '叹气', '长呼气叹声', () {
    const d = 1.4;
    final breath = bandpass(whiteNoise(d), 300, 1600);
    final n = breath.length;
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final env = sin(pi * min(1.0, t * 1.15)) * (1 - t * 0.5);
      out[i] = breath[i] * env * 0.9;
    }
    return out;
  }());
  emit(
      'human',
      'hey_call',
      '短促招呼（合成人声）',
      '共振峰合成的「喂/嘿」类呼喊',
      formantVoice(
        f0: 205,
        dur: 0.85,
        formants: [
          [620, 110, 1.0],
          [1180, 130, 0.55],
          [2600, 180, 0.28],
        ],
        vibDepth: 0.045,
        breath: 0.1,
      ));

  // ---------- 7. animals 动物 ----------
  emit('animals', 'dog_bark_a', '狗吠（低沉）', '中大型犬吠声近似', () {
    const d = 0.32;
    final body = mix([
      formantVoice(
          f0: 130,
          dur: d,
          formants: [
            [700, 200, 1.0],
            [1350, 250, 0.6],
            [2500, 350, 0.3],
          ],
          vibDepth: 0.08,
          breath: 0.3),
      bandpass(whiteNoise(d), 400, 1600),
    ]);
    final n = body.length;
    final env = attackDecayEnv(n, 0.02, 0.09);
    return [for (var i = 0; i < n; i++) body[i] * env[i]];
  }());
  emit('animals', 'dog_bark_b', '狗吠（清脆）', '小型犬连续两声', () {
    List<double> one() {
      const d = 0.2;
      final body = formantVoice(
          f0: 260,
          dur: d,
          formants: [
            [950, 260, 1.0],
            [1900, 320, 0.5],
          ],
          vibDepth: 0.1,
          breath: 0.25);
      final n = body.length;
      final env = attackDecayEnv(n, 0.015, 0.06);
      return [for (var i = 0; i < n; i++) body[i] * env[i]];
    }

    final out = silence(0.9);
    mixInto(out, one());
    mixInto(out, one(), srcAmp: 0.9, at: (0.3 * sampleRate).round());
    return out;
  }());
  emit('animals', 'cat_meow', '猫叫', '喵声近似（滑频共振峰）', () {
    final out = List<double>.filled((0.9 * sampleRate).round(), 0);
    final seg = formantVoice(
        f0: 480,
        dur: 0.9,
        formants: [
          [820, 160, 1.0],
          [1500, 200, 0.5],
          [2800, 260, 0.25],
        ],
        vibDepth: 0.06,
        breath: 0.08);
    // 尾音下滑
    for (var i = 0; i < out.length; i++) {
      final t = i / out.length;
      final sag = 1 - 0.35 * t;
      out[i] = seg[i] * sag;
    }
    return out;
  }());
  emit('animals', 'bird_chirp', '鸟鸣（婉转）', '调频啁啾两声', () {
    final out = silence(1.2);
    mixInto(out, sweep(2800, 4200, 0.16, amp: 0.8));
    mixInto(out, sweep(3600, 2500, 0.14, amp: 0.7),
        at: (0.28 * sampleRate).round());
    mixInto(out, sweep(3000, 4600, 0.12, amp: 0.6),
        at: (0.6 * sampleRate).round());
    return out;
  }());
  emit('animals', 'rooster', '公鸡打鸣', '喔喔啼近似', () {
    final out = silence(1.8);
    final a = formantVoice(
        f0: 340,
        dur: 0.7,
        formants: [
          [760, 180, 1.0],
          [1500, 240, 0.55],
          [2900, 320, 0.3],
        ],
        vibDepth: 0.07,
        breath: 0.12);
    mixInto(out, a);
    final b = formantVoice(
        f0: 300,
        dur: 0.9,
        formants: [
          [640, 160, 1.0],
          [1300, 220, 0.5],
        ],
        vibDepth: 0.05,
        breath: 0.1);
    mixInto(out, b, srcAmp: 0.9, at: (0.85 * sampleRate).round());
    return out;
  }());

  // ---------- 8. bells 提示铃 ----------
  emit('bells', 'bicycle', '自行车铃', '双金属片叮铃', () {
    final out = silence(1.0);
    for (var i = 0; i < 2; i++) {
      mixInto(
          out, strike(modes: [2093, 2637, 4100], decay: 0.16, dur: 0.4, q: 42),
          srcAmp: 0.85, at: (i * 0.18 * sampleRate).round());
    }
    return out;
  }());
  emit('bells', 'wind_chime', '风铃', '多管随机轻响', () {
    final out = silence(2.4);
    final notes = [1568, 1760, 2093, 2349, 2637, 3136];
    for (var i = 0; i < 7; i++) {
      mixInto(
          out,
          strike(
            modes: [notes[_rng.nextInt(notes.length)].toDouble(), 4200, 5600],
            decay: 0.7,
            dur: 1.2,
            q: 55,
          ),
          srcAmp: 0.4 + _rng.nextDouble() * 0.4,
          at: (_rng.nextDouble() * 1.6 * sampleRate).round());
    }
    return out;
  }());
  emit('bells', 'alarm_clock', '机械闹钟', '经典双铃快速震响', () {
    final out = silence(2.2);
    final n = out.length;
    final strikeEnv = List<double>.filled(n, 0);
    for (var i = 0; i < n; i += (0.045 * sampleRate).round()) {
      final len = (0.03 * sampleRate).round();
      for (var j = 0; j < len && i + j < n; j++) {
        strikeEnv[i + j] = 1 - j / len;
      }
    }
    final ring =
        mix([resonator(strikeEnv, 1720, 30), resonator(strikeEnv, 2280, 30)]);
    mixInto(out, ring, srcAmp: 0.8);
    return out;
  }());
  emit('bells', 'school', '上课铃', '电铃持续响', () {
    final out = silence(2.0);
    final n = out.length;
    final pulse = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      pulse[i] = (sin(2 * pi * 24 * i / sampleRate) > 0 ? 1.0 : 0.35);
    }
    final tone = mix([sine(880, 2.0, amp: 0.7), sine(1760, 2.0, amp: 0.3)]);
    for (var i = 0; i < n; i++) {
      out[i] = tone[i] * pulse[i] * 0.8;
    }
    return fadeEdges(out, 0.02, 0.2);
  }());
  emit(
      'bells',
      'temple',
      '钟磬',
      '低沉大钟余韵',
      strike(
        modes: [196, 392, 588, 784, 990],
        decay: 2.2,
        dur: 4.0,
        q: 60,
      ));

  // ---------- 9. alarms 警示 ----------
  emit('alarms', 'beep', '电子哔', '三短 beep', () {
    final out = silence(1.2);
    for (var i = 0; i < 3; i++) {
      mixInto(out, sine(1000, 0.12, amp: 0.8),
          at: (i * 0.3 * sampleRate).round());
    }
    return fadeEdges(out, 0.005, 0.02);
  }());
  emit('alarms', 'siren', '警报扫频', '经典警笛往复', () {
    final out = silence(2.4);
    final n = out.length;
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final f = 620 + 380 * sin(2 * pi * 0.55 * t);
      phase += 2 * pi * f / sampleRate;
      out[i] = sin(phase) * 0.85;
    }
    return out;
  }());
  emit('alarms', 'countdown', '倒计时哔', '急促连哔提示', () {
    final out = silence(2.0);
    for (var i = 0; i < 8; i++) {
      mixInto(out, sine(1400, 0.08, amp: 0.75),
          at: (i * 0.22 * sampleRate).round());
    }
    return fadeEdges(out, 0.004, 0.02);
  }());
  emit('alarms', 'smoke', '防火警报', '高频断续鸣叫', () {
    final out = silence(2.2);
    for (var i = 0; i < 6; i++) {
      mixInto(
          out, mix([sine(3100, 0.16, amp: 0.6), sine(3200, 0.16, amp: 0.6)]),
          at: (i * 0.34 * sampleRate).round());
    }
    return fadeEdges(out, 0.004, 0.03);
  }());
  emit('alarms', 'buzzer', '蜂鸣器', '低沉持续蜂鸣', () {
    final out = silence(1.5);
    final n = out.length;
    final sq = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      sq[i] = sin(2 * pi * 210 * i / sampleRate) > 0 ? 0.7 : -0.7;
    }
    return fadeEdges(lowpass(sq, 1800), 0.01, 0.05);
  }());

  // ---------- 10. nature 自然 ----------
  emit('nature', 'rain', '雨声', '中雨（雨滴+底噪）', rain(5.0));
  emit('nature', 'rain_heavy', '暴雨', '密集雨声',
      rain(5.0, dropsPerSec: 160, heavy: 1.35));
  emit('nature', 'thunder', '雷声', '远雷滚鸣', () {
    final out = silence(4.0);
    final raw = lowpass(whiteNoise(4.0), 220);
    final n = out.length;
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final env = pow(sin(pi * pow(t, 0.6)), 1.6).toDouble();
      out[i] = raw[i] * env;
    }
    mixInto(
        out, lowpass(strike(modes: [52, 78], decay: 1.4, dur: 4.0, q: 5), 200),
        srcAmp: 0.7);
    return out;
  }());
  emit('nature', 'wind', '风声', '树梢夜风', wind(5.0));
  emit('nature', 'waves', '海浪', '涌浪拍岸', waves(6.0));

  // ---------- 11. tech 电子 ----------
  emit('tech', 'msg_pop', '消息提示', '短促水滴音', () {
    return fadeEdges(sweep(880, 1760, 0.16, amp: 0.85), 0.005, 0.04);
  }());
  emit('tech', 'keyboard', '键盘敲击', '机械键盘连击', () {
    final out = silence(1.4);
    for (var i = 0; i < 9; i++) {
      mixInto(
          out,
          strike(
            modes: [2200 + _rng.nextDouble() * 1800, 5200],
            decay: 0.02,
            dur: 0.08,
            q: 14,
          ),
          srcAmp: 0.5 + _rng.nextDouble() * 0.5,
          at: (_rng.nextDouble() * 1.2 * sampleRate).round());
    }
    return out;
  }());
  emit('tech', 'vibration', '手机振动', '马达嗡嗡两下', () {
    final out = silence(1.6);
    final n = out.length;
    final buzz = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final seg = (t % 0.9) < 0.38 ? 1.0 : 0.0;
      buzz[i] = sin(2 * pi * 175 * i / sampleRate) * seg;
    }
    return fadeEdges(lowpass(buzz, 900), 0.01, 0.05);
  }());
  emit('tech', 'mouse_click', '鼠标点击', '清脆双击', () {
    final out = silence(0.5);
    mixInto(out, strike(modes: [3300, 5200], decay: 0.015, dur: 0.06, q: 12));
    mixInto(out, strike(modes: [3500, 5400], decay: 0.015, dur: 0.06, q: 12),
        srcAmp: 0.9, at: (0.13 * sampleRate).round());
    return out;
  }());
  emit('tech', 'ups_beep', '设备提示', '长哔一声',
      fadeEdges(sine(830, 0.8, amp: 0.8), 0.01, 0.08));

  // ---------- 12. ambient 助眠底噪 ----------
  emit('ambient', 'white', '白噪音', '全频带均匀噪声（遮蔽）',
      fadeEdges(whiteNoise(8.0), 0.5, 0.8));
  emit(
      'ambient', 'pink', '粉噪音', '低频偏多更柔和', fadeEdges(pinkNoise(8.0), 0.5, 0.8));
  emit('ambient', 'brown', '棕噪音', '深沉低频（助眠首选）',
      fadeEdges(brownNoise(8.0), 0.5, 0.8));
  emit('ambient', 'rain_night', '雨夜', '雨声+远雷底', () {
    final out = mix([
      rain(8.0, dropsPerSec: 60, heavy: 0.8),
      lowpass(whiteNoise(8.0), 150)
    ]);
    return out;
  }());
  emit('ambient', 'fan', '风扇', '恒定气流传声器噪声', () {
    final n = (8.0 * sampleRate).round();
    final hum = mix([sine(120, 8.0, amp: 0.3), sine(240, 8.0, amp: 0.15)]);
    final air = bandpass(whiteNoise(8.0), 200, 1200);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final blade = 0.85 + 0.15 * sin(2 * pi * 24 * t);
      out[i] = (hum[i] + air[i] * 0.7) * blade;
    }
    return fadeEdges(out, 0.5, 0.8);
  }());

  // ---------- 13. annoy 招人烦（v2.0）----------
  // 合规：仍为**程序化合成**（无采样素材、无版权风险），非真人录音。
  // 用途限定：用户自有设备的「反击/拒绝」场景，实际发声受日间/夜间音量区间
  // 与动作时长上限约束（见 CounterPlan），并遵循夜间免打扰护栏。
  emit('annoy', 'cough_fit', '连声咳嗽', '三声短促连续咳嗽', () {
    List<double> one(double amp) {
      const d = 0.26;
      final burst = bandpass(whiteNoise(d), 420, 2600);
      final n = (d * sampleRate).round();
      final env = attackDecayEnv(n, 0.010, 0.055);
      return [for (var i = 0; i < n; i++) burst[i] * env[i] * amp];
    }

    final out = silence(1.5);
    for (final (at, amp) in [(0.0, 1.0), (0.30, 0.9), (0.56, 0.8)]) {
      mixInto(out, one(amp), at: (at * sampleRate).round());
    }
    return out;
  }());
  emit('annoy', 'throat_clear_hard', '用力清嗓', '低频粗糙的干咳清嗓', () {
    const d = 0.6;
    final n = (d * sampleRate).round();
    final raw = bandpass(whiteNoise(d), 260, 1700);
    final env = attackDecayEnv(n, 0.02, 0.22);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final m = (0.5 + 0.5 * sin(2 * pi * 9 * t)) * env[i];
      out[i] = raw[i] * m;
    }
    return out;
  }());
  emit('annoy', 'spit', '吐痰', '短促的「呸」吐痰音', () {
    final out = silence(0.55);
    // 唇齿爆破：极短宽带噪声簇。
    const bd = 0.10;
    final bn = (bd * sampleRate).round();
    final burst = bandpass(whiteNoise(bd), 900, 6000);
    final benv = attackDecayEnv(bn, 0.004, 0.03);
    mixInto(out, [for (var i = 0; i < bn; i++) burst[i] * benv[i]]);
    // 随后的低频唾沫拖尾。
    final tail = lowpass(whiteNoise(0.30), 900);
    final tn = tail.length;
    final tenv = expDecayEnv(tn, 0.09);
    mixInto(out, [for (var i = 0; i < tn; i++) tail[i] * tenv[i]],
        srcAmp: 0.5, at: (0.08 * sampleRate).round());
    return out;
  }());
  emit('annoy', 'snort_laugh', '嗤笑', '鼻腔「哼」两声嘲笑', () {
    List<double> hn(double f0) => formantVoice(
          f0: f0,
          dur: 0.22,
          formants: [
            [300, 90, 1.0],
            [1100, 140, 0.5],
            [2300, 200, 0.25],
          ],
          breath: 0.35,
          vibDepth: 0.015,
        );

    final out = silence(0.85);
    mixInto(out, hn(150));
    mixInto(out, hn(138), srcAmp: 0.9, at: (0.28 * sampleRate).round());
    return out;
  }());
  emit('annoy', 'jeer', '喝倒彩', '拉长的「嘘」倒彩声', () {
    const d = 1.3;
    final voice = formantVoice(
      f0: 128,
      dur: d,
      formants: [
        [320, 110, 1.0],
        [900, 160, 0.55],
        [2100, 240, 0.2],
      ],
      breath: 0.45,
      vibrato: 4,
      vibDepth: 0.05,
    );
    final n = voice.length;
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / n;
      // 尾音渐弱并微微起伏，像拖长的哄声。
      out[i] = voice[i] * (1 - t * 0.75) * (0.9 + 0.1 * sin(2 * pi * 3 * t));
    }
    return out;
  }());
  emit('annoy', 'tsk', '咂嘴', '两声不满的「啧」', () {
    final click = highpass(
        strike(modes: [2600, 4200, 6000], decay: 0.012, dur: 0.05, q: 10), 1400);
    final out = silence(0.6);
    mixInto(out, click);
    mixInto(out, click, srcAmp: 0.85, at: (0.22 * sampleRate).round());
    return out;
  }());
  emit('annoy', 'grumble', '拖长抱怨', '低沉的嘟囔抱怨声', () {
    const d = 1.6;
    final voice = formantVoice(
      f0: 108,
      dur: d,
      formants: [
        [500, 120, 1.0],
        [1500, 180, 0.5],
        [2500, 260, 0.2],
      ],
      breath: 0.3,
      vibrato: 4.5,
      vibDepth: 0.04,
    );
    final n = voice.length;
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final env = sin(pi * min(1.0, t * 1.1)) * (1 - t * 0.35);
      out[i] = voice[i] * env;
    }
    return out;
  }());
  emit('annoy', 'what_doing', '「干啥呢」', '共振峰合成的「干啥呢」质问', () {
    // 三个音节近似：「干」/「啥」/「呢」（元音 a / a / e）。
    const sylls = <List<double>>[
      [700, 1200, 2600],
      [730, 1090, 2440],
      [500, 1700, 2500],
    ];
    final out = silence(1.1);
    for (var s = 0; s < sylls.length; s++) {
      final v = formantVoice(
        f0: 165 - s * 8.0,
        dur: 0.26,
        formants: [
          [sylls[s][0], 110, 1.0],
          [sylls[s][1], 150, 0.55],
          [sylls[s][2], 220, 0.25],
        ],
        breath: 0.18,
        vibDepth: 0.02,
      );
      mixInto(out, v, at: ((0.05 + s * 0.30) * sampleRate).round());
    }
    return out;
  }());
  emit('annoy', 'hey_you', '「哎」短促喝止', '高起短促的「哎」', () {
    final v = formantVoice(
      f0: 205,
      dur: 0.5,
      formants: [
        [700, 110, 1.0],
        [1250, 150, 0.55],
        [2500, 240, 0.25],
      ],
      breath: 0.2,
      vibDepth: 0.025,
    );
    final n = v.length;
    final env = attackDecayEnv(n, 0.01, 0.16);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / n;
      out[i] = v[i] * env[i] * (1 - t * 0.2);
    }
    return out;
  }());
  emit('annoy', 'mocking_laugh', '讥笑', '「哈哈哈」连串嘲笑', () {
    final out = silence(1.2);
    for (var k = 0; k < 4; k++) {
      final v = formantVoice(
        f0: 178 - k * 6.0,
        dur: 0.18,
        formants: [
          [730, 110, 1.0],
          [1090, 150, 0.5],
          [2440, 220, 0.22],
        ],
        breath: 0.22,
        vibDepth: 0.03,
      );
      mixInto(out, v,
          srcAmp: 1.0 - k * 0.12, at: ((0.06 + k * 0.22) * sampleRate).round());
    }
    return out;
  }());

  // ---------- manifest ----------
  final byCat = <String, int>{};
  for (final m in manifest) {
    byCat[m['category'] as String] = (byCat[m['category'] as String] ?? 0) + 1;
  }
  final out = {
    'version': '1.0.0',
    'sampleRate': sampleRate,
    'license': 'MIT（程序化合成，无采样素材）',
    'generator': 'tool/gen_sfx.dart (seed=20260913)',
    'total': manifest.length,
    'categories': byCat,
    'items': manifest,
  };
  File('assets/audio/presets_manifest.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));

  print('生成 ${manifest.length} 条音效，${byCat.length} 个分类：');
  byCat.forEach((k, v) => print('  $k: $v'));
  print('manifest → assets/audio/presets_manifest.json');
}
