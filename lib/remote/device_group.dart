import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'remote_store.dart';

/// 设备组（Q6.B）：把若干已配对端点编成一个具名集合，供「我的设备」页
/// 一键群发命令（当前只发 Ping）。与 [RemoteStore] 的配对表**分离存储**：
/// 配对表是授权真源（删配对即撤权），组只是**展示/触达的快捷方式**，
/// 组里存的 deviceId 可能随时失效 —— 所以群发前必须经
/// [resolveGroupTargets] 对当前配对表重新核对，绝不直接信任组内名单。
class DeviceGroup {
  const DeviceGroup({
    required this.id,
    required this.name,
    required this.memberIds,
  });

  final String id;
  final String name;

  /// 组内端点的 deviceId 列表。**允许含失效/重复项**——清洗交给
  /// [resolveGroupTargets]（判定），存储层不擅自删数据。
  final List<String> memberIds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'memberIds': memberIds,
      };

  static DeviceGroup fromJson(Map<String, dynamic> j) => DeviceGroup(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '未命名设备组',
        memberIds: ((j['memberIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 组名的**判定**（项目铁律：判定与接线分离）。
///
/// 返回空串 = 合法；非空 = 给用户看的错误文案。
/// 空白（全空格）同样视为空 —— 建一个看不见名字的组是纯坑。
/// 上限 20 字：组名只是快捷标签，长得像设备列表的组名只会挤爆卡片。
String validateGroupName(String name) {
  final n = name.trim();
  if (n.isEmpty) return '组名不能为空';
  if (n.length > 20) return '组名过长（最多 20 字）';
  return '';
}

/// 群发目标的**判定**：组内成员 ∩ 当前已配对。
///
/// - **∩ 配对表**：组名单只是收藏，授权真源是配对表；已解配对的成员
///   必须被剔除（对已撤权设备发命令本就该被端点准入拒掉，提前剔除
///   能让「已发 N 台」如实反映触达数）。
/// - **去重**：组内名单理论上有重复（旧数据/手滑），去重避免同一台
///   被连发两条 Ping。
/// - **保序**：按组内名单顺序输出，群发结果与组定义可对照。
List<String> resolveGroupTargets(
    DeviceGroup group, List<PairedEndpoint> paired) {
  final pairedIds = {for (final e in paired) e.deviceId};
  final out = <String>[];
  for (final id in group.memberIds) {
    if (pairedIds.contains(id) && !out.contains(id)) out.add(id);
  }
  return out;
}

/// 设备组的持久化（SharedPreferences，键 `rc:group:<id>`，一组一条 JSON）。
///
/// 与 [RemoteStore] 分开建类而不是塞进它的 extension：组的读写和配对表
/// 生命周期完全不同（配对撤权**不能**牵连组），放一起只会让人误以为相关。
class DeviceGroupStore {
  DeviceGroupStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'rc:group:';

  /// 全部组，按组名字典序（确定序：跨重启稳定，测试可精确断言）。
  List<DeviceGroup> groups() {
    final out = <DeviceGroup>[];
    for (final k in _prefs.getKeys()) {
      if (!k.startsWith(_prefix)) continue;
      final raw = _prefs.getString(k);
      if (raw == null || raw.isEmpty) continue;
      try {
        out.add(DeviceGroup.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } on Object {
        // 单条坏数据（手改存储/版本迁移残片）只跳过该条，不让整页崩。
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  DeviceGroup? byId(String id) {
    if (id.isEmpty) return null;
    for (final g in groups()) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// 同 id 覆盖（与 [RemoteStore.addPaired] 的原位覆盖同款语义）。
  Future<void> save(DeviceGroup g) =>
      _prefs.setString('$_prefix${g.id}', jsonEncode(g.toJson()));

  Future<void> delete(String id) => _prefs.remove('$_prefix$id');

  /// 组 id：微秒时间戳足够本机唯一（组不做跨设备同步）。
  static String newId() => 'g${DateTime.now().microsecondsSinceEpoch}';
}
