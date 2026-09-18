import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'assist_join.dart';
import 'endpoint_service.dart';
import 'protocol.dart';
import 'remote_store.dart';

/// 控制台的**命令通道**抽象。
///
/// 远程控制台（`RemoteConsoleTab`）原本直接依赖 `PairedEndpoint` +
/// `RcEndpointService.sendTo`，于是只能驱动"已配对端点"。协助会话（S3）的
/// 对端**没有配对关系**，命令走会合主题 + 会话密钥 —— 若把控制台复制一份
/// 适配，就会出现两套命令面板，功能必然漂移（新增命令只加一边）。
///
/// 因此把"怎么发、回执从哪来"抽出来，控制台只面对本接口：
///
/// | 实现 | 目标 | 加密密钥 | 回执来源 |
/// |---|---|---|---|
/// | [PairedChannel] | 已配对端点 | 对端配对码派生 | `{对端ID}/evt` |
/// | [AssistChannel] | 协助会话端点 | 临时码+密码派生 | 会合主题 |
abstract interface class RcCommandChannel {
  /// 展示名（目标端点名）。
  String get label;

  /// 回执/事件流，信封形状与 [RcEndpointService.events] 一致。
  Stream<Map<String, dynamic>> get events;

  /// 通道**可用性/权限**变更流（不携带业务数据，仅用于触发重建）。
  ///
  /// 为什么需要它：控制台按通道权限灰化按钮，但权限是**对端随时可变**的
  /// （协助会话里端点可随时放行/收回）。若只在收到业务事件时重建，
  /// 端点单独变更权限时按钮的灰化状态会一直停留在旧值 ——
  /// 表现为"端点明明放行了，按钮却还是灰的"，或更糟的反向情况。
  Stream<void> get updates;

  /// 是否可发命令（配对通道：端点在线；协助通道：会话已激活）。
  bool get canSend;

  /// 发送命令；返回是否**已发出**（不代表被执行 —— 端点侧仍有权限门控）。
  Future<bool> send(RcMessage msg);

  /// 释放资源（协助通道会退订会合主题）。
  Future<void> dispose();
}

/// 已配对端点通道：包一层现有实现，行为与改造前完全一致。
class PairedChannel implements RcCommandChannel {
  PairedChannel(this.endpoint, this._store);

  final PairedEndpoint endpoint;
  final RemoteStore _store;

  @override
  String get label => endpoint.name;

  @override
  Stream<Map<String, dynamic>> get events => RcEndpointService.instance.events;

  /// 配对通道无权限位模型（配对即全权），故无"权限变更"可推。
  /// 端点在/离线由端点服务自身的生命周期驱动，页面重建时重新求值即可。
  @override
  Stream<void> get updates => const Stream<void>.empty();

  @override
  bool get canSend => RcEndpointService.instance.isRunning;

  @override
  Future<bool> send(RcMessage msg) =>
      RcEndpointService.instance.sendTo(endpoint, msg, _store);

  @override
  Future<void> dispose() async {}
}

/// 协助会话通道：命令经会合主题与会话密钥收发。
class AssistChannel implements RcCommandChannel {
  AssistChannel(this.client);

  final AssistJoinClient client;

  @override
  String get label =>
      client.epName.isEmpty ? '协助会话端点' : '${client.epName}（协助）';

  @override
  Stream<Map<String, dynamic>> get events => client.events;

  /// 端点放行/收回权限时推送 —— 控制台据此刷新按钮灰化状态。
  @override
  Stream<void> get updates => client.changes.map<void>((_) {});

  @override
  bool get canSend => client.active;

  @override
  Future<bool> send(RcMessage msg) async {
    // 未授权命令**仍然发出**：裁决权在端点侧，本端只做 UI 灰化提示。
    // 若在此静默拦截，使用者会以为"功能坏了"而看不到端点的拒绝原因。
    return client.send(msg);
  }

  @override
  Future<void> dispose() async {}
}

/// 便捷构造：读取配对表得到 [PairedChannel]。
Future<PairedChannel?> pairedChannelOf(String deviceId) async {
  final store = RemoteStore(await SharedPreferences.getInstance());
  for (final e in store.paired()) {
    if (e.deviceId == deviceId) return PairedChannel(e, store);
  }
  return null;
}

/// 该命令在当前通道下是否**预计**可执行（仅用于 UI 灰化）。
bool channelAllows(RcCommandChannel channel, String cmd) {
  if (channel is AssistChannel) return channel.client.allows(cmd);
  return true; // 配对通道无权限位模型（配对即全权）
}
