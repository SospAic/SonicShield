import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../domain/scheduling/run_pause.dart';

/// 「全局执行总开关」（FR-71）的**跨写入方单一真源代理**（第八十二轮）。
///
/// ## 为什么需要它
/// 真源仍是 `SharedPreferences(PrefsKeys.runMasterMode)`，但它有**三个写入方**：
/// ① 首页常驻开关卡片；② 设置页总开关；③ 远程 `run.master.set` 处理器。
/// 此前三方各写各的 prefs，而首页只在 `initState` 读一次 ⇒ **远程改了，
/// 首页不刷新** —— 这正是"总开关支持远程控制"缺的最后一公里。
///
/// 本店把「写 prefs **+** 广播新值」绑成一个动作（[set]），三方都走它，
/// 任何监听方（[ValueListenableBuilder]）即时更新 ⇒ 远程与本机改动**互相可见**。
/// 与 `BackgroundServiceManager.instance` 同款：进程内单例，UI 侧只读消费。
class RunMasterService {
  RunMasterService._();

  /// 进程内单例（与端点服务 / 引擎管理器同生命周期）。
  static final RunMasterService instance = RunMasterService._();

  /// 当前模式（内存镜像）。UI 用 [ValueListenableBuilder] 消费。
  final ValueNotifier<RunMasterMode> mode = ValueNotifier(RunMasterMode.auto);

  /// 从 prefs 播种当前值（UI 进入时调用）。
  ///
  /// 刻意**每次真读 prefs**（不做内存缓存短接）：测试用
  /// `SharedPreferences.setMockInitialValues` 控制真源，每次都得到确定值，
  /// 从而避开"单例内存态跨用例污染"（本仓既有教训，见 `docs/12 §99`）。
  Future<RunMasterMode> seed() async {
    final p = await SharedPreferences.getInstance();
    final m = RunMasterMode.parse(p.getString(PrefsKeys.runMasterMode));
    mode.value = m;
    return m;
  }

  /// 写 prefs + 广播新值。**所有**写入方（本机 UI / 远程处理器）都必须走这里，
  /// 否则监听方收不到变更 —— 那正是本轮要修的那条断裂。
  ///
  /// `ValueNotifier` 对**同值**不重复通知，故重复写入同一模式不会造成多余重建。
  Future<void> set(RunMasterMode m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(PrefsKeys.runMasterMode, m.name);
    mode.value = m;
  }
}
