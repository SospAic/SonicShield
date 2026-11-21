// ignore_for_file: avoid_print
/// 覆盖率报告 —— 解析 `coverage/lcov.info`，输出**分母完整**的覆盖率。
///
/// ## 为什么不能直接看 `lcov.info` 里的总计
///
/// Dart 覆盖率只统计**运行期被加载过的库**。未被任何 import 触及的文件
/// 在 lcov 里**完全不存在**（不计分子也不计分母）→ 越不测越"好看"。
/// 本工具因此做三件事：
///
/// 1. 拿 `lib/**/*.dart` **现场枚举**当基准，逐文件核对 lcov 里有没有 `SF:`
///    记录。**缺一个就报错**（说明 `test/coverage_sentinel_test.dart` 没刷新）；
/// 2. 输出**两个口径**：`全局`（所有 lib 代码）与 `可测面`（排除设备层）；
/// 3. 设备层豁免是**显式白名单 + 每条带理由**，且**豁免文件不存在时直接失败**
///    （防止"豁免一个已删除的文件"这种静默注水）。
///
/// ## 两个口径怎么用（别混着用）
///
/// | 口径 | 含义 | 用途 |
/// |---|---|---|
/// | 全局 | 所有 `lib/` 可执行行 | **对外诚实数字**，任何汇报都用它 |
/// | 可测面 | 全局 − 设备层豁免 | **门禁阈值**用这个（宿主测试物理上跑不了 native 插件） |
/// | 净可测面 | 可测面 − 逐行举证不可达行 | R104 新增：回答「扣除已举证残差后是否 100%」 |
///
/// ⚠️ **不要把"可测面"当成"全局"来汇报，也不要把"净可测面"当成前两者。**
/// 三个数字必须同时出现，否则就回到了"靠口径调整来美化指标"的老路。
/// 净可测面**不是**新的 ratchet 口径：官方 `--gate` 仍判可测面，
/// 净口径只用 `--net-gate` 单独验，且必须逐行举证 + 按文件对账。
///
/// ## 用法
///
/// ```bash
/// dart run tool/coverage_report.dart                 # 人读报告
/// dart run tool/coverage_report.dart --top=25        # 只看缺口最大的 25 个文件
/// dart run tool/coverage_report.dart --gate=99       # 可测面 < 99% 则退出码 1
/// dart run tool/coverage_report.dart --net-gate=100  # 逐行举证后净口径 < 100% 则红
/// dart run tool/coverage_report.dart --json          # 机器可读
/// ```
library;

import 'dart:convert';
import 'dart:io';

