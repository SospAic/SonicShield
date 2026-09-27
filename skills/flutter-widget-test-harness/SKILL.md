# 技能：flutter-widget-test-harness（宿主 widget 测试）

> 权威记录分散在 docs/17 §46②（四类）→ §48⑥（六类）→ §49⑤（七类）→ §50⑤（八类）
> → §72.4 / docs/12 §75.4（第 41 轮）。
> 本文件是**汇总版**，供下一会话直接引用；若有出入，以 docs/17 最新节为准。
> 第 21–25 轮实测沉淀；每一条都有"报错形态 → 根因 → 修法"的实证。
> 附录 A（第 25 轮）→ B（第 26 轮）→ C（第 38 轮）→ D（第 39 轮）→ E（第 40 轮）→ F（第 41 轮）。

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

## 附录 C · 页面"结构上不可达"时：加 `@visibleForTesting` 注入缝（第 38 轮沉淀）

> 出处：`docs/12 §72` / `docs/17 §69`。样板：`test/multi_video_screen_test.dart`（15 例）。
> 场景：屏幕**整块 UI 只在某个服务状态非空时才构建**，而宿主机造不出那个状态
> ⇒ 未覆盖不是"难测"，是"**结构上到不了**"。

### C.1 先判"同源性"，再决定打哪个文件

缺口降序看 TOP 时**不要直接挑最大的**：

| 判据 | 结论 |
|---|---|
| 缺口**全落在同一个 `if` / 早返回分支之后**（同源） | 一个缝解锁一大块 ⇒ **优先** |
| 缺口**散在多条独立平台路径**上（异源） | 要逐条啃 ⇒ **拆成多轮**，每轮只打一条 |

★ 序列化经验：**同源的 100 行 < 异源的 500 行**。

### C.2 加缝五步检查清单（缺一项就可能翻车）

1. **只加方法，不改既有签名/行为** —— 既有两个方法一个字都不动。
2. 确认本项目把 `invalid_use_of_visible_for_testing_member` 设为 **error**
   （`analysis_options.yaml`）⇒ 生产误用即门禁第 1 步红。
3. **逐条 grep `test/` 里读该文件源码文本的锁**，确认新方法**不落在被切的函数体切片里**
   （这些锁通常只切某个函数体 ⇒ 加在文件尾部不会误判）。
4. 缝要能自清，但**绝不关 `StreamController`** —— 关了同进程后续用例全部假绿。
   用"清空状态 + 复位"而不是"dispose"。
5. **缝自身的可执行行会抬分母**（如可测面 `LF` 9562 → 9576，+14）。
   **如实计入**；此时 `MIN_COVERED`（分子绝对地板）才是真正的防线。
   **绝不许**把新代码塞进豁免名单来美化比率。

### C.3 三个新假故障（第 38 轮实测，与八类不重复）

| # | 报错形态 | 根因 | 修法 |
|---|---|---|---|
| 9 | `Found 0 widgets with text "未选择设备"`，但那块 UI 明明"应该在于是禁用" | 页面在 `isEmpty` 时**早返回**，那整块控件**根本没构建** —— "不可用"有两种形态（`onPressed == null` **禁用** vs **不构建**） | 断言对准**真实的那一种**；"禁用"分支若确实存在，用注入缝单独打一例，并在注释里标注它**仅经缝可达** |
| 10 | 点遮罩关 `showDialog` 后断言 `findsNothing` 假红"对话框还在" | `SimpleDialog` 会在树上停留**到转场动画结束**（实测只 `pump` 60ms 不够） | `pump()` + `pump(500ms)` 再断言 |
| 11 | 门禁第 1 步红：`prefer_conditional_assignment` | 缝里写 `if (x != null) { y = x; } else if (y == null) { … }` | 改 `y = x ?? y;` 再 `y ??= …;`（语义等价、写法合规） |

### C.4 插件桩的最小集（WebRTC 类页面）

`FlutterWebRTC.Method`（`createVideoRenderer` 必须复刻真实返回形状 `{'textureId': 1}`，
否则拿到 `null` 会抛 `NoSuchMethodError`）、`FlutterWebRTC/Texture1`、
`FlutterWebRTC.Event`（**必须桩**：未桩时 `onListen` 的 `MissingPluginException`
被 `FlutterError.reportError` 上报 ⇒ 直接判用例失败）。
其余方法（`getUserMedia` / `createPeerConnection`）**故意返回 `null`** ——
宿主机本来就该失败，正好断言"失败时必须可诊断、不留半开会话"。
权限走 `test/support/permission_stub.dart`；**不桩任何声盾生产逻辑**。

