import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

/// 远程协议（`RcCmd` / `RcEvt`）的**三向覆盖机器锁**。
///
/// ## 为什么要有这个文件
///
/// BUG-037 / BUG-046 / BUG-048 是同一类缺陷的不同表现：
/// **协议里声明了一条命令或事件，但链路的某一端是断的** ——
/// 端点有 `case` 但控制器从不发送、控制器发了但端点没实现、
/// 端点广播了但没有 UI 消费。每一端单看都"对"，整条链路是断的。
///
/// 第十三轮起用**人工**三向覆盖比对（端点处理 / 控制器发送 / UI 消费）
/// 一次性定位过 5 条断链命令；但人工比对只能发现"当下"的洞，
/// 新加一条命令后是否登记齐全，仍然靠人记。本文件把这张比对表
/// **变成可断言的量**：新增 `RcCmd`/`RcEvt` 常量后如果漏接任何一端，
/// 功能层门禁直接红。
///
/// ## 判据（每一向都必须成立）
///
/// | 维度 | 要求 |
/// |---|---|
/// | `RcCmd` → 端点 | `endpoint_service.dart` 有 `case RcCmd.X` |
/// | `RcCmd` → 权限闸门 | `assist.dart` 的 `RcPermGate.requiredPerm` **显式登记** |
/// | `RcCmd` → 发送方 | 至少一个非端点文件构造该命令 |
/// | `RcEvt` → 发出方 | `endpoint_service.dart` 至少发一次 |
/// | `RcEvt` → 消费方 | 至少一个非端点文件引用它 |
/// | `RcEvt` → **App 内**消费方 | 至少一个 `lib/` 下的文件引用它 |
///
/// ## 为什么"权限闸门显式登记"值得单独锁
///
/// `requiredPerm` 的 `switch` 末尾是 `_ => denyAll` —— 这是**正确的安全默认**
/// （新增命令忘记登记时应当失败关闭，而不是默认放行）。但它的代价是：
/// 漏登记**不会编译报错**，只会在协助会话里表现为"命令被静默拒绝"。
/// 这正是最需要回归锁的那类"静默降级"，所以本文件要求它必须显式列出。
///
/// ## 实现方式（源码契约）
///
/// Dart 无运行时反射，故直接解析 `lib/remote/protocol.dart` 的类体文本。
/// 这是**权衡而非首选**：若将来协议常量改由代码生成（如 protobuf），
/// 应改为断言生成产物而不是源码文本。

// **剥掉注释**再做文本扫描 —— 本锁能被信任的前提（W5 P1）。
//
// 本项目刻意在 `lib/` 的注释里**写明**"每条命令必须登记"这类约定及其理由。
// 不剥注释：存在性断言（`case RcCmd.x`）会被注释冒充（假绿）；
// 禁止性断言（缺口登记表"不得冗余"）会把说明文字判成违规（假红）。
//
// 实现见 `test/support/source_text.dart`（第 36 轮收敛到唯一真源；
// 此前本文件抄的是 test/rc_transport_lock_test.dart:72 那份副本）。