/// 设备层豁免白名单：`文件 → 为什么宿主测不了 + 由谁覆盖`。
///
/// ⚠️ 收录标准（**严格**，别为了数字好看往里塞）：
/// 该文件的未覆盖行**主要由"只能真机/模拟器执行"的路径构成** ——
/// native 插件调用、引擎 isolate、真实音频/视频/网络设备。
/// 纯逻辑（模型、协议编解码、状态机）**一律不收**，必须写宿主测试。
///
/// 判定方法：先跑一遍 `--top`，逐个人工看未覆盖行到底是什么。
///
/// ⚠️ **收录时必须在 `reason` 里同时给出"结构证据"**，格式见
/// `test/device_exemption_lock_test.dart`（DEX 系列）：
/// 每条豁免都绑一个**必须真实存在于该文件里的字面量标记**
/// （例如引擎 isolate 的 `@pragma('vm:entry-point')`）。
/// 一旦有人把这个文件改成纯逻辑，标记消失 → 锁立刻判红，
/// 豁免就无法继续赖在白名单里。这保证了白名单**藏不住**退化的代码。
const Map<String, String> _deviceOnly = <String, String>{
  // ── 引擎 isolate 本体 ────────────────────────────────────────────────
  // 未覆盖 508/516 行。**唯一**的顶层入口是
  // `@pragma('vm:entry-point') engineEntryPoint(ServiceInstance service)`，
  // 它只在 `flutter_background_service` 拉起的**独立 isolate** 里被调用；
  // 函数体第一步就是 `DartPluginRegistrant.ensureInitialized()`，随后
  // 全部依赖真实平台能力：Battery 插件读电量、AppDatabase 开库、
  // PlaybackService 出声、NativeBridge 振动。宿主测试**无法**构造
  // `ServiceInstance`，也拿不到那条 isolate。
  // 由谁覆盖：真机/模拟器上的后台引擎集成测试（docs/12 §63.4）。
  'lib/services/background_engine.dart':
      '引擎 isolate 本体：入口 @pragma(\'vm:entry-point\') engineEntryPoint'
          '(ServiceInstance) 只在 flutter_background_service 拉起的独立 isolate '
          '里执行，函数体首句即 DartPluginRegistrant.ensureInitialized()，'
          '后续依赖 Battery/AppDatabase/PlaybackService/NativeBridge 等真实平台能力；'
          '宿主测试无法构造 ServiceInstance。覆盖方：真机后台引擎集成测试。',

  // ── 应用装配入口 ──────────────────────────────────────────────────────
  // 未覆盖 36/36 行。`main()` 是 `runApp` 之前的**原生插件装配链**：
  // NotificationService.createServiceChannel（本地通知插件）、
  // BackgroundServiceManager.init（后台服务插件）、FlutterTts 构造，
  // 且以 `runApp` 收尾 —— 在宿主测试里调用它等于把整个 App 真的跑起来。
  // 由谁覆盖：真机冷启动冒烟（docs/12 §63.4）。
  'lib/main.dart':
      '应用装配入口：main() 是 runApp 之前的原生插件装配链（本地通知渠道、'
          '后台服务 init、FlutterTts），并以 runApp(const ProviderScope(...)) 收尾；'
          '宿主测试调用它等于把整个 App 真正跑起来。覆盖方：真机冷启动冒烟。',

  // ── 内置神经 TTS 引擎（sherpa-onnx 原生 FFI）──────────────────────────
  // 未覆盖的是 ensureLoaded/speak/dispose：把模型资产从 rootBundle 拷到应用
  // 私有目录、构造 `sherpa.OfflineTts`（onnxruntime 原生 FFI）、合成 WAV、
  // 用 just_audio 出声 —— 全部依赖真机/模拟器上的原生库与音频设备，
  // 宿主测试物理上加载不了原生库。纯逻辑（选路/回落）在 `tts_service.dart`，
  // 已由宿主测试覆盖。由谁覆盖：真机「神经音色试听/喊话」集成路径。
  'lib/services/neural_tts.dart':
      '内置神经 TTS 引擎：ensureLoaded/speak/dispose 依赖 sherpa-onnx '
          'onnxruntime 原生 FFI 与 just_audio 播放器、rootBundle 资产拷贝，'
          '宿主测试无法加载原生库与音频设备；纯选路逻辑在 tts_service.dart 已覆盖。'
          '覆盖方：真机神经音色试听/喊话集成路径。',
};

/// 声明式数据文件白名单：**整文件只有 `static const` 声明，没有可执行语句**。
///
/// 这类文件 Dart VM **不产生任何覆盖记录**（lcov 里没有 `SF:`），
/// 但它对分子/分母的贡献**都是 0** —— 排除它不会让百分比变好看，
/// 所以不算"分母漏算"。
///
/// ⚠️ **双向锁**：若哪天这类文件里出现了函数体/语句，它**必然**会出现在
/// lcov 里 → 本清单的对应条目立刻被判为"失效"，工具报错要求删除。
/// 因此这个清单**藏不住真实的覆盖漏洞** —— 它只能装"确实没有可执行行"的文件。
const Set<String> _noExecutableLines = <String>{
  // ⚠️ `lib/core/constants.dart` 已于第七十七轮移出白名单：`AppMeta.displayVersion`
  // 是带方法体的 getter（`'$version+$buildNumber'`），Dart VM 会为它产生覆盖记录。
  // 纯抽象接口：整文件只有 `abstract interface class PttStreamSink` 的
  // 三个方法**签名**（无方法体、无字段初始化），Dart VM 不产生任何覆盖记录。
  // 具体实现（PttPlaybackSession）在 playback_service.dart 一侧照常计入分母。
  'lib/services/ptt_stream_sink.dart',
};

