# 技能：flutter-widget-test-harness（宿主 widget 测试）

> 权威记录分散在 docs/17 §46②（四类）→ §48⑥（六类）→ §49⑤（七类）→ §50⑤（八类）。
> 本文件是**汇总版**，供下一会话直接引用；若有出入，以 docs/17 最新节为准。
> 第 21–25 轮实测沉淀；每一条都有"报错形态 → 根因 → 修法"的实证。

## 触发条件

给 `lib/features/**` 的屏幕/组件写宿主（非设备）widget 测试，或宿主测试
**挂死 / 报错毫不相似 / 时红时绿 / 全绿但没测到**时，先读本文件再动手。
可抄样板：`test/router_test.dart`、`test/task_list_screen_test.dart`、
`test/log_stats_screen_test.dart`（含 provider 错误注入）。

## 八类假故障（报错毫不相似，根因同源：`testWidgets` 跑在 `FakeAsync` 里）

| # | 报错形态 | 根因 | 修法 |
|---|---|---|---|
| 1 | 测试**永久挂死**（实测卡满 6–10 分钟） | 用例体里 `await` **真实 isolate 往返**（开库、以及 **DB 读写**——后者曾推翻旧结论） | 开库放 `setUp`；读写用 `dbRead`/`dbWrite` 包 `tester.runAsync` |
| 2 | `uri` 对但屏幕还是旧页（整页路由仍带底部导航） | `router.go()` 发生在**首帧之后** | `go()` 放 `pumpWidget()` **之前**。第 2 类最阴：断言 uri 的测试会**全绿** |
| 3 | `A Timer is still pending`（栈：sqflite `BasicLock`，10s） | 锁超时 Timer 在 fake async 里不取消 | `runAsync` 让真实事件循环转几圈 |
| 4 | `A Timer is still pending`（栈：Riverpod `_defaultVsync`，0s） | `autoDispose` 用 `Timer(Duration.zero)` 调度，`pump()` 不传时长不 elapse | 卸载后 `pump(Duration.zero)` |
| 5 | 时红时绿（invalidate 后断言偶错） | **固定轮数 drain 等异步重读**：`AsyncValue` 先带旧值渲染 | `waitFor(cond)` 有界轮询 + 超时**显式 `fail`**（静默放行让负向断言恒真） |
| 6 | 断言错但值"看起来对" | **按 widget 下标取值**：依赖 `ORDER BY` 平局的未定义顺序 | 按关系定位（`find.ancestor`/`find.descendant`）；夹具给确定的时间戳 |
| 7 | `takeException()` 返回 null **但测试仍红**（错误带 `(but after the test had completed)`） | `onPressed` 返回的 Future **无人 await** → 走 zone `onError`、绕过 `FlutterError.onError` | 判据落在"用户能看到什么"（提示文案 / 未落库），别落在 `takeException()` |
| 8 | `fling`/`drag` 无论幅度速度都**触发不了 `RefreshIndicator`** | 手势竞技场要 `pumpAndSettle` 走完入场动画才完成识别（纪律禁止拿它当"等数据"） | `tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show()` 直接触发——**测的是接线本身**，手势交给框架。取证结论：测量问题，非生产缺陷 |

## harness 模板要点（`test/log_stats_screen_test.dart` 是完整样例）

1. 开库放 `setUp`（fake async 之外）；`sqfliteFfiInit()` + `databaseFactoryFfi`。
2. 用例体里的 DB 读写必须 `tester.runAsync`（陷阱 1）。
3. 等 UI 一律 `waitFor/waitForText`（陷阱 5），**不 `pumpAndSettle`**
   （加载态是无限动画；`StatefulShellRoute.indexedStack` 下 Dashboard 的
   `Timer.periodic` 拖住一切 pump —— 全程只用 `pump(Duration)`）。
4. 收尾推掉 SnackBar 计时（默认 4s），否则 `A Timer is still pending`。
5. **每例有上限**：用文件级注解（一行覆盖全文件）——
   `perTest` 包装会"未使用"告警（`testWidgets` 有自己的 timeout 参数）。
   ⚠️ 注解附着 `library` 指令，而 `library;` **必须先于所有 import**
   （`library_directive_not_first`）→ **注解 + `library;` 放文件最顶部**：
   ```dart
   @Timeout(Duration(seconds: 90))
   library;

   import 'package:flutter_test/flutter_test.dart';
   ```
6. 夹具直接写 SQL 指定 `created_at`（`LogRepository.append` 用 `DateTime.now()`，
   同毫秒平局使 `ORDER BY ... DESC` 顺序未定义 —— 陷阱 6 的根源）。

## 附录 A · 驱动 Material 大对话框（docs/17 §49⑤）

| 坑 | 修法 |
|---|---|
| 文案硬编码找不到（`find.textContaining('06:05')`） | 界面是 `TimeOfDay.format(ctx)`；宿主无 delegates → **en_US `6:05 AM`**。**问框架要**：`t.format(tester.element(find.byType(TheScreen)))` |
| 全屏选择器日期格点不到（`Offset(…, 6107)` 超 6000 视口） | 该用例**单独调小视口** + `ensureVisible`；格点取 `.first` |
| 拨盘不好拖 | 先点 `Icons.keyboard_outlined` 切**输入模式**再 `enterText` |
| 只断言"对话框关了" | **必须让值真的变**（先点两个日期格再 Save，断言文案 ≠ 原值），否则 `onChanged` 没接上也能绿 |
| `pumpWidget` 重入**不重置路由栈** | 同一用例循环 pump 会撞上上次 push 的页面；要么换用例要么先 `pop` |

## 附录 B · 给"会调插件"的页面打桩（docs/17 §48⑥，按优先级）

1. 官方注入点（`FilePicker.platform = fake`；仅限直接依赖，否则
   `depend_on_referenced_packages` 红）。
2. **打桩方法通道**（标准编解码器，不引入 import）——`path_provider`/`share_plus`
   在 `flutter test` 里走方法通道；⚠️ 方法名是 `getTemporaryDirectory`
   （≠ Dart 接口的 `getTemporaryPath`），**不能靠推理，要实测**。
3. 夹具用同步 I/O 造（`createTempSync`/`writeAsStringSync`，不受 FakeAsync 影响）。

**provider 错误分支一条 override 喂多页**（docs/17 §50⑦）：
`logRepoProvider.overrideWith((ref) => throw StateError(...))` —— 所有 watch
它 `.future` 的 provider/FutureBuilder 同时进错误态，一次锁住全部 error 分支。

## 证伪纪律

- **锁必须能失败**：每个复发锁做**变异验证**（还原 bug → 该锁红；修复 → 绿）。
- **变异逐个注入**，一次注多个会互相干扰、无法归因（docs/17 §46④ M 系列）。
- **只测一个方向的变异 = 没测**（RTR-02e 教训）。
- 重写测试文件后**必须重新量覆盖率**（第二十四轮删掉 3 条旧用例丢了覆盖，
  是覆盖率数字发现的，不是人眼）。