## 附录 D · 「同源红利耗尽」之后的选目标法与三个新假故障（第 39 轮沉淀）

> 出处：`docs/12 §73` / `docs/17 §70`。样板：`test/quick_scripts_card_test.dart`（6 例，新建）、
> `test/device_list_screen_test.dart` DLSW-12…21（10 例，扩充）。

### D.1 换判据的触发条件（先量，别猜）

先跑 `python _pt/covhomoscan.py 10`（全库扫描「单个连续未覆盖块 ≥ N 行」）：

| 观测 | 含义 | 下一步 |
|---|---|---|
| 有 `≥ 20~30 行`的连续块 | **同源红利仍在** | 按附录 C.1 的「同源性」判据选目标 |
| **最大块 < 15 行**（本项目第 39 轮实测：`≥20` 行块**命中 0 个**，最大仅 **12 行**） | **同源红利已耗尽** | 换判据 ⇒ 见 D.2 |

### D.2 换用的判据：**「无专属测试文件」× 「缺口比 MISS/LF」**

不要再看缺口**绝对数**（TOP 的 `endpoint_service` 528 = **246 块 / 块均 2.1 行**，
是典型**异源碎片**；`pair_qr_screen` 112 = 52 块，同型）。改看这两条：

1. `test/<basename>_test.dart` **是否存在** —— 不存在 ⇒ "不是难测，是**从没被看过**"；
2. **MISS / LF 比值**（越高越值得，例：`30 / 46 = 65%`）。

★ 第 39 轮正是这样捞出 `quick_scripts_card.dart`（46 行里 30 行未覆盖、
**全项目唯一"无专属测试文件 + 能被首页直接渲染"的写路径**，`_send()` 真会往别人设备发命令）。

★ **反向判据（同样重要）**：「有专属测试文件」**不等于**"这块被测过" ——
`device_list_test.dart` 把三个**纯函数**测得很扎实，但**"设备组"整块 91 行从没被 pump**。
⇒ 看文件时**对齐"测试文件覆盖的是哪一层（纯函数 / widget）"**，而不是"有没有测试文件"。

### D.3 三个新假故障 / 新坑（第 39 轮实测，与八类 + C.3 不重复）

| # | 形态 | 根因 | 修法 |
|---|---|---|---|
| 12 | `Expected: exactly one matching candidate / Actual: Found 2 widgets with text containing 客厅手机` —— 断言"对话框里点名了失败设备"却红了 | `find.textContaining` **跨整棵树**匹配，同一字符串也出现在**设备卡片标题**上 | **断言必须收窄到它真正想约束的容器**：`find.descendant(of: find.byType(AlertDialog), matching: …)`。先问"我想约束的是哪个容器" |
| 13 | 中继跑了 6~12 分钟产物**零新增字节**，被误判成"挂死" | `timeout … \| tr '\r' '\n' \| tail -40` 里 `tr` 与 `tail` **都全缓冲**（非 tty 时全缓冲） | 单跑/观测类命令改 **`> _pt/xxx_raw.txt 2>&1` 直写文件**（逐条用例秒级可见）；`tr` 只留给"整段门禁输出"这类一次性场合 |
| 14 | 产物文件**在**（1042 B）、`.done` **不在**、任务 `State=Ready` ⇒ 无法判断状态 | 这是**第三种状态「作业异常终止」**：既非挂死（进程已退、有产物）、也非跑完（无 `.done`） | 判据**只能是「产物 + `.done` 成对」**；缺一个就当异常终止，**用直写文件的单跑复核上一次的中间结论**，不要凭猜继续 |

### D.4 零生产改动的性价比（本轮最强的一条）

同源红利耗尽后，**"补一个从没被 pump 过的整块"优于"加 `@visibleForTesting` 注入缝"**：

| 路线 | 生产代码 | 分母 | 第 39 轮实测 |
|---|---|---|---|
| 加注入缝（附录 C） | +N 行 | **变大**（比率被稀释） | 第 38 轮：+14 行分母 |
| 补「有测试但整块没驱动」的文件 | **0 行** | **不动** | 第 39 轮：**+115 行分子 / 分母一成不变** |