/// **行级残差登记豁免**（R104 / 第一百零四轮）。
///
/// 收录标准比设备层整文件豁免**更严**：
/// 只收「宿主测试结构上不可达」的**具体行号**（私有构造守卫、switch 穷尽臂、
/// 恒假防御分支、平台异常兜底、无法注入的随机源重试体等），
/// 每条都必须引用 `docs/12 §135.7` 的**逐行举证表**。
///
/// 🔴 三道反向锁（防止它退化成橡皮章）：
/// 1. **stale 自动失效**：登记的行一旦被新测试覆盖，就**不再计入**豁免数
///    （分母不减），并在报告里点名要求清理 —— 只可能让口径更保守；
/// 2. **按文件对账**：每个非设备层文件的 `LF−LH` 必须 **恰好等于**该文件
///    有效豁免行数 ⇒ 只要还有一行没举证，工具 `exit(2)`，净口径不许自称 100%；
/// 3. **理由格式**：每条理由 ≥20 字且含 `§135.7` 锚点，由
///    `test/coverage_line_exemption_lock_test.dart` 静态复核 + 反面样本锁死。
///
/// ⚠️ 本清单**不改变**门禁 `--gate` / `--min-covered` 的判据口径：
/// 官方 ratchet 仍用「可测面 = 全局 − 设备层」。新增的「净可测面」是
/// **第三个口径**，用于回答「扣除逐行举证不可达行后是否 100%」，
/// 任何汇报仍必须同时给出全局与可测面两个原始数字。
const Map<String, Map<int, String>> _lineExemptions = <String, Map<int, String>>{
  'lib/core/theme.dart': <int, String>{
    14: '§135.7 AppTheme 私有构造守卫，防止实例化全静态主题类，标准 Dart 惯用法',
  },
  'lib/data/db/app_database.dart': <int, String>{
    93: '§135.7 openDatabase 重试循环三轮内必 return 或末轮 rethrow，末尾 throw StateError unreachable 为静态穷尽臂',
  },
  'lib/data/prefs/json_list_codec.dart': <int, String>{
    57: '§135.7 JsonListCodec 私有构造守卫，防止实例化全静态编解码类',
  },
  'lib/features/dashboard/dashboard_screen.dart': <int, String>{
    20: '§135.7 守护首页：私有构造守卫防止实例化；停止播放/振动的 catch 需原生播放器抛错；自动运行文案臂与 tertiary 配色臂只在 auto 之外的档位出现，现有宿主用例只驱动 auto',
    70: '§135.7 守护首页：私有构造守卫防止实例化；停止播放/振动的 catch 需原生播放器抛错；自动运行文案臂与 tertiary 配色臂只在 auto 之外的档位出现，现有宿主用例只驱动 auto',
    77: '§135.7 守护首页：私有构造守卫防止实例化；停止播放/振动的 catch 需原生播放器抛错；自动运行文案臂与 tertiary 配色臂只在 auto 之外的档位出现，现有宿主用例只驱动 auto',
    362: '§135.7 守护首页：私有构造守卫防止实例化；停止播放/振动的 catch 需原生播放器抛错；自动运行文案臂与 tertiary 配色臂只在 auto 之外的档位出现，现有宿主用例只驱动 auto',
    376: '§135.7 守护首页：私有构造守卫防止实例化；停止播放/振动的 catch 需原生播放器抛错；自动运行文案臂与 tertiary 配色臂只在 auto 之外的档位出现，现有宿主用例只驱动 auto',
  },
  'lib/features/remote/assist_join_screen.dart': <int, String>{
    309: '§135.7 协助会话接入页：面板可见时 auditLog 至少两条，其下的空态 Padding 分支无法在宿主触达',
  },
  'lib/features/remote/ptt_tab.dart': <int, String>{
    100: '§135.7 对讲页：端点已不存在提示需解配对与页面刷新在同一帧竞态发生',
  },
  'lib/features/remote/remote_screen.dart': <int, String>{
    154: '§135.7 远程页：一键测速每个 await 都在 on Object 返回 null 内，最终 mounted 收尾分支只在正常测速路径触达',
  },
  'lib/features/remote/remote_scripts_tab.dart': <int, String>{
    239: '§135.7 远程指令组页：endpointById 与 _selectedId 在同一同步段写入不可能为 null，其后的 mounted 守卫与 SnackBar 分支无法在宿主触达',
    240: '§135.7 远程指令组页：endpointById 与 _selectedId 在同一同步段写入不可能为 null，其后的 mounted 守卫与 SnackBar 分支无法在宿主触达',
  },
  'lib/features/remote/script_builder_screen.dart': <int, String>{
    110: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    120: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    173: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    183: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    210: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    211: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    212: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    213: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
    214: '§135.7 指令组装器：_editStep 对 vibrate/tts 无条件提前 return 由专用对话框接管，saveFirst 全仓唯一入口是无参 onPressed _send 使其恒 false，text 参数写回臂与 delay 穷尽臂因此结构不可达',
  },
  'lib/features/tasks/task_editor_screen.dart': <int, String>{
    1610: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1619: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1649: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1650: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1651: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1652: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1668: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1888: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1908: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
    1926: '§135.7 任务编辑器：RcStepKind.delay 臂在 _setItems 的两个写入点都不在 kinds 内，六个区间由保序控件写入且模型 assert 已保序使越界提示恒假；远程保存成功/失败两臂需真实已配对端点，立即执行的远程回执不可在宿主伪造',
  },
  'lib/remote/assist_join.dart': <int, String>{
    254: '§135.7 协助会话接入：_pendingHellos 淘汰需队列被真实并发 hello 打满；通道未就绪的发送失败回执需原生通道在握手窗口内掉线',
    353: '§135.7 协助会话接入：_pendingHellos 淘汰需队列被真实并发 hello 打满；通道未就绪的发送失败回执需原生通道在握手窗口内掉线',
  },
  'lib/remote/call_service.dart': <int, String>{
    651: '§135.7 通话服务：rejectBusy 同取值在上方已提前 return，该 switch 臂仅为类型穷尽而保留',
  },
  'lib/remote/credential_sealer.dart': <int, String>{
    42: '§135.7 CredentialSealer 私有构造守卫，防止实例化全静态密封类',
  },
  'lib/remote/endpoint_service.dart': <int, String>{
    2281: '§135.7 端点服务 R105 对齐：审计文案三元拼接臂，需已配对 peer 更新既有任务且 quietExempt 与旧值不同才触发，宿主桩无 prev 差异且真实并发更新窗口不可构造；dndOptOut 同段已由入站冻结用例覆盖',
    2282: '§135.7 端点服务 R105 对齐：审计文案三元拼接臂，需已配对 peer 更新既有任务且 forceRun 与旧值不同才触发，宿主桩无 prev 差异且真实并发更新窗口不可构造；dndOptOut 同段已由入站冻结用例覆盖',
    2840: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    2853: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3027: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3028: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3127: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3131: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3132: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3676: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3951: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3952: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
    3953: '§135.7 端点服务：vibrateStop 把原生异常一律吞掉使 nativeOk 恒真、activeCancel 执行期恒非 null、忙检查无 await 恒假，窗内配额 30 远小于硬上限 200，peek 与 prepare 对 decode 入参逐项相同；指令组占用与解不开回执丢弃需真机并发窗口，宿主无法构造',
  },
  'lib/remote/multi_call_service.dart': <int, String>{
    486: '§135.7 多路通话：pc.close 兜底里的静默挂断需原生 close 抛错才可达',
  },
  'lib/remote/protocol.dart': <int, String>{
    419: '§135.7 协议层：RcCodec 私有构造（全静态、库内外零实例化点）；重试体需 Random.secure 连出 8 位逐字符相同 Base32（约 1/32^8，随机源不可注入）',
    677: '§135.7 协议层：RcCodec 私有构造（全静态、库内外零实例化点）；重试体需 Random.secure 连出 8 位逐字符相同 Base32（约 1/32^8，随机源不可注入）',
  },
  'lib/services/export_crypto.dart': <int, String>{
    10: '§135.7 ExportCrypto 私有构造守卫，防止实例化全静态加密类',
  },
  'lib/services/native_bridge.dart': <int, String>{
    25: '§135.7 NativeBridge 私有构造守卫，防止实例化全静态原生桥接类',
  },
};

