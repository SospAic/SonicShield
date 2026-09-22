import 'dart:convert';

import '../domain/models/action.dart';
import '../domain/models/condition.dart';
import '../domain/models/task.dart';
import '../domain/models/trigger.dart';

/// 远程任务线格式（docs/14 §2.1，协议 v1.7）。
///
/// 与 `Task.toRow()` 同构，但更适合 JSON 传输：
/// - `trigger` / `action` 用**嵌套对象**（而非 JSON 字符串）
/// - `enabled` 用 **bool**（而非 0/1）
/// - `assetIds` 用数组；`condition` 用嵌套对象
///
/// 领域模型不承担传输职责，转换集中在本文件。
///
/// ## 安全：入站数据视为不可信
///
/// [TaskWire.fromWire] 用于解析**对端发来的**任务定义，必须做白名单校验：
/// 枚举必须可解析、数值必须夹紧到合理区间、集合大小有上限。
/// 校验失败返回 null，端点应回 `rc.ack ok=false`，
/// 避免畸形定义写入 DB 后拖垮调度器（docs/14 §2.1 安全注记）。
abstract final class TaskWire {
  TaskWire._();

  /// 冷却上限：24 小时（与调度语义一致）。
  static const maxCooldownSec = 86400;

  /// 优先级绝对值上限。
  static const maxPriorityAbs = 100;

  /// 单任务音源池上限。
  static const maxAssetIds = 64;

  static const maxNameLen = 120;

  /// 单次播放/声景时长上限（秒）。
  static const maxDurationSec = 3600;

  /// 声景轨道数上限（与 `SoundscapeAction` 语义一致）。
  static const maxSoundscapeTracks = 4;

  /// 文本类字段上限（TTS 文案 / 通知标题正文）。
  static const maxTextLen = 500;

  /// 录音取证时长上限（秒）。
  static const maxRecordSec = 1800;

  /// 震动模式步数上限（与 Android Vibrator 模式串长度上限同量级）。
  static const maxVibrateSteps = VibrateLimits.maxPatternSteps;

  // ---- v1.9 振动传输层夹紧（docs/20 §10.3）----
  //
  // ⚠️ 这几个常量**不是产品护栏**，与 D1「持续振动本地不设时长硬上限」不矛盾：
  // 它们是**入站数据不可信**这条安全边界上的取值上界 —— 对端可以发任何数字，
  // 而 `ActionConfig` 的区间约束只由 `assert` 表达，release 会被剥离。
  // 没有它们，一条 `durationSecMax: 999999999` 会让分片续发表直接爆掉。
  // 本机任务走 `task_editor_screen` 的表单约束，**不经过**这些常量，
  // 因此"本地不设上限"与"远程必须夹紧"可以同时成立。
  // 数值与 `VibrateLimits` 同源（`vibrate_wire_lock_test` 断言二者不得分叉）。
  static const maxVibrateDurationSec = VibrateLimits.maxDurationSec;
  static const maxVibrateJitterMs = VibrateLimits.maxJitterMs;
  static const maxPulseCount = VibrateLimits.maxPulses;

  /// 动作集候选数上限（与 `ActionSetAction` 的 assert 同源）。
  static const maxActionSetCandidates = 12;

  /// 候选权重上限：`ActionSetAction.pick` 对权重只要求 ≥0，无穷大的权重
  /// 会让 `fold` 溢出成 `Infinity`，随后 `roll` 恒为 NaN —— 选中逻辑静默失效。
  static const maxActionSetWeight = 1e6;

  /// **入站振动一律遵循系统勿扰**（v1.9，docs/20 §10.3 第 4 条）。
  ///
  /// `respectDnd=false` 会让原生侧改用 `USAGE_ALARM`，即**穿透系统勿扰**。
  /// 允许已配对的对端打开它，等于让对端绕过本机的合规护栏 —— 与 `quietExempt`
  /// （docs/20 §8.2 约束 1）是同一类问题，直接触碰项目红线（docs/08 §2）。
  /// 本机任务仍可由用户自己关闭（编辑器有显式警告），**远程路径不提供这个能力**。
  ///
  /// ⚠️ 写成常量而不是"删掉键走默认"，是为了让"有人想接上它"必须**主动改常量名**。
  static const bool inboundRespectDnd = true;