⇒ 选目标时**先扫一遍"哪些文件的分支从没进过 widget 层"**（D.2 的两条判据），
再考虑加缝。**能在不动生产代码的前提下拿下的，就先拿。**

## 附录 E · 第 40 轮沉淀：判据再细化 + 两条"只在门禁里暴露"的纪律

### E.1 判据再细化：「有专属测试文件」≠「这条业务路径被执行过」

D.2 的判据只到"有没有专属测试文件"。第 40 轮证明**还要再问一句**：

| 现象 | 实测 | 结论 |
|---|---|---|
| `native_bridge_test.dart` **39 例全绿** | 却**从没调用过** `vibrateCommand` —— v1.9 振动**唯一**下发口 | 契约层被锁住 ≠ 业务路径被跑过 |
| `db_repository_test.dart` 把仓储层锁得很扎实 | 却**从没造过一个旧版库** ⇒ `_onUpgrade` 的 `ALTER TABLE` 零验证 | 所有用例都从 `:memory:` 起步 |

⇒ **选靶时按"文件里哪些整块分支从没被任何用例驱动"逐块点，而不是按文件缺口数排序。**
第 41 轮（附录 F.1）把这句话推到"某块分支是否被**任何路径**驱动过"。

### E.2 `flutter analyze` 对测试文件是「打地鼠两连击」

| 轮次 | 报错 | 修法 |
|---|---|---|
| 第 1 次 | `prefer_const_constructors`：`MyWidget(...)` 可以 const | 加 `const` |
| 第 2 次 | **同三处立刻换成** `prefer_const_declarations`：`final x = const C()` 要写成 `const x = C()` | 再去掉 `final` |

⚠️ 两次之间**单跑测试都是全绿**，**只在门禁第 1 步暴露**
⇒ **写完测试必须单独跑一次 `flutter analyze`**，别指望功能层会替你发现。

### E.3 变异测试三条纪律（"改坏 → 跑 → 按字节还原 → md5 比对"）

| # | 纪律 | 不遵守的后果 |
|---|---|---|
| ① | **还原锚点必须带唯一标记**（改坏值写成 `xxx; // MUTx`），并用 `assert s.count(old) == 1` 兜住 | "改坏后的值"可能与文件里**本来就存在**的同形语句撞车（第 40 轮 MUT_B 差点撞上同函数上方 11 行的 `_resultWarn = false;`）⇒ **还原到错的行**，把生产代码留在改动状态 |
| ② | **必须 `open(p, 'rb')` / `open(p, 'wb')`** | Windows 文本模式把 `\n` 翻成 `\r\n` ⇒ md5 比对**必然假红** |
| ③ | 跑完**独立比对 BEFORE/AFTER 两个 md5** | 分不清"还原成功"与"压根没改过" |

## 附录 F · 第 41 轮沉淀：`record` 单例的「一次性 Future + zone 绑定」与"未打桩通道永久挂起"

### F.1 新假故障 15：**插件单例的 `_createFuture` 跨用例/跨 zone 永不恢复**

**症状极具误导性**：断言报"**找不到某段文本**"或"**没有 stop 调用**"，
看起来像 UI 缺陷 / 生产代码没释放资源，**根因却在十几行之前的一次单例构造**。

| 事实 | 出处（可复核） |
|---|---|
| `RcControllerService` 是**进程内单例**，`final AudioRecorder _rec = AudioRecorder()` | `lib/remote/controller_service.dart:78` |
| `AudioRecorder()` **构造即**发起一次 `create()` | `record-7.1.1/lib/src/record.dart:32-41` |
| `_createFuture` 是 **`late final`**（**一次性**） | 同文件 `:25` |
| `_safeCall` 每次调用都先 `await _createFuture` | 同文件 `:216-224` |
| `_platform` 是 **getter**（每次现取 `RecordPlatform.instance`） | 同文件 `:29` |

⇒ **问题不在"假实例被换新"**（getter 每次现取），而在**这个 Future 属于哪个 zone**：
`setUp` 里预热 ⇒ 它属于**真实 zone**；用例内 fake-async `await` 它 ⇒
完成回调被调度回真实 zone ⇒ **用例内永不恢复**。

**探针判据**（照抄这个思路，30 行内就能定性）：