void main() {
  // ---------------- 源码读取 ----------------
  // ⚠️ 读入即剥注释（W5 P1）：下面所有 `contains` / `refsIn` 判据
  // 只认**代码**，注释里引用 `RcCmd.xxx` 不是发送、不是 case、不是登记。
  final protocol =
      stripComments(File('lib/remote/protocol.dart').readAsStringSync());
  final endpoint =
      stripComments(File('lib/remote/endpoint_service.dart').readAsStringSync());
  final permGate =
      stripComments(File('lib/remote/assist.dart').readAsStringSync());

  /// 除端点 / 权限闸门 / 协议定义之外的**所有** Dart 源（含 `tool/` 桌面控制器）。
  final others = <String, String>{};
  for (final dir in ['lib', 'tool']) {
    for (final f in Directory(dir).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final p = f.path.replaceAll(r'\', '/');
      if (p == 'lib/remote/protocol.dart' ||
          p == 'lib/remote/endpoint_service.dart' ||
          p == 'lib/remote/assist.dart') {
        continue;
      }
      others[p] = stripComments(f.readAsStringSync());
    }
  }

  /// 仅 `lib/`（**App 内**）的源，不含 `tool/`。
  final inApp = <String, String>{
    for (final e in others.entries)
      if (e.key.startsWith('lib/')) e.key: e.value,
  };

  /// 取出 `abstract final class <name> { ... }` 的类体文本。
  ///
  /// 注意：这里在 `test()` 之外执行，**不能用 `expect`**（会抛
  /// `OutsideTestException`），故用 `StateError` 表达"解析前提不成立"。
  String classBody(String src, String name) {
    final sig = 'abstract final class $name {';
    final start = src.indexOf(sig);
    if (start < 0) throw StateError('协议里找不到 $name 类');
    // 花括号配对取类体：不再写死 `indexOf('\n}', start)`（依赖"类在行首收尾"
    // 的排版，缩进一变就静默切错，见 test/support/source_text.dart / A12）。
    final body = balancedSlice(src, start + sig.length - 1);
    if (body == null) throw StateError('$name 类体未正常闭合');
    return body;
  }

  /// 类体里的 `static const <name> =` 常量名。
  List<String> constNames(String body) => RegExp(r'static const (\w+)\s*=')
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toList();

  final cmds = constNames(classBody(protocol, 'RcCmd'));
  final evts = constNames(classBody(protocol, 'RcEvt'));

  /// 某个 token 在哪些文件里出现。
  List<String> refsIn(Map<String, String> files, String token) => [
        for (final e in files.entries)
          if (e.value.contains(token)) e.key
      ];

  // ---------------- 已知缺口登记 ----------------
  //
  // 每条都必须写明**为什么可以暂时不接**以及**解除条件**。
  // 缺口被修复后请从本表删除 —— 最后一个用例会检查本表是否腐烂。

  /// 端点有 `case`、但全项目没有任何发送方。
  const cmdWithoutSender = <String, String>{
    'taskGet': '端点有实现，但无 UI 入口：`task.list` 已返回完整定义，'
        '单条拉取属预留能力（第七轮已判定为有意保留）。'
        '解除条件：控制台做「按 id 拉取单条任务」时一并接线。',
    'deviceAlert': '找回告警（Q9-B）：端点分发与原生桥已接线，'
        '控制端 UI 入口下一轮加入。解除条件：控制台加「找回」按钮。',
  };

  /// **必须在协助会话被拒绝、但登记在别处**的命令。
  ///
  /// `RcPermGate.requiredPerm` 的 `_ => denyAll` 已经让它们天然被拒，
  /// 只是那条登记**不在 `assist.dart` 里**，本文件按文件名取文本，因此
  /// 需要在这里显式登记，否则下面的"三向之二"会把它们误报成缺口。
  ///
  /// ⚠️ 这不是"豁免"：登记在这张表里的命令，其**运行时拒绝**由
  /// `test/pair_roundtrip_test.dart` 直接断言
  /// （`RcPermGate.allows(全放行, cmd) == false`）。
  /// 一旦有人给 `assist.dart` 里的它配上真实权限位，两处会同时红 ——
  /// 表里"不得冗余"用例要求删除本条目，行为用例要求 denyAll 仍成立。
  const cmdDeniedInAssist = <String, String>{
    'pairRequest': '`pair.request` 是**配对**命令，不是协助命令：协助对端'
        '**未配对**，允许它等于让人借"临时协助"把自己变成已配对设备（提权面）。'
        '`requiredPerm` 未登记 ⇒ `denyAll` ⇒ 一律拒绝。'
        '登记在此是因为 `lib/remote/assist.dart` 不在本轮的改动范围内；'
        '运行时拒绝由 test/pair_roundtrip_test.dart 锁死。'
        '解除条件：在 assist.dart 的 `requiredPerm` 里显式列出它（保持 denyAll 语义）。',
  };

  /// 无人发出的事件。
  ///
  /// ⚠️ `callMissed` 已于第十七轮**闭环**（BUG-050）：端点侧 `_wireCall()` 会在
  /// 被叫振铃超时后发出它。按本表的规矩，修好就要删条目（见下方"不得冗余"用例）。
  const evtWithoutEmitter = <String, String>{
    'photo': '`camera.snap` 因 camera 插件无 AGP9 兼容版而按设计降级',
  };

  /// 无人消费的事件。
  ///
  /// 第十七轮已**清空**：`callMissed` 现在由 `CallService._onRemoteEvent`
  /// 与通话 UI 消费（BUG-050）。
  const evtWithoutConsumer = <String, String>{};

  /// 有消费方，但**只在 `tool/` 桌面 E2E 工具里**，App 内无消费者。
  ///
  /// ⚠️ `scriptState` 已于第十七轮**续五**闭环：`RemoteScriptsTab` 现在消费
  /// `RcEvt.scriptState` 显示执行进度（纯逻辑在 `lib/remote/script_progress.dart`，
  /// 回归锁在 `test/script_progress_test.dart`）。按本表规矩，修好就删条目 ——
  /// 下面的"不得冗余"用例会强制这一点。
  const evtWithoutInAppConsumer = <String, String>{
    'heartbeat': '`rc.heartbeat` 的语义是"端点还活着"。控制台的在线判定已经由'
        '「任意同 peerId 事件都算存活」覆盖（心跳是最慢的恢复信号），'
        '**App 内无需单独分支**。'
        '第十七轮起 `tool/rc_probe.dart` 会消费它 —— 用来把心跳从"真回执"里'
        '剔除，并统计心跳条数以区分「端点离线」与「密钥不匹配」'
        '（BUG-052 的教训：心跳曾让"密文到达即通过"的判据恒真）。'
        '因此它已**有人消费**，只是 App 内没有。',
    'plan': '`rc.plan` 是 `plan.get` 的清单回传（端点 → 控制端），'
        '与 `RcEvt.tasks/assets/presets` 同一形态：先由 `tool/rc_probe.dart` 的'
        '`plan` 探针步骤消费（E2E 核验"远程读计划"链路通）。'
        'App 作为**被控端**时只需发出该事件；App 作为**控制端**的远程计划展示'
        'UI 尚未排期，故 App 内暂无消费者。'
        '解除条件：控制台加「查看远端反击计划」入口时，一并消费该事件。',
  };

  // ---------------- 用例 ----------------

  test('协议常量可被解析（防空解析：锁本身必须真的在检查东西）', () {
    expect(cmds.length, greaterThanOrEqualTo(25),
        reason: 'RcCmd 常量数异常偏少，解析可能失效');
    expect(evts.length, greaterThanOrEqualTo(18),
        reason: 'RcEvt 常量数异常偏少，解析可能失效');
    expect(cmds.toSet().length, cmds.length, reason: 'RcCmd 有重名常量');
    expect(evts.toSet().length, evts.length, reason: 'RcEvt 有重名常量');
  });

  test('RcCmd 三向之一：每条命令端点都有 case', () {
    // 收窄到 `_dispatch` 的函数体（W5 P1）：`case RcCmd.x` 必须真的落在
    // 端点分发的 switch 里，而不是文件里任何角落（别的注释/文本都算不了数）。
    final dispatch = methodBody(endpoint, 'Future<void> _dispatch(');
    final missing = [
      for (final c in cmds)
        if (!dispatch.contains('case RcCmd.$c')) c,
    ];
    expect(missing, isEmpty, reason: '这些命令端点没有处理分支：$missing');
  });

  test('RcCmd 三向之二：每条命令都在权限闸门显式登记', () {
    final missing = [
      for (final c in cmds)
        if (!permGate.contains('RcCmd.$c') && !cmdDeniedInAssist.containsKey(c))
          c,
    ];
    expect(missing, isEmpty,
        reason: '这些命令未登记进 RcPermGate.requiredPerm —— '
            '`_ => denyAll` 会让它们在协助会话里被**静默拒绝**（不报错）：$missing');
  });

  test('RcCmd 三向之三：每条命令都有发送方', () {
    final missing = [
      for (final c in cmds)
        if (refsIn(others, 'RcCmd.$c').isEmpty &&
            !cmdWithoutSender.containsKey(c))
          c,
    ];
    expect(missing, isEmpty, reason: '这些命令全项目无人发送（端点能力空转）：$missing');
  });

  test('RcEvt 三向之一：每个事件端点都会发出', () {
    final missing = [
      for (final e in evts)
        if (!endpoint.contains('RcEvt.$e') && !evtWithoutEmitter.containsKey(e))
          e,
    ];
    expect(missing, isEmpty, reason: '这些事件无人发出（消费者永远等不到）：$missing');
  });

  test('RcEvt 三向之二：每个事件都有人消费', () {
    final missing = [
      for (final e in evts)
        if (refsIn(others, 'RcEvt.$e').isEmpty &&
            !evtWithoutConsumer.containsKey(e))
          e,
    ];
    expect(missing, isEmpty, reason: '这些事件发出后无人消费（白耗带宽）：$missing');
  });

  test('RcEvt 三向之三：每个事件在 App 内都有消费者', () {
    final missing = [
      for (final e in evts)
        if (refsIn(inApp, 'RcEvt.$e').isEmpty &&
            !evtWithoutConsumer.containsKey(e) &&
            !evtWithoutInAppConsumer.containsKey(e))
          e,
    ];
    expect(missing, isEmpty,
        reason: '这些事件只有桌面 E2E 工具消费，App 内看不到（用户可见缺口）：$missing');
  });

  test('缺口登记表不得腐烂：登记的名字必须仍存在于协议中', () {
    for (final entry in [
      ...cmdWithoutSender.keys,
      ...cmdDeniedInAssist.keys,
      ...evtWithoutEmitter.keys,
      ...evtWithoutConsumer.keys,
      ...evtWithoutInAppConsumer.keys,
    ]) {
      expect(cmds.contains(entry) || evts.contains(entry), isTrue,
          reason: '缺口登记表里的 `$entry` 已不在协议中 —— '
              '请删除该条目（协议常量被重命名或删除后，登记表会变成噪音）。');
    }
  });

  test('缺口登记表不得冗余：缺口已被修复就必须删除条目', () {
    final stale = <String>[];

    for (final c in cmdWithoutSender.keys) {
      if (refsIn(others, 'RcCmd.$c').isNotEmpty) {
        stale.add('cmdWithoutSender/$c');
      }
    }
    for (final c in cmdDeniedInAssist.keys) {
      // assist.dart 一旦真的登记了它，本条目就该删 —— 否则"拒绝"会从
      // "显式声明"退化成"靠 `_ => denyAll` 兜底"，而本表存在的意义正是
      // 逼着人显式写下来（同时 pair_roundtrip_test 会锁 denyAll 语义）。
      if (permGate.contains('RcCmd.$c')) stale.add('cmdDeniedInAssist/$c');
    }
    for (final e in evtWithoutEmitter.keys) {
      if (endpoint.contains('RcEvt.$e')) stale.add('evtWithoutEmitter/$e');
    }
    for (final e in evtWithoutConsumer.keys) {
      if (refsIn(others, 'RcEvt.$e').isNotEmpty) {
        stale.add('evtWithoutConsumer/$e');
      }
    }
    for (final e in evtWithoutInAppConsumer.keys) {
      if (refsIn(inApp, 'RcEvt.$e').isNotEmpty) {
        stale.add('evtWithoutInAppConsumer/$e');
      }
    }

    expect(stale, isEmpty, reason: '这些缺口其实已经接上了，请从登记表删除并更新 docs/17：$stale');
  });
}