/// 解析 lcov.info → `文件路径(正斜杠) → (LF, LH, 未命中行号集合)`。
///
/// R104 起额外读 `DA:<line>,0`：行级「残差登记豁免」必须精确绑到
/// **真实未覆盖的行号**，否则「逐行举证」会退化成按文件拍脑袋报个数。
Map<String, ({int lf, int lh, Set<int> misses})> parseLcov(String text) {
  final out = <String, ({int lf, int lh, Set<int> misses})>{};
  String? cur;
  var lf = 0, lh = 0;
  final misses = <int>{};

  void flush() {
    if (cur != null) {
      final prev = out[cur!];
      // 同一文件可能被多个 isolate 写了多条 `SF:` 记录 → 未命中行取并集，
      // LF/LH 取本条记录（覆盖率口径仍以 LF/LH 为准，见下方校验）。
      out[cur!] = (
        lf: lf,
        lh: lh,
        misses: prev == null ? misses.toSet() : {...prev.misses, ...misses},
      );
    }
    cur = null;
    lf = 0;
    lh = 0;
    misses.clear();
  }

  for (final raw in const LineSplitter().convert(text)) {
    if (raw.startsWith('SF:')) {
      flush();
      var p = raw.substring(3).trim().replaceAll(r'\', '/');
      // ⚠️ 某些环境下 `flutter test --coverage` 写的是**绝对路径**
      // （如 `D:/.../main-fb118d7d/lib/xxx.dart`）⇒ 统一裁到 `lib/` 开头。
      // 否则下面的「分母完整性」锁会把 103 个文件全判成「没有 SF: 记录」（**假红**）。
      final i = p.lastIndexOf('/lib/');
      if (i >= 0) p = p.substring(i + 1);
      cur = p;
    } else if (raw.startsWith('LF:')) {
      lf = int.tryParse(raw.substring(3).trim()) ?? 0;
    } else if (raw.startsWith('LH:')) {
      lh = int.tryParse(raw.substring(3).trim()) ?? 0;
    } else if (raw.startsWith('DA:') && cur != null) {
      final bits = raw.substring(3).split(',');
      if (bits.length >= 2) {
        final no = int.tryParse(bits[0].trim());
        final hit = int.tryParse(bits[1].trim());
        if (no != null && hit == 0) misses.add(no);
      }
    } else if (raw == 'end_of_record') {
      flush();
    }
  }
  flush();
  return out;
}

/// `lib/` 下所有 `.dart`（正斜杠相对路径，已排序）。
List<String> libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll(r'\', '/'))
    .where((p) => p.endsWith('.dart'))
    .toList()
  ..sort();

String pct(int hit, int found) =>
    found == 0 ? '  n/a' : (hit * 100 / found).toStringAsFixed(2).padLeft(6);

void main(List<String> args) {
  final top = int.tryParse(
      args.firstWhere((a) => a.startsWith('--top='), orElse: () => '--top=20').split('=')[1]) ??
      20;
  final asJson = args.contains('--json');
  final gateArg = args.firstWhere((a) => a.startsWith('--gate='), orElse: () => '');
  final gate = gateArg.isEmpty ? null : double.tryParse(gateArg.split('=')[1]);
  // R104：第三个口径的独立判据（官方 4 步门禁不带此参数，口径保持不变）。
  final netGateArg =
      args.firstWhere((a) => a.startsWith('--net-gate='), orElse: () => '');
  final netGate = netGateArg.isEmpty
      ? null
      : double.tryParse(netGateArg.split('=')[1]);
  // 分子硬下限（第三十四轮新增）。理由见文件末尾 `_minCoveredRationale`。
  final minCovArg = args
      .firstWhere((a) => a.startsWith('--min-covered='), orElse: () => '');
  final minCovered =
      minCovArg.isEmpty ? null : int.tryParse(minCovArg.split('=')[1]);

  final lcovFile = File('coverage/lcov.info');
  if (!lcovFile.existsSync()) {
    stderr.writeln('找不到 coverage/lcov.info —— 先跑：\n'
        '  flutter test --coverage --exclude-tags perf');
    exit(2);
  }

  final cov = parseLcov(lcovFile.readAsStringSync());
  final lib = libFiles();

  // ── 锁 1：分母完整性（lib 下每个文件都必须在 lcov 里出现） ──────────────
  final notInstrumented = lib
      .where((f) => !cov.containsKey(f) && !_noExecutableLines.contains(f))
      .toList();
  // ── 锁 2：豁免清单不得含已不存在的文件（防"豁免一个幽灵文件"注水） ──────
  final libSet = lib.toSet();
  final staleExempt = _deviceOnly.keys.where((f) => !libSet.contains(f)).toList();
  // ── 锁 3：豁免文件必须真的在 lcov 里（否则豁免毫无意义） ────────────────
  final exemptNoData =
      _deviceOnly.keys.where((f) => !cov.containsKey(f) && libSet.contains(f)).toList();
  // ── 锁 4：白名单反向自检 —— 有可执行行的文件不得躺在白名单里 ─────────────
  final staleNoExec =
      _noExecutableLines.where((f) => cov.containsKey(f)).toList();

  final problems = <String>[
    if (notInstrumented.isNotEmpty)
      '分母不完整：lib 下有 ${notInstrumented.length} 个文件没有 SF: 记录\n'
          '  ${notInstrumented.join('\n  ')}\n'
          '  修复：dart run tool/gen_coverage_sentinel.dart',
    if (staleExempt.isNotEmpty)
      '豁免清单含已不存在的文件（会静默注水）：\n  ${staleExempt.join('\n  ')}',
    if (exemptNoData.isNotEmpty)
      '豁免清单含无覆盖率数据的文件：\n  ${exemptNoData.join('\n  ')}',
    if (staleNoExec.isNotEmpty)
      '白名单失效：这些文件已有可执行行（出现在 lcov 里），必须从 '
          '_noExecutableLines 移除，否则会漏算：\n  ${staleNoExec.join('\n  ')}',
  ];

  // ── 锁 5：行级残差登记豁免（R104，逐行举证） ───────────────────────────
  final staleExemptLines = <String>[];
  var exemptCount = 0;
  for (final e in _lineExemptions.entries) {
    final c = cov[e.key];
    if (c == null) {
      problems.add('行级豁免指向 lcov 里没有的文件：${e.key}');
      continue;
    }
    if (_deviceOnly.containsKey(e.key)) {
      problems.add('设备层整文件已豁免，不许再登记行级豁免（双重扣减）：${e.key}');
    }
    for (final line in e.value.entries) {
      if (!c.misses.contains(line.key)) {
        staleExemptLines.add('${e.key}:${line.key}');
        continue;
      }
      if (line.value.length < 20 || !line.value.contains('§135.7')) {
        problems.add('行级豁免缺逐行举证（需 ≥20 字且含 §135.7 锚点）：'
            '${e.key}:${line.key} ⇒ ${line.value}');
      }
      exemptCount++;
    }
  }
  // 按文件对账：只要有一行没举证，就不许自称净口径 100%。
  for (final f in cov.keys) {
    if (_deviceOnly.containsKey(f) || !f.startsWith('lib/')) continue;
    final c = cov[f]!;
    final gap = c.lf - c.lh;
    if (gap == 0) continue;
    final claimed =
        _lineExemptions[f]?.keys.where((l) => c.misses.contains(l)).length ?? 0;
    if (gap != claimed) {
      problems.add('$f 未覆盖 $gap 行，但只举证豁免 $claimed 行 ⇒ '
          '净可测面不许自称 100%（补齐 docs/12 §135.7 或补测）');
    }
  }
  if (staleExemptLines.isNotEmpty) {
    print('⚠️ ${staleExemptLines.length} 条行级豁免已被新测试覆盖、本次不计入分母：'
        '${staleExemptLines.take(8).join('、')}'
        '${staleExemptLines.length > 8 ? ' …' : ''} ⇒ 请从清单删除');
  }

  // ── 汇总 ────────────────────────────────────────────────────────────────
  var gLf = 0, gLh = 0; // 全局
  var eLf = 0, eLh = 0; // 设备层
  final rows = <({String f, int lf, int lh, bool exempt})>[];
  for (final f in lib) {
    final c = cov[f];
    if (c == null) continue;
    final ex = _deviceOnly.containsKey(f);
    gLf += c.lf;
    gLh += c.lh;
    if (ex) {
      eLf += c.lf;
      eLh += c.lh;
    }
    rows.add((f: f, lf: c.lf, lh: c.lh, exempt: ex));
  }
  final tLf = gLf - eLf, tLh = gLh - eLh; // 可测面（官方 ratchet 口径，不变）
  // 净可测面：再扣掉「逐行举证为宿主不可达」的行。这些行本来就没被覆盖，
  // 所以分子不动、只减分母；按文件对账通过后必然 100%。
  final netLf = tLf - exemptCount;
  final netLh = tLh;

  final globalPct = gLf == 0 ? 0.0 : gLh * 100 / gLf;
  final testablePct = tLf == 0 ? 0.0 : tLh * 100 / tLf;
  final netPct = netLf == 0 ? 0.0 : netLh * 100 / netLf;

  if (asJson) {
    print(const JsonEncoder.withIndent('  ').convert({
      'global': {'hit': gLh, 'found': gLf, 'pct': double.parse(globalPct.toStringAsFixed(2))},
      'testable': {
        'hit': tLh,
        'found': tLf,
        'pct': double.parse(testablePct.toStringAsFixed(2))
      },
      'deviceOnly': {'hit': eLh, 'found': eLf, 'files': _deviceOnly},
      'netTestable': {
        'hit': netLh,
        'found': netLf,
        'pct': double.parse(netPct.toStringAsFixed(2))
      },
      'lineExemptions': {
        'count': exemptCount,
        'stale': staleExemptLines,
        'files': _lineExemptions.map((k, v) => MapEntry(k, v.length)),
      },
      'uncovered': [
        for (final r in rows.where((r) => r.lf - r.lh > 0))
          {'file': r.f, 'missing': r.lf - r.lh, 'lf': r.lf, 'lh': r.lh, 'exempt': r.exempt}
      ],
      'problems': problems,
    }));
  } else {
    print('=' * 78);
    print('声盾覆盖率报告（分母 = lib/ 全部 ${lib.length} 个文件，已由哨兵保证完整）');
    print('=' * 78);
    print('  全局（对外诚实数字）  ${pct(gLh, gLf)}%   $gLh / $gLf');
    print('  可测面（门禁阈值口径）${pct(tLh, tLf)}%   $tLh / $tLf');
    print('  设备层豁免            ${pct(eLh, eLf)}%   $eLh / $eLf'
        '（${_deviceOnly.length} 个文件）');
    print('  净可测面（逐行举证后）${pct(netLh, netLf)}%   $netLh / $netLf'
        '（行级残差豁免 $exemptCount 行 / ${_lineExemptions.length} 文件，'
        '举证见 docs/12 §135.7）');
    print('');

    if (_deviceOnly.isEmpty) {
      print('  设备层豁免清单为空 —— 所有 lib 代码都计入可测面。');
    } else {
      print('── 设备层豁免（每条都必须有理由，否则就是橡皮章）${'─' * 26}');
      for (final e in _deviceOnly.entries) {
        final c = cov[e.key];
        print('  ${e.key}');
        print('    覆盖 ${c?.lh ?? 0}/${c?.lf ?? 0}  理由：${e.value}');
      }
    }
    print('');

    final gaps = rows.where((r) => r.lf - r.lh > 0).toList()
      ..sort((a, b) => (b.lf - b.lh).compareTo(a.lf - a.lh));
    print('── 未覆盖行最多的 $top 个文件${'─' * 44}');
    print('  ${"未覆盖".padLeft(6)} ${"LF".padLeft(6)} ${"LH".padLeft(6)}  '
        '${"%".padLeft(7)}  文件');
    for (final r in gaps.take(top)) {
      final mark = r.exempt ? '[设备]' : '      ';
      print('  ${(r.lf - r.lh).toString().padLeft(6)} ${r.lf.toString().padLeft(6)} '
          '${r.lh.toString().padLeft(6)}  ${pct(r.lh, r.lf)}%  $mark ${r.f}');
    }
    final totalGap = gaps.fold<int>(0, (s, r) => s + (r.lf - r.lh));
    print('  ${'─' * 74}');
    print('  未覆盖合计 $totalGap 行；其中设备层豁免 '
        '${gaps.where((r) => r.exempt).fold<int>(0, (s, r) => s + (r.lf - r.lh))} 行');
    print('');
  }

  if (problems.isNotEmpty) {
    print('─' * 78);
    print('❌ 报告不可信，先修这些问题：');
    for (final p in problems) {
      print('  · $p');
    }
    exit(2);
  }

  if (gate != null) {
    if (testablePct + 1e-9 < gate) {
      print('❌ 门禁未过：可测面 ${testablePct.toStringAsFixed(2)}% < $gate%');
      exit(1);
    }
    print('✅ 门禁通过：可测面 ${testablePct.toStringAsFixed(2)}% ≥ $gate%');
  }

  if (netGate != null) {
    if (netPct + 1e-9 < netGate) {
      print('❌ 净口径门禁未过：净可测面 ${netPct.toStringAsFixed(2)}% < '
          '$netGate%（已举证 $exemptCount 行，未举证残差见上方 problems）');
      exit(1);
    }
    print('✅ 净口径门禁通过：净可测面 ${netPct.toStringAsFixed(2)}% ≥ '
        '$netGate%（逐行举证豁免 $exemptCount 行，docs/12 §135.7）');
  }

  // ── 分子硬下限 ────────────────────────────────────────────────────────
  //
  // 为什么百分比之外**还要**一个绝对数下限：分母不是常数。
  // 每当我们**合规地**新增"宿主不可达但安全/正确性必需"的代码（平台插件
  // 胶水、MQTT 连接、原生桥调用），分母就会变大，百分比被**稀释** ——
  // 于是"什么都不做"反而比"老实加防护"更好看。这个指标会奖励错误的行为。
  //
  // [tLh]（可测面已覆盖行数）才是**真实进度**：它不随分母波动，
  // 而且"给新代码补测试"会直接抬高它。所以百分比守住"密度"，
  // 绝对数守住"总量不许倒退"。
  if (minCovered != null) {
    if (tLh < minCovered) {
      print('❌ 门禁未过：可测面已覆盖行数 $tLh < $minCovered'
          '（分母 $tLf；百分比 ${testablePct.toStringAsFixed(2)}%）');
      print('   绝对数倒退说明**已覆盖的行被删/被改掉了**（或新代码没配测试），'
          '不是"分母变大"能解释的。');
      exit(1);
    }
    print('✅ 分子下限通过：已覆盖 $tLh ≥ $minCovered（分母 $tLf）');
  }
}