  /// 入站动作定义是否**试图**关闭勿扰遵循（供端点写审计，不静默）。
  ///
  /// 与 [inboundRespectDnd] 配套：夹紧发生在 `fromWire` 内部，端点拿不到"被夹了"
  /// 这个信号；这里用同一个判定给出，端点据此写一条审计日志。
  /// 两个函数共享 `_wantsNoDnd`，避免"夹紧规则改了、审计规则没改"的分叉。
  static bool inboundDndDowngrade(Object? rawAction) {
    final m = _asMap(rawAction);
    if (m == null) return false;
    var hit = false;
    void probe(Object? v) {
      final n = _asMap(v);
      if (n == null) return;
      if (_wantsNoDnd(n['respectDnd'])) hit = true;
      final inner = _asMap(n['primary']);
      if (inner != null) probe(inner);
    }

    probe(m);
    return hit;
  }

  /// 只有**显式**的 `false` 才算"想关掉勿扰遵循"；缺失/畸形一律不算
  /// （后者在夹紧后同样是 `true`，不构成下放）。
  static bool _wantsNoDnd(Object? v) => v == false;

  // ---------------- 出站 ----------------

  static Map<String, dynamic> toWire(Task t) => {
        'id': t.id,
        'name': t.name,
        'enabled': t.enabled,
        'triggerType': t.triggerType.name,
        'trigger': t.trigger.toJson(),
        'actionType': t.actionType.name,
        'action': t.action.toJson(),
        'assetIds': t.assetIds,
        'cooldownSec': t.cooldownSec,
        'quietPolicy': t.quietPolicy.name,
        // 夜间独立豁免（v1.9）：**出站携带，入站无视**（见 [fromWire] 的注记）。
        // 出站带上是为了让对端界面能显示"该任务在端点侧夜间不受约束"（透明性），
        // 但不代表对端有权设置它。
        'quietExempt': t.quietExempt,
        'priority': t.priority,
        if (t.condition != null) 'condition': t.condition!.toJson(),
        'createdAt': t.createdAt.millisecondsSinceEpoch,
        'updatedAt': t.updatedAt.millisecondsSinceEpoch,
      };

  // ---------------- 入站（不可信，必须校验） ----------------

  /// 解析并校验线格式任务。不合法返回 null。
  static Task? fromWire(Map<String, dynamic> j) {
    try {
      final id = (j['id'] as String?)?.trim() ?? '';
      if (id.isEmpty) return null;

      final rawName = (j['name'] as String?)?.trim() ?? '';
      if (rawName.isEmpty) return null;
      final name = rawName.length > maxNameLen
          ? rawName.substring(0, maxNameLen)
          : rawName;

      final triggerType =
          _enumByName(TriggerType.values, j['triggerType'] as String?);
      final actionType =
          _enumByName(ActionType.values, j['actionType'] as String?);
      if (triggerType == null || actionType == null) return null;

      final triggerMap = _asMap(j['trigger']);
      final actionMap = _asMap(j['action']);
      if (triggerMap == null || actionMap == null) return null;

      // 夹紧必须发生在**原始 JSON 层**：ActionConfig/TriggerConfig 的区间
      // 约束由 assert 表达，assert 在构造期就抛出，构造后再归一化为时已晚。
      final sanitizedAction = _sanitizeActionMap(actionMap);
      if (sanitizedAction == null) return null;

      final trigger = TriggerConfig.fromJson(_clampTimeSpecs(triggerMap));
      final action = ActionConfig.fromJson(sanitizedAction);

      final quiet =
          _enumByName(QuietPolicy.values, j['quietPolicy'] as String?) ??
              QuietPolicy.skip;

      final cooldown = _clampInt(j['cooldownSec'], 0, maxCooldownSec, 300);
      final priority =
          _clampInt(j['priority'], -maxPriorityAbs, maxPriorityAbs, 0);

      final assetIds = _stringList(j['assetIds'], maxAssetIds);

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      return Task(
        id: id,
        name: name,
        enabled: _asBool(j['enabled']),
        triggerType: triggerType,
        trigger: trigger,
        actionType: actionType,
        action: action,
        assetIds: assetIds,
        cooldownSec: cooldown,
        quietPolicy: quiet,
        // ⚠️ **入站一律 false，绝不读 `j['quietExempt']`**（v1.9，docs/20 §8.2 约束 1）。
        //
        // 夜间豁免是"允许任务绕过 22:00–07:00 免打扰护栏"的授权。
        // 若允许已配对的对端通过 `task.upsert` 打开它，等于**让对端绕过本机的合规护栏** ——
        // 直接触碰项目红线（"未授权控制他人设备"，见 docs/08 §2）。
        // 因此这里**显式**写 false，而不是"省略该参数"：
        // 显式写法让"有人把它接上"这件事必须**主动删掉一行**才能做到，
        // 且 `test/quiet_exempt_lock_test.dart` 会同时断言
        // 「出站含该键」与「入站忽略该键」这一非对称契约。
        //
        // 副作用（**安全方向，已接受**）：对端更新任务会清掉该任务在本机的豁免。
        // 端点侧会为此写一条审计（见 `endpoint_service._upsertTask`），不静默。
        quietExempt: false,
        condition: _condition(j['condition']),
        priority: priority,
        createdAt: _epoch(j['createdAt']) ??
            DateTime.fromMillisecondsSinceEpoch(nowMs),
        // 入站更新一律刷新 updatedAt，避免对端伪造时间线。
        updatedAt: DateTime.fromMillisecondsSinceEpoch(nowMs),
      );
    } on Object {
      return null;
    }
  }

