import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_data.dart' as typed;

/// **MQTT 客户端替身**（第四十八轮）。
///
/// ## 为什么需要它
///
/// `lib/remote/endpoint_service.dart` 的传输层（`_connect` / `_send` /
/// `flushOutbox` / `refreshSubscriptions` / 订阅接口）要求的运行前提是
/// 「有一个 `MqttClient` 且 `connectionStatus.state == connected`」。
/// 宿主机连不上 broker ⇒ 这一整桶（约 128 行）此前**一行都没被执行过**，
/// 只有源码文本锁兜底。第四十四轮立的判据第五代说得直白：
/// **「源码锁是绿的」 ≠ 「那条业务路径被执行过」**。
///
/// ## 为什么可以做成替身（而不是"宿主物理不可达"）
///
/// `mqtt_client 10.11.11` 的 `MqttClient` 是**纯 Dart 类**，
/// **不是平台通道**（对比 `flutter_webrtc` / `just_audio` 那两轮）。
/// 它只在真正 `connect()` 时才去开 `SecureSocket` —— 而 `connect` 与方法
/// `publishMessage` / `subscribe` / `unsubscribe` / `disconnect` 以及
/// getter `connectionStatus` / `updates` **全是普通虚方法**，可以在子类里覆写。
/// 覆写之后跑的是**生产代码本身**，不是它的复制品。
///
/// ## 与 `just_audio_stub.dart` / `webrtc_stub.dart` 的分工
///
/// 那两份是"静态可写单例"型（`XxxPlatform.instance`），必须在 `tearDown`
/// 还原原实例，否则污染同进程其它测试文件。本替身是**实例注入**型
/// （由 `RcEndpointService.debugClientFactory` 返回），
/// 注入点本身就是 `@visibleForTesting`，**生产恒为 null** ⇒ 不需要全局还原。
///
/// ## 诚实边界
///
/// 本替身**不做任何业务判断**，只复刻"平台侧返回形状"：
/// 它不会替生产代码决定该不该发、该不该订。凡是本替身能观测到的
/// （`published` / `subscribed`），都是生产代码自己调出来的。
/// 反过来：它**证明不了**真实 broker 上的 QoS / 重连 / TLS 行为 ——
/// 那些仍然只在真机上可验证（`docs/12` 诚实边界）。
class FakeMqttServerClient extends MqttServerClient {
  /// [broker] / [clientId] 原样透传（替身不解析，只记录由基类保存）。
  FakeMqttServerClient(super.broker, super.clientId);

  final MqttClientConnectionStatus _status = MqttClientConnectionStatus();

  /// 每一条被 `publishMessage` 真正交出去的报文（按调用顺序）。
  ///
  /// ⚠️ 名字**不能**叫 `published` —— `MqttClient` 自己就有
  /// `Stream<MqttPublishMessage>? get published`（发布完成事件流）。
  /// 同名会变成"覆写继承 getter 且类型不兼容"（第 48 轮实测：12 条 analyze 报错）。
  /// 这类"替身成员名撞上插件成员名"的坑与 `Helper.switchCamera` 那次同族。
  final sentWires = <FakeMqttPublish>[];

  /// 每一次 `subscribe` 的主题（按调用顺序，**允许重复**：重订阅是合法行为）。
  final subscribed = <String>[];

  /// 每一次 `unsubscribe` 的主题。
  final unsubscribed = <String>[];

  /// `connect()` 的调用次数（`_scheduleReconnect` 的 10s 定时器是否真的重连）。
  int connectCalls = 0;

  /// `disconnect()` 的调用次数。
  int disconnectCalls = 0;

  /// `true` ⇒ `connect()` 抛错（模拟 broker 不可达 / TLS 握手失败）。
  bool failConnect = false;

  /// `true` ⇒ `connect()` 正常返回，但状态停在 `disconnected`
  /// （模拟"TCP 连上了、broker 拒绝会话"这一类失败）。
  bool stayDisconnected = false;

  final _updates =
      StreamController<List<MqttReceivedMessage<MqttMessage>>>.broadcast();

  @override
  MqttClientConnectionStatus? get connectionStatus => _status;

  @override
  Stream<List<MqttReceivedMessage<MqttMessage>>>? get updates =>
      _updates.stream;

  @override
  Future<MqttClientConnectionStatus?> connect([
    String? username,
    String? password,
  ]) async {
    connectCalls++;
    if (failConnect) {
      throw Exception('FakeMqttServerClient: broker unreachable');
    }
    _status.state = stayDisconnected
        ? MqttConnectionState.disconnected
        : MqttConnectionState.connected;
    return _status;
  }

  @override
  void disconnect() {
    disconnectCalls++;
    _status.state = MqttConnectionState.disconnected;
  }

  @override
  int publishMessage(
    String topic,
    MqttQos qualityOfService,
    typed.Uint8Buffer data, {
    bool retain = false,
  }) {
    sentWires.add(FakeMqttPublish(
      topic: topic,
      wire: utf8.decode(data.toList(), allowMalformed: true),
      qos: qualityOfService,
      retain: retain,
    ));
    return sentWires.length;
  }

  @override
  Subscription? subscribe(String topic, MqttQos qosLevel) {
    subscribed.add(topic);
    return null;
  }

  @override
  void unsubscribe(String topic, {expectAcknowledge = false}) {
    unsubscribed.add(topic);
  }

  /// 往 `updates` 流推一条入站报文 —— 等价于 broker 投递到
  /// `client.updates` 监听器的那一刻（**这正是 `_handleRaw` 的唯一生产入口**）。
  Future<void> emit(String topic, String text) async {
    final b = MqttClientPayloadBuilder()..addString(text);
    final m = MqttPublishMessage()..payload.message = b.payload!;
    _updates.add([MqttReceivedMessage<MqttMessage>(topic, m)]);
    await Future<void>.delayed(Duration.zero);
  }

  /// 一次投递里携带**多条**报文（生产侧 `updates` 的类型就是 `List<...>`）。
  ///
  /// 为什么需要它：`client.updates` 的事件类型是
  /// `List<MqttReceivedMessage<MqttMessage>>`，监听器体内是一个 `for` 循环。
  /// 只发"每事件一条"的话，那个循环的"多条"语义**永远不会被执行** ——
  /// 这正是本替身必须照真实返回形状写、而不能图省事变简单的原因。
  Future<void> emitBatch(List<(String topic, String text)> batch) async {
    final msgs = <MqttReceivedMessage<MqttMessage>>[];
    for (final (topic, text) in batch) {
      final b = MqttClientPayloadBuilder()..addString(text);
      final m = MqttPublishMessage()..payload.message = b.payload!;
      msgs.add(MqttReceivedMessage<MqttMessage>(topic, m));
    }
    _updates.add(msgs);
    await Future<void>.delayed(Duration.zero);
  }

  /// 释放内部 `StreamController`（生产代码**永不**调用）。
  ///
  /// ⚠️ 与 47 轮记忆里那条纪律一致：注入缝/替身**绝不替生产代码关流** ——
  /// 这里只在 `tearDown` 被显式调用，是测试自己的资源回收，不是生产语义。
  Future<void> dispose() => _updates.close();
}

/// 一条被交出去的 MQTT 发布报文（替身的观测记录）。
class FakeMqttPublish {
  FakeMqttPublish({
    required this.topic,
    required this.wire,
    required this.qos,
    required this.retain,
  });

  final String topic;

  /// 交出去的字节串（生产侧是密文；对本替身而言就是 `addString` 的内容）。
  final String wire;

  final MqttQos qos;
  final bool retain;
}
