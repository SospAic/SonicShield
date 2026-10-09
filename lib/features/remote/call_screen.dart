import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';
import '../../remote/call_lifecycle.dart';
import '../../remote/call_permission.dart';
import '../../remote/call_service.dart';
import '../../remote/remote_store.dart';

/// 视频通话页：选择配对端点发起呼叫（视频/语音）+ 自动接通开关。
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, this.preselectEndpointId});

  final String? preselectEndpointId;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  bool _autoAnswer = false;
  List<PairedEndpoint> _endpoints = const [];
  String? _selected;

  /// 本机当前的通话阶段（主叫的"连接中"界面靠它驱动，BUG-D）。
  CallPhase _phase = CallService.instance.currentPhase;

  /// 对端 `rc.call` 状态镜像（"对方振铃中…"，BUG-050）。
  RemoteCallState _remote = CallService.instance.remoteState;

  /// 挂断要用（`hangUp` 需要 store 才能发 `call.end`）。
  RemoteStore? _store;

  StreamSubscription<CallPhase>? _phaseSub;
  StreamSubscription<RemoteCallState>? _remoteSub;

  @override
  void initState() {
    super.initState();
    _load();
    // 来电界面不再从这里挂载 —— 它由 `CallOverlayHost`（挂在 `MaterialApp.builder`）
    // 常驻监听 `CallService.phase` 自动弹出，与当前在哪个路由无关（BUG-056）。
    //
    // 但**主叫**的"连接中"阶段仍需要一个界面：`CallOverlayHost` 只覆盖
    // ringing/connected，而主叫的阶段是 connecting（BUG-D）。
    _phaseSub = CallService.instance.phase.listen((p) {
      if (mounted) setState(() => _phase = p);
    });
    _remoteSub = CallService.instance.remoteStateChanges.listen((s) {
      if (mounted) setState(() => _remote = s);
    });
  }

  @override
  void dispose() {
    _phaseSub?.cancel();
    _remoteSub?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    if (!mounted) return;
    setState(() {
      _endpoints = store.paired();
      _autoAnswer = store.paired().isNotEmpty ? _autoAnswer : _autoAnswer;
      _selected = widget.preselectEndpointId ??
          (_endpoints.isEmpty ? null : _endpoints.first.deviceId);
    });
    _autoAnswer = await CallService.autoAnswerEnabled();
    if (mounted) setState(() {});
  }

  Future<void> _toggleAuto(bool v) async {
    final scaffold = ScaffoldMessenger.of(context);
    // 关掉开关不需要权限，直接关。
    if (!v) {
      await CallService.setAutoAnswer(false);
      if (mounted) setState(() => _autoAnswer = false);
      return;
    }
    // ⚠️ BUG-062：此前 `await [camera, microphone].request();` 的**结果被丢弃**，
    // 权限被拒也照样把开关打开 —— 用户看到"已开启"，实际来电根本接不起来。
    final status = await [Permission.camera, Permission.microphone].request();
    final block = autoAnswerBlockFor(
      micGranted: status[Permission.microphone]?.isGranted ?? false,
      cameraGranted: status[Permission.camera]?.isGranted ?? false,
    );
    if (block != AutoAnswerBlock.none) {
      if (mounted) {
        scaffold
            .showSnackBar(SnackBar(content: Text(autoAnswerBlockText(block))));
        setState(() => _autoAnswer = false);
      }
      return;
    }
    await CallService.setAutoAnswer(true);
    if (mounted) setState(() => _autoAnswer = true);
  }

  Future<void> _call(bool video) async {
    final ep = _endpoints.where((e) => e.deviceId == _selected).firstOrNull;
    if (ep == null) {
      // ⚠️ 静默 return 会让用户以为"按钮坏了"（BUG-D 的观感就是这个）。
      _toast('请先选择一个端点');
      return;
    }
    // ⚠️ 权限必须在**发起之前**问：等 `getUserMedia` 失败再报错，用户看到的是
    // 一句"呼叫失败"，根本不知道是权限问题（BUG-062 同形状：失败必须可诊断）。
    // 语音呼叫只要麦克风 —— 不许因为"相机被拒"把能用的语音呼叫拦下来。
    final status = await [
      Permission.microphone,
      if (video) Permission.camera,
    ].request();
    final blocked = callStartBlockFor(
      micGranted: status[Permission.microphone]?.isGranted ?? false,
      cameraGranted: status[Permission.camera]?.isGranted ?? false,
      video: video,
    );
    if (blocked != null) {
      _toast(callStartBlockText(blocked));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final store = RemoteStore(prefs);
    _store = store;
    CallService.bindStore(
        () async => RemoteStore((await SharedPreferences.getInstance())));
    final callId =
        await CallService.instance.startCall(ep, store, video: video);
    if (!mounted) return;
    if (callId == null) {
      // ⚠️ 不许再用"权限或端点离线"这种一锅端文案 —— 它把四种下一步动作
      // 完全不同的原因压成一句不可执行的话（BUG-D）。
      final why = CallService.instance.lastStartBlock;
      _toast(why == null ? '呼叫失败' : callStartBlockText(why));
      return;
    }
    // ⚠️ 这里**不再** `Navigator.pushNamed('/remote/call/in-call')`。
    // go_router 的 Navigator 用 `pages:` 构建、**没有** `onGenerateRoute`，
    // 而 `/remote/call/in-call` 这个路由**从未声明过**（router.dart 只有
    // `/remote/call`）⇒ pushNamed 当场抛异常（debug 是断言、release 是
    // 空值检查），用户看到的就是"点了按钮什么都没发生"（BUG-D）。
    //
    // 主叫的连接中界面改为在本页渲染（见 build → `_ConnectingView`），
    // 接通后由常驻的 `CallOverlayHost` 接管全屏画面。
  }

  /// 挂断（主叫在"连接中/振铃"阶段取消呼叫）。
  Future<void> _hangUp() async {
    final store = _store ??
        RemoteStore(await SharedPreferences.getInstance());
    await CallService.instance.hangUp(store);
  }

  @override
  Widget build(BuildContext context) {
    // 主叫发出 invite 后处于 connecting —— 这一阶段**必须看得见**（BUG-D）。
    // 修之前：`CallOverlayHost` 只覆盖 ringing/connected，而那个"进通话页"
    // 的路由又不存在 ⇒ 主叫点下按钮后界面毫无变化（无提示、无挂断入口）。
    if (_phase == CallPhase.connecting) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _ConnectingView(remote: _remote, onHangUp: _hangUp),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('视频通话')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Card(
            child: SwitchListTile(
              secondary: Icon(_autoAnswer ? Icons.videocam : Icons.videocam_off,
                  size: 30),
              title: Text(_autoAnswer ? '自动接通已开启' : '自动接通已关闭',
                  style: Theme.of(context).textTheme.titleMedium),
              subtitle: const Text('仅限已配对设备呼入时自动接通（家人守护场景）。'
                  '接通后屏幕可见、系统摄像头指示灯正常工作，不提供隐蔽模式。'),
              value: _autoAnswer,
              onChanged: _toggleAuto,
            ),
          ),
          const SizedBox(height: 12),
          Text('呼叫端点', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (_endpoints.isEmpty)
            const Card(
                child: Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Text('尚未配对端点。请先在「远程遥控」页完成配对。'))),
          RadioGroup<String>(
            groupValue: _selected,
            onChanged: (v) => setState(() => _selected = v),
            child: Column(
              children: [
                for (final e in _endpoints)
                  RadioListTile<String>(
                    value: e.deviceId,
                    title: Text(e.name),
                    subtitle: Text(e.deviceId),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.videocam),
                  label: const Text('视频呼叫'),
                  onPressed: _selected == null ? null : () => _call(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.call),
                  label: const Text('语音呼叫'),
                  onPressed: _selected == null ? null : () => _call(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Card(
            color: AppColors.dangerWash,
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                '⚠️ 合规提示：自动接通用于家人守护（老人/儿童看护）与本人设备间协作。'
                '在他人不知情时开启其摄像头属于侵犯隐私的违法行为，本应用不提供'
                '任何隐蔽接通方式——接通即亮屏、系统指示灯正常工作。',
                style: AppText.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主叫「连接中」界面（BUG-D）。
///
/// ## 为什么必须由本页承担
///
/// 通话界面分两处：常驻的 `CallOverlayHost`（挂在 `MaterialApp.builder`，
/// 覆盖 **ringing / connected**）与本页。主叫的阶段是
/// `connecting → connected`，而 ringing 只属于**被叫** —— 于是
/// `CallOverlayHost` 在主叫最需要反馈的那段时间里什么都不显示。
/// 修之前 `_call` 又把"进通话页"的希望寄托在一个**不存在的路由**上，
/// 两者叠加的结果就是"点下按钮，什么都没发生"。
///
/// 文案取自纯逻辑 [connectingText]（`ringing` → "对方振铃中…"），
/// 让使用者能区分"对方在响"与"信令根本没送到"——这两者的下一步动作
/// 完全不同（一个继续等，一个去查网络）。
class _ConnectingView extends StatelessWidget {
  const _ConnectingView({required this.remote, required this.onHangUp});

  final RemoteCallState remote;
  final Future<void> Function() onHangUp;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const Spacer(),
          const CircleAvatar(radius: 44, child: Icon(Icons.videocam, size: 40)),
          const SizedBox(height: 16),
          Text(
            connectingText(remote),
            style: AppText.titleMedium.copyWith(color: Colors.white),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: FloatingActionButton.large(
              heroTag: 'caller-hangup',
              backgroundColor: AppColors.danger,
              // P2-31：补语义标签（原来只有图标，读屏无法播报"挂断"）。
              tooltip: '挂断',
              // 挂断入口是**必须**的：没有它，用户在这 45s 里无法取消呼叫。
              onPressed: () => onHangUp(),
              child: const Icon(Icons.call_end, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
