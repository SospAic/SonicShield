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
