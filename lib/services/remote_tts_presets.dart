import 'package:shared_preferences/shared_preferences.dart';

/// 远程 TTS 喊话的 **5 个预置位**（内容可自定义，落 `SharedPreferences`）。
///
/// ## 为什么固定 5 个
/// 控制端在「语音播报」步骤里常用同一批话术（"请把音量调小""该休息了"…）。
/// 与其每次手打，不如给 5 个**可自定义**的预置位：点一下即填入文本。
/// 数量固定为 [slotCount] 让 UI 布局稳定、也让"自定义"对话框恒有 5 行输入。
///
/// ## 纯逻辑 / 平台层分离
/// [normalize] 是**纯函数**（去空白、截断超长、缺则补默认、多则截断），
/// 宿主测试能穷举；[read]/[write] 只是它的 `SharedPreferences` 薄封装。
/// 所有越界输入（脏数据、超长、条数不符）都被收敛到"恰好 5 条合法文案"。
abstract final class RemoteTtsPresets {
  /// 持久化键（带版本后缀，便于将来换结构并存解析）。
  static const String prefsKey = 'remote_tts_presets_v1';

  /// 预置位数量（固定 5 个）。
  static const int slotCount = 5;

  /// 单条文案长度上限（与 `CounterPlan.maxTtsTextLen` 同源量级）。
  static const int maxLen = 200;

  /// 出厂 5 条（用户可改）。
  static const List<String> defaults = <String>[
    '请注意，声盾远程指令',
    '请把音量调小一点',
    '该休息了，别熬夜',
    '有情况，请查看设备',
    '收到请回复',
  ];

  /// 把任意输入规整成**恰好 [slotCount] 条**合法文案。
  ///
  /// - 去首尾空白、丢弃空串；
  /// - 超长（>[maxLen]）截断；
  /// - 不足则按 [defaults] 循环补齐（保证 UI 恒有 5 个可点项）；
  /// - 多于 [slotCount] 则截断。
  static List<String> normalize(List<String> raw) {
    final out = <String>[];
    for (final r in raw) {
      final t = r.trim();
      if (t.isEmpty) continue;
      out.add(t.length > maxLen ? t.substring(0, maxLen) : t);
    }
    for (var i = 0; out.length < slotCount; i++) {
      out.add(defaults[i % defaults.length]);
    }
    return out.take(slotCount).toList();
  }

  /// 读取（缺 / 坏 / 条数不符 → 一律规整为 5 条）。
  static List<String> read(SharedPreferences prefs) =>
      normalize(prefs.getStringList(prefsKey) ?? const <String>[]);

  /// 写入（先规整再落库；返回是否写成功）。
  static Future<bool> write(SharedPreferences prefs, List<String> raw) =>
      prefs.setStringList(prefsKey, normalize(raw));
}