  // ---------------- 内部工具 ----------------

  /// 动作参数夹紧。
  ///
  /// `ActionConfig.fromJson` 的区间约束靠 `assert` 表达，而 **release 构建
  /// 会剥离 assert** —— 对端发来 `volumeMin:0.9, volumeMax:0.2` 时不会抛错，
  /// 会写出一个自相矛盾的动作，调度器物化期取值即崩。此处显式归一化：
  /// 越界夹紧、上下界互换、时长上限收敛。
  /// 动作 JSON 夹紧（构造前）。
  ///
  /// 返回 null = 该动作**结构上不可接受**（拒绝整条任务）。
  ///
  /// 为什么必须在构造前夹紧：`PlayAudioAction` 的
  /// `assert(volumeMin <= volumeMax)`、`SoundscapeAction` 的
  /// `assert(tracks.length in 1..4)` 都在**构造期**求值 —— debug 下先抛错、
  /// release 下被剥离。构造后归一化在 debug 永远走不到，在 release 又是
  /// 唯一防线，两条路径行为不一致。统一在原始 JSON 层夹紧即消除分歧。
  static Map<String, dynamic>? _sanitizeActionMap(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'play':
        final m = Map<String, dynamic>.from(j);
        final (vLo, vHi) =
            _rangeD(m['volumeMin'], m['volumeMax'], 0, 1, 0.6, 1);
        m['volumeMin'] = vLo;
        m['volumeMax'] = vHi;
        final (dLo, dHi) = _rangeI(
            m['durationSecMin'], m['durationSecMax'], 1, maxDurationSec, 3, 15);
        m['durationSecMin'] = dLo;
        m['durationSecMax'] = dHi;
        m['fadeInSec'] = _clampInt(m['fadeInSec'], 0, 600, 0);
        m['fadeOutSec'] = _clampInt(m['fadeOutSec'], 0, 600, 0);
        m['rampUpSec'] = _clampInt(m['rampUpSec'], 0, 3600, 0);
        return m;
      case 'tts':
        final m = Map<String, dynamic>.from(j);
        m['text'] = _clip(j['text'] as String? ?? '', maxTextLen);
        m['volume'] = _clampD(j['volume'], 0, 1, 0.8);
        return m;
      case 'notify':
        final m = Map<String, dynamic>.from(j);
        m['title'] = _clip(j['title'] as String? ?? '声盾', maxTextLen);
        m['body'] = _clip(j['body'] as String? ?? '', maxTextLen);
        return m;
      case 'record':
        return Map<String, dynamic>.from(j)
          ..['seconds'] = _clampInt(j['seconds'], 1, maxRecordSec, 60);
      case 'vibrate':
        final raw = j['patternMs'];
        // 缺省即用领域模型默认模式（不是错误）；显式给出则必须合法。
        if (raw == null) return Map<String, dynamic>.from(j);
        if (raw is! List || raw.isEmpty || raw.length > maxVibrateSteps) {
          return null;
        }
        return Map<String, dynamic>.from(j)
          ..['patternMs'] = [
            for (final e in raw)
              if (e is num) e.toInt().clamp(0, VibrateLimits.maxPatternStepMs)
          ];
      case 'randomVibrate':
        // ⚠️ **不补这个分支的后果**（docs/20 §10.3）：落进 `default:` → 原样透传
        // → release 下 assert 被剥离 → 自相矛盾配置（`amplitudeMin > amplitudeMax`）
        // 写入 DB → 物化期崩。这是本文件开头已经写明的教训，新 kind 必须遵守。
        final m = Map<String, dynamic>.from(j);
        final (dLo, dHi) = _rangeI(m['durationSecMin'], m['durationSecMax'], 1,
            maxVibrateDurationSec, 3, 10);
        m['durationSecMin'] = dLo;
        m['durationSecMax'] = dHi;
        final (onLo, onHi) = _rangeI(m['pulseOnMsMin'], m['pulseOnMsMax'],
            VibrateLimits.minPulseOnMs, VibrateLimits.maxPulseOnMs, 150, 400);
        m['pulseOnMsMin'] = onLo;
        m['pulseOnMsMax'] = onHi;
        final (offLo, offHi) = _rangeI(
            m['pulseOffMsMin'], m['pulseOffMsMax'], 0, VibrateLimits.maxPulseOffMs, 100, 600);
        m['pulseOffMsMin'] = offLo;
        m['pulseOffMsMax'] = offHi;
        final (aLo, aHi) =
            _rangeD(m['amplitudeMin'], m['amplitudeMax'], 0, 1, 0.4, 1);
        m['amplitudeMin'] = aLo;
        m['amplitudeMax'] = aHi;
        m['maxPulses'] = _clampInt(m['maxPulses'], 1, maxPulseCount, 200);
        m['rampUpSec'] =
            _clampInt(m['rampUpSec'], 0, VibrateLimits.maxRampSec, 0);
        m['respectDnd'] = inboundRespectDnd;
        return m;
      case 'continuousVibrate':
        final m = Map<String, dynamic>.from(j);
        final (dLo, dHi) = _rangeI(m['durationSecMin'], m['durationSecMax'], 1,
            maxVibrateDurationSec, 10, 30);
        m['durationSecMin'] = dLo;
        m['durationSecMax'] = dHi;
        final (aLo, aHi) =
            _rangeD(m['amplitudeMin'], m['amplitudeMax'], 0, 1, 0.5, 1);
        m['amplitudeMin'] = aLo;
        m['amplitudeMax'] = aHi;
        m['jitterMs'] = _clampInt(m['jitterMs'], 0, maxVibrateJitterMs, 0);
        final (sLo, sHi) =
            _rangeD(m['sharpnessMin'], m['sharpnessMax'], 0, 1, 0, 0);
        m['sharpnessMin'] = sLo;
        m['sharpnessMax'] = sHi;
        m['dutyCyclePct'] = _clampInt(m['dutyCyclePct'], 10, 100, 100);
        m['rampUpSec'] =
            _clampInt(m['rampUpSec'], 0, VibrateLimits.maxRampSec, 0);
        m['rampDownSec'] =
            _clampInt(m['rampDownSec'], 0, VibrateLimits.maxRampSec, 0);
        m['respectDnd'] = inboundRespectDnd;
        return m;
      case 'composite':
        final primary = _asMap(j['primary']);
        if (primary == null) return null;
        final sp = _sanitizeActionMap(primary);
        if (sp == null) return null;
        final m = Map<String, dynamic>.from(j)..['primary'] = sp;
        final pn = _asMap(j['prefixNotify']);
        if (pn != null) {
          m['prefixNotify'] = _sanitizeActionMap(pn) ??
              {'kind': 'notify', 'title': '声盾', 'body': ''};
        }
        return m;
      case 'randomFrom':
        // BUG-072：动作集此前**没有分支也不递归** —— 落进 `default:` 原样透传。
        // 后果不是"少夹紧一层"，而是**校验被整体绕过**：对端把未夹紧的
        // `continuousVibrate`（`amplitudeMin: 5`）塞进
        // `candidates[0].action`，`_sanitizeActionMap` 根本不会走到它，
        // release 下 assert 被剥离 → 自相矛盾动作写入 DB → 物化期崩。
        // 凡是**能嵌套动作**的 kind，都必须在这里递归下去。
        final raw = j['candidates'];
        if (raw is! List ||
            raw.length < 2 ||
            raw.length > maxActionSetCandidates) {
          return null;
        }
        final cleaned = <Map<String, dynamic>>[];
        for (final c in raw) {
          final cm = _asMap(c);
          if (cm == null) return null;
          final inner = _asMap(cm['action']);
          if (inner == null) return null;
          final si = _sanitizeActionMap(inner);
          if (si == null) return null;
          cleaned.add(cm
            ..['action'] = si
            ..['weight'] =
                _clampD(cm['weight'], 0, maxActionSetWeight, 1.0));
        }
        return Map<String, dynamic>.from(j)..['candidates'] = cleaned;
      case 'soundscape':
        final tracks = j['tracks'];
        if (tracks is! List ||
            tracks.isEmpty ||
            tracks.length > maxSoundscapeTracks) {
          return null;
        }
        final cleaned = <Map<String, dynamic>>[];
        for (final t in tracks) {
          final tm = _asMap(t);
          if (tm == null) return null;
          if (tm['presetCategory'] == null && tm['assetId'] == null) {
            return null;
          }
          cleaned.add(tm..['volume'] = _clampD(tm['volume'], 0, 1, 0.6));
        }
        return Map<String, dynamic>.from(j)
          ..['tracks'] = cleaned
          ..['durationSec'] = _clampInt(j['durationSec'], 1, maxDurationSec, 60)
          ..['fadeOutSec'] = _clampInt(j['fadeOutSec'], 0, 60, 5);
      default:
        // 未知 kind 交由 ActionConfig.fromJson 抛错 → 上层捕获后拒绝。
        return Map<String, dynamic>.from(j);
    }
  }

  /// 递归夹紧任意层级的 `{hour, minute}`（TimeSpec）字段。
  ///
  /// `TimeSpec` 用 assert 约束 0..23 / 0..59；对端一个 `hour: 25` 会让整条
  /// 任务被拒。夹紧比拒绝更合适：触发器语义仍然明确。
  static Map<String, dynamic> _clampTimeSpecs(Map<String, dynamic> j) {
    final out = <String, dynamic>{};
    j.forEach((k, v) {
      if (v is Map) {
        final m = v.map((a, b) => MapEntry('$a', b));
        if (m['hour'] is num) {
          m['hour'] = (m['hour'] as num).toInt().clamp(0, 23);
        }
        if (m['minute'] is num) {
          m['minute'] = (m['minute'] as num).toInt().clamp(0, 59);
        }
        out[k] = _clampTimeSpecs(m);
      } else if (v is List) {
        out[k] = [
          for (final e in v)
            e is Map ? _clampTimeSpecs(e.map((a, b) => MapEntry('$a', b))) : e
        ];
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  static (double, double) _rangeD(
      Object? lo, Object? hi, double min, double max, double dLo, double dHi) {
    var a = _clampD(lo, min, max, dLo);
    var b = _clampD(hi, min, max, dHi);
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    return (a, b);
  }

  static (int, int) _rangeI(
      Object? lo, Object? hi, int min, int max, int dLo, int dHi) {
    var a = _clampInt(lo, min, max, dLo);
    var b = _clampInt(hi, min, max, dHi);
    if (a > b) {
      final t = a;
      a = b;
      b = t;
    }
    return (a, b);
  }

  static double _clampD(Object? v, double min, double max, double fallback) {
    if (v is! num) return fallback;
    return v.toDouble().clamp(min, max).toDouble();
  }

  static String _clip(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;

  static T? _enumByName<T extends Enum>(List<T> values, String? name) {
    if (name == null) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry('$k', val));
    }
    // 兼容对端直接发 JSON 字符串（与 DB 列同构）
    if (v is String && v.isNotEmpty) {
      try {
        final d = jsonDecode(v);
        if (d is Map) return d.map((k, val) => MapEntry('$k', val));
      } on Object {
        return null;
      }
    }
    return null;
  }

  /// 宽容布尔解析：线格式约定 bool，但 `0/1` 也接受（避免为一个
  /// 非安全相关的字段整条任务被拒）。
  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return false;
  }

  static int _clampInt(Object? v, int min, int max, int fallback) {
    if (v is! num) return fallback;
    final i = v.toInt();
    if (i < min) return min;
    if (i > max) return max;
    return i;
  }

  static List<String> _stringList(Object? v, int cap) {
    if (v is! List) return const [];
    final out = <String>[];
    for (final e in v) {
      if (e is String && e.isNotEmpty) out.add(e);
      if (out.length >= cap) break;
    }
    return out;
  }

  static DateTime? _epoch(Object? v) {
    if (v is! num) return null;
    final ms = v.toInt();
    // 合理范围：2000-01-01 ~ 2100-01-01，超出视为非法
    if (ms < 946684800000 || ms > 4102444800000) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static TaskCondition? _condition(Object? v) {
    final m = _asMap(v);
    if (m == null) return null;
    // 复用既有解析（入参为 JSON 字符串），并夹紧数值范围。
    final parsed = TaskCondition.fromJsonOrNull(jsonEncode(m));
    if (parsed == null) return null;
    return TaskCondition(
      requireCharging: parsed.requireCharging,
      minBatteryPct: parsed.minBatteryPct?.clamp(0, 100),
      windowStartMin: parsed.windowStartMin?.clamp(0, 1439),
      windowEndMin: parsed.windowEndMin?.clamp(0, 1439),
      windowEndNextDay: parsed.windowEndNextDay,
      // v1.7：白名单式透传 —— 未列出的键一律丢弃（入站数据视为不可信）。
      requireWifi: parsed.requireWifi,
      skipInCall: parsed.skipInCall,
    );
  }
}