```
单用例内通道桩                 → CALLS=[create, hasPermission, stop]   ✅ 桩没问题
跨用例复用同一单例             → DONE=false ERR=null CALLS=[]           ❌ 永久挂起（且不抛错）
```

**修法三件套**

1. **平台层假实现**：`RecordPlatform.instance` 是**公开可写静态字段**、**无 token 校验**
   （`record/record.dart` 重导出 `record_platform_interface`）⇒ 这是插件架构本身给的扩展点，
   把 `create()` 变成**纯 microtask**（无平台消息往返）。
   样板：`test/support/record_stub.dart` 第二层 `FakeRecordPlatform`。
2. `setUp`（**真实 zone**）里预热一次（例：`await RcControllerService.instance.pttCancel();`），
   让 `_createFuture` 在用例开始前真正完成。
3. **凡触碰该插件的交互，整条手势 + 真实计时器都放进 `tester.runAsync`。**

**子事实（Flutter 手势源码）**

| 结论 | 出处 |
|---|---|
| 100ms `didExceedDeadline` 是 **`Timer`** ⇒ 必须在**真实 zone**里下按才拿得到真实计时器；`pump(150ms)` 推的是 fake 时钟，**推不动它** | `packages/flutter/lib/src/gestures/tap.dart:308-311` |
| `onTapCancel` **只在** `_sentTapDown == true` 时触发；取消时 arena 未 sweep ⇒ 没有"补发 down"的机会 ⇒ **那 100ms 计时器是唯一通路** | 同文件 `:315-319` |
| 快速 tap 不同：`acceptGesture` 会补发 down + up | 同文件 `:347-354` |

**代价（务必照做）**：用 `tester.tap` 驱动这类插件时的用例会**挂死**
（`timeout 300` 才被杀，**其后同文件全部用例 `did not complete`**）
⇒ **每条触碰插件的用例都显式写 `timeout: const Timeout(Duration(seconds: 90))`**，
否则一次挂死吃掉整轮预算。

### F.2 新假故障 16：**没打过桩的通道 ⇒ `await` 永久挂起（不是抛错）**

| 项 | 内容 |
|---|---|
| 根因 | `TestDefaultBinaryMessenger.send` 对**没打过桩**的通道会落回 `delegate.send`（`flutter_test/lib/src/test_default_binary_messenger.dart:140-150`）⇒ 宿主无引擎 ⇒ `ui.PlatformDispatcher.sendPlatformMessage` 的回调**永不触发** |
| 实测 | `permission_flow.showKeepAliveGuide` → `_detectVendor` 读 `DeviceInfoPlugin().androidInfo`（通道 `dev.fluttercommunity.plus/device_info`）⇒ `await` 永久挂起 ⇒ 底部弹窗永不出现 |
| 症状 | `Found 0 widgets with text containing 后台保活设置`（**和"断言写错"长得一模一样**） |
| 判据 | **凡 `await` 一个"看起来该立刻返回"的插件调用却什么都没发生，先查通道有没有打桩** |
| 修法 | 显式打桩并**抛 `MissingPluginException`** —— 这正是生产代码 `on Object` 兜底存在的理由（桌面 / 机型识别失败走的就是它） |

### F.3 新坑：**Dart 覆盖率只收录"被编译过的行"** ⇒ 驱动旧死代码会同时抬高分子与分母

第 41 轮实测：**分母 +8 行**（可测面 9576 → 9584 / 全局 10066 → 10074），
来源是 `remote_screen.dart` 的 **LF 323 → 331** ——
此前**从未被 pump** 的 `_PttSheet` 分支行**根本不在报告里**（**既不计分母也不计分子**），
驱动起来之后它们**才进入分母**。

⇒ 这是**如实计入**，**不是**豁免口径变动。汇报时必须**主动披露分母变动并给出实测来源**，
否则"比率上升"里混着"分母刚被喂饱"的成分，看起来像成绩其实不是。

### F.4 新纪律：**每轮另存 `coverage/lcov.info`**

`_pt/lcov_<轮次>.info`（例：`_pt/lcov_round41.info`）。
第 40 轮的 lcov 被同路径**覆盖写掉** ⇒ 第 41 轮无法把某文件 `±1 行` 钉到具体行号，
只能靠"两次独立全量 + 一次单文件"三个样本做定性判断。
配套新工具：**`_pt/lcovdiff2.py <A> <B> [目标文件]`** —— 两份 lcov 的**逐行 DA 计数对比**。
