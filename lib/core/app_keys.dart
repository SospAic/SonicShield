import 'package:flutter/material.dart';

/// 应用级全局 key。
///
/// 单独成文件是为了**避免 import 环**：`app.dart` 需要在 `MaterialApp` 上装
/// 通话 UI 宿主，而通话 UI 又需要这个 messenger key 来弹提示。
/// 两边都从这里取，就没有 `app.dart ↔ call_incoming_overlay.dart` 的互相 import。

/// 全局 SnackBar 入口。
///
/// 通话结束（未接/被拒/占线…）的提示可能在**任意页面之上**弹出 ——
/// 主叫发起呼叫后即便退到别的页，也必须收得到"对方无应答"（BUG-050）。
/// 用 `ScaffoldMessenger.of(context)` 需要拿得到当时的页面 context，
/// 而通话结束是一个**全局异步事件**，没有"当时的页面"。
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// R94 / QUA-07：`respectDnd` 默认值语义变更（true → false）的**一次性提示**键。
///
/// ## 背景
///
/// R93 把 `RandomVibrateAction` / `ContinuousVibrateAction` 的 `respectDnd`
/// 缺省值从 `?? true` 改成 `?? false`（修复"系统静音/勿扰把振动吞掉、
/// 回执却写 success"的静默失败）。存量任务 JSON 里没有该键 ⇒ 读出来就是
/// false ⇒ 升级后历史振动任务开始**穿透勿扰**。这是用户可感知的行为变更，
/// 不能静默生效（A6 审计 QUA-07）。
///
/// ## 契约（与 F5 的写入方约定）
///
/// - **写入方**：F5（启动链/迁移处）在检测到"默认值已翻转且未提示过"时
///   置 `true`；
/// - **读取方**：设置页（`settings_screen.dart`）读到 true 时展示一次性
///   横幅，用户点「我已知晓」（或任何关闭路径）后立即置回 `false`；
/// - 键名字符串**就是** `dnd_default_changed_notice_pending`（跨 isolate
///   共享的持久化键，抽成常量防拼写漂移 —— 与 `PrefsKeys` 同族的理由）。
const String kDndDefaultChangedNoticePending =
    'dnd_default_changed_notice_pending';
