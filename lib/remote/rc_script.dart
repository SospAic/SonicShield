import 'dart:convert';

/// 远程指令组（宏）模型：动作 + 时延的有序序列。
/// 组装器与端点执行器共用同一序列化格式（协议 docs/14）。
///
/// step kind：
/// - play   {volume(0..1), durationSec, presetCategory?}   随机播放（可指定分类）
/// - tts    {text, volume}
/// - notify {title, body}
/// - vibrate {}
/// - record {seconds}
/// - delay  {seconds}   时延元素（0.5s 粒度，单步上限 600s）

enum RcStepKind { play, tts, notify, vibrate, record, delay }

class RcStep {
  const RcStep(this.kind, this.params);

  final RcStepKind kind;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {'kind': kind.name, ...params};

  static RcStep fromJson(Map<String, dynamic> j) {
    final kind = RcStepKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => throw ArgumentError('未知 step kind: ${j['kind']}'),
    );
    return RcStep(kind, {...j}..remove('kind'));
  }

  /// 人类可读描述（通知/弹窗展示）。
  String describe() {
    switch (kind) {
      case RcStepKind.play:
        return '播放${params['presetCategory'] == null ? '' : '（${params['presetCategory']}）'}'
            '${params['durationSec'] == null ? '' : ' ${params['durationSec']}s'}';
      case RcStepKind.tts:
        return '播报「${params['text']}」';
      case RcStepKind.notify:
        return '通知「${params['title']}」';
      case RcStepKind.vibrate:
        return '震动';
      case RcStepKind.record:
        return '录音取证 ${params['seconds']}s';
      case RcStepKind.delay:
        return '等待 ${params['seconds']}s';
    }
  }
}

class RcScript {
  const RcScript({
    required this.scriptId,
    required this.name,
    required this.fromName,
    required this.sentAt,
    required this.steps,
  });

  final String scriptId;
  final String name;
  final String fromName; // 发送方名称（弹窗展示）
  final int sentAt; // 发送时间戳 ms
  final List<RcStep> steps;

  Map<String, dynamic> toJson() => {
        'scriptId': scriptId,
        'name': name,
        'fromName': fromName,
        'sentAt': sentAt,
        'steps': [for (final s in steps) s.toJson()],
      };

  static RcScript fromJson(Map<String, dynamic> j) => RcScript(
        scriptId: j['scriptId'] as String,
        name: j['name'] as String? ?? '远程指令组',
        fromName: j['fromName'] as String? ?? '未知发送方',
        sentAt: (j['sentAt'] as num?)?.toInt() ?? 0,
        steps: [
          for (final s in (j['steps'] as List?) ?? [])
            RcStep.fromJson((s as Map).cast<String, dynamic>()),
        ],
      );

  static RcScript fromPayload(Map<String, dynamic> payload) =>
      fromJson(payload);

  /// 端点校验：步数 ≤ 50、总时长上限 30 分钟（delay 合计 ≤ 600s/步）。
  static String? validate(List<RcStep> steps) {
    if (steps.isEmpty) return '指令组为空';
    if (steps.length > 50) return '步骤过多（上限 50）';
    var total = 0.0;
    for (final s in steps) {
      if (s.kind == RcStepKind.delay) {
        final sec = (s.params['seconds'] as num?)?.toDouble() ?? 0;
        if (sec < 0.5 || sec > 600) return '时延超出范围（0.5–600 秒/步）';
        total += sec;
      }
    }
    if (total > 30 * 60) return '时延合计超过 30 分钟上限';
    return null;
  }

  static RcScript fromJsonString(String s) =>
      fromJson((jsonDecode(s) as Map).cast<String, dynamic>());
}
