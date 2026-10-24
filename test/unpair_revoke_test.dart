import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';

import 'support/source_text.dart';

/// P0 回归锁：**解除配对后，该 deviceId 的入站命令必须被拒绝**。
///
/// ## 缺陷形状（A3 §2「撤销」）
///
/// `/cmd` 的准入此前**只有一条**：能用「本机配对码 + `{本机ID}|cmd`」
/// 解密成功（`endpoint_service._handleRaw`）。而配对码是全体已配对控制端
/// **共享**的、且**无轮换入口** —— 于是 `RemoteStore.removePaired(id)`
/// 只把该控制端移出本机列表，**拦不住它的任何命令**；`_peerOf` 在表里查不到
/// 时还会**构造占位对端**继续 `_dispatch`，等于默认放行。
///
/// 结果：**配对移出了列表，但对方仍能控制本机**。
///
/// ## 本文件锁什么
///
/// 1. **纯判据**（[decideRcAdmission]）：表内 → 放行；表外（含**已解除配对**）
///    → 拒绝。可穷举断言，能做变异证伪（改判据立刻红）。
/// 2. **真实存盘链路**：走 [RemoteStore.addPaired] / [removePaired]，
///    证明"移出列表"真的会让同一 deviceId 立刻被拒。
/// 3. **接线锁**（源码契约）：判据必须出现在 `_handleRaw` 里、且**早于**
///    `_dispatch`/`guardDispatch`；拒绝分支必须 `return` 且**不得**落到
///    `_dispatch`（反退化：只查列表却照样执行 = 假修复）。
///
/// ## 为什么"其它已配对端点不受影响"也要锁
///
/// 撤销最容易写坏的形状是"一刀切"（例如清空整表、或按主题前缀连坐）。
/// 判据必须是**逐发送方**、**无状态**的 —— 见 UR-04 / UR-05。


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final source = File('lib/remote/endpoint_service.dart').readAsStringSync();

  late RemoteStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = RemoteStore(await SharedPreferences.getInstance());
  });

  PairedEndpoint endpointOf(String id) => PairedEndpoint(
        deviceId: id,
        name: '控制器',
        secret: 'secret-$id',
        pairedAt: DateTime.now(),
      );

  /// 复刻 `_handleRaw` 的准入调用形状：**查当前配对表** → 纯判据。
  ///
  /// 刻意不直接传写死的 bool：锁要覆盖"查表 + 判据"这条真实链路 ——
  /// 否则把 `endpointById` 换成常量也能"通过"，那正是自欺的锁。
  RcAdmission admitFrom(
          List<PairedEndpoint> table, String senderId, String type) =>
      decideRcAdmission(
        senderId: senderId,
        type: type,
        senderPaired: endpointById(table, senderId) != null,
      );

  /// 只保留仍配对的端点（等价于"移除了 [removedId]"后的表）。
  List<PairedEndpoint> withoutId(List<PairedEndpoint> table, String removedId) => [
        ...table.where((e) => e.deviceId != removedId),
      ];

  group('UR-A 准入判据（纯函数，可变异证伪）', () {
    test('UR-01 已配对发送方 → 放行', () {
      final table = [endpointOf('a' * 16)];
      final verdict = admitFrom(table, 'a' * 16, RcCmd.ping);
      expect(verdict, RcAdmission.allowPaired);
      expect(verdict.allowed, isTrue);
    });

    test('UR-02 ★ 解除配对后，该 deviceId 的入站命令被拒绝', () {
      final table = [endpointOf('a' * 16)];
      expect(admitFrom(table, 'a' * 16, RcCmd.ping).allowed, isTrue,
          reason: '前提（反断言）：解除之前，同一条命令是放行的 —— '
              '否则本锁可能只是恒拒的假绿');

      final after = withoutId(table, 'a' * 16);
      // 挑一条"真会执行东西"的命令（指令组），而不是只读的 ping。
      final verdict = admitFrom(after, 'a' * 16, RcCmd.scriptRun);
      expect(verdict, RcAdmission.rejectUnpaired,
          reason: '★ 解除配对后必须返回 rejectUnpaired —— 只把端点移出 UI 列表'
              '而放行命令，就是本缺陷本身');
      expect(verdict.allowed, isFalse,
          reason: '★ allowed 必须为 false：它是 _handleRaw 唯一的放行开关');
    });

    test('UR-03 拒绝是幂等的：同输入恒同裁决，反复下发不会变放行', () {
      final after = withoutId([endpointOf('a' * 16)], 'a' * 16);
      for (var i = 0; i < 3; i++) {
        expect(admitFrom(after, 'a' * 16, RcCmd.scriptRun),
            RcAdmission.rejectUnpaired,
            reason: '第 ${i + 1} 次仍须拒绝');
      }
    });

    test('UR-04 ★ 解除一台不影响其它已配对端点', () {
      final table = [endpointOf('a' * 16), endpointOf('b' * 16)];
      final after = withoutId(table, 'a' * 16);

      expect(admitFrom(after, 'a' * 16, RcCmd.ping), RcAdmission.rejectUnpaired,
          reason: '被解除的 a 必须失效');
      expect(admitFrom(after, 'b' * 16, RcCmd.ping), RcAdmission.allowPaired,
          reason: '★ 仍在表里的 b 不受任何影响 —— 撤销不得"连坐"');
    });

    test('UR-05 pair.request 未配对时仍放行（否则永远无法重新配对）', () {
      const empty = <PairedEndpoint>[];
      final verdict = admitFrom(empty, 'a' * 16, RcCmd.pairRequest);
      expect(verdict, RcAdmission.allowPairing);
      expect(verdict.allowed, isTrue,
          reason: '握手本身必须畅通：配对码无轮换入口时，重新配对是唯一恢复路径');
    });

    test('UR-06 未标识发送方（from 空）**拒绝** —— R94 收紧（P0-001 / REM-01）', () {
      const empty = <PairedEndpoint>[];
      final verdict = admitFrom(empty, '', RcCmd.ping);
      expect(verdict, RcAdmission.rejectUnidentified);
      expect(verdict.allowed, isFalse,
          reason: '旧实现此处放行（allowUnidentified），等于「我不知道你是谁，'
              '但我允许你做任何事」—— 持有配对码者把 from 留空即可绕过 '
              'rejectUnpaired / rejectRevoked，撤销授权形同虚设');

      // 反面样本（证明判据非恒假）：同一命令、同一空配对表，只要发送方
      // **标识了自己且确实在表里**，就必须放行。
      final paired = [endpointOf('d' * 16)];
      expect(admitFrom(paired, 'd' * 16, RcCmd.ping), RcAdmission.allowPaired,
          reason: '非恒真样本：拒空 from 不等于拒一切');
    });

    test('UR-07 从未配对且已标识发送方 → 同样拒绝（不止"删过"）', () {
      const empty = <PairedEndpoint>[];
      expect(admitFrom(empty, 'c' * 16, RcCmd.guardSet),
          RcAdmission.rejectUnpaired);
      expect(admitFrom(empty, 'c' * 16, RcCmd.taskUpsert),
          RcAdmission.rejectUnpaired,
          reason: '写库类命令（改任务）也必须先过准入');
    });
  });

  group('UR-B 真实存盘链路（addPaired / removePaired）', () {
    test('UR-08 ★ removePaired 落盘后，同一 deviceId 立即被拒', () async {
      await store.addPaired(endpointOf('a' * 16));
      expect(admitFrom(store.paired(), 'a' * 16, RcCmd.soundPlay).allowed,
          isTrue,
          reason: '前提：配对在表里时放行');

      await store.removePaired('a' * 16);

      expect(store.paired(), isEmpty, reason: '配对表已落盘移除');
      expect(admitFrom(store.paired(), 'a' * 16, RcCmd.soundPlay),
          RcAdmission.rejectUnpaired,
          reason: '★ 授权撤销必须对**入站命令**生效，而不是只从 UI 列表消失');
    });

    test('UR-09 removePaired 只精确移除目标项（不误伤同表其它端点）', () async {
      await store.addPaired(endpointOf('a' * 16));
      await store.addPaired(endpointOf('b' * 16));

      await store.removePaired('a' * 16);

      expect(store.paired().map((e) => e.deviceId).toList(), ['b' * 16]);
      expect(admitFrom(store.paired(), 'b' * 16, RcCmd.ping).allowed, isTrue,
          reason: '★ b 仍被放行 —— 撤销是逐 deviceId 的');
    });
  });

  group('UR-C 接线锁（源码契约：必须拦在 _dispatch 之前）', () {
    final raw = methodBody(source, 'Future<void> _handleRaw(');

    test('UR-10 准入判据在 _handleRaw 内，且早于 guardDispatch（拦在执行之前）', () {
      final gateAt = raw.indexOf('decideRcAdmission(');
      final runAt = raw.indexOf('await guardDispatch(');
      expect(gateAt, greaterThanOrEqualTo(0),
          reason: '缺少准入判据 ⇒ 退回"能解密即执行"（本缺陷）');
      expect(runAt, greaterThanOrEqualTo(0));
      expect(gateAt, lessThan(runAt),
          reason: '★ 判据必须在 _dispatch/guardDispatch **之前** —— '
              '放在之后等于"先执行再检查"，是假修复');
    });

    test('UR-11 ★ 反退化：拒绝分支必须真的 return，且不得落到 _dispatch', () {
      final gateAt = raw.indexOf('decideRcAdmission(');
      final runAt = raw.indexOf('await guardDispatch(', gateAt);
      expect(runAt, greaterThan(gateAt));
      final branch = raw.substring(gateAt, runAt);

      expect(branch.contains('await _auditAdmissionReject(msg)'), isTrue,
          reason: '拒绝必须**留痕**（不得静默吞）');
      expect(branch.contains('return;'), isTrue,
          reason: '★ 必须 return：只把 allowed 算出来却不返回，命令照样执行');
      expect(branch.contains('_dispatch('), isFalse,
          reason: '★ 拒绝分支里不得出现 _dispatch —— 出现即"既拒绝又执行"');
    });

    test('UR-12 ★ 判据来自真实配对表查表，而非常量', () {
      expect(raw.contains('endpointById(store.paired(), msg.from)'), isTrue,
          reason: '裁决输入必须是**当前**配对表；换成常量就能骗过'
              '"看起来查了列表"的假锁');
      expect(raw.contains('senderPaired:'), isTrue);
    });

    test('UR-13 拒绝审计可诊断：remote/rejected/命令类型/发送方/限频', () {
      final audit = methodBody(source, 'Future<void> _auditAdmissionReject(');
      expect(audit.contains("source: 'remote'"), isTrue);
      expect(audit.contains("status: 'rejected'"), isTrue,
          reason: '拒绝是**独立可辨**的审计状态 —— 混进 failed/skipped 会让'
              '"授权已被撤销"淹没在普通失败里，失去可诊断性');
      expect(audit.contains('action: msg.type'), isTrue,
          reason: '要能回答"哪条命令被拒了"');
      expect(audit.contains('已不在配对表'), isTrue,
          reason: '文案必须直指"授权/配对已撤销"，否则用户只会去查网络');
      expect(audit.contains('_rejectFlood.allow('), isTrue,
          reason: '必须限频：被撤销的控制端会按连接/心跳重放命令，'
              '不限频会把审计刷爆（与 R-2 同考量）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // UR-D · 撤销的**另一半**：在途作业清场（第三十四轮 P1）
  // ══════════════════════════════════════════════════════════════════
  //
  // UR-B / UR-C 锁的是"下一条命令会被拒"。但**已经在跑**的作业不受准入约束：
  //
  //   · 一个 30 分钟的 `script.run`（可能正在播放声音 / 正在录音取证）
  //   · 一通 `call.invite` 视频通话（占着摄像头与麦克风）
  //
  // 使用者点「删除设备 / 取消配对」的心智模型是**立即断开**，而旧实现里
  // 列表已经空了、端点还在执行它下发的指令 —— 正是"撤销后仍能造成影响"。
  //
  // 判据抽成纯函数 [decideRevokeCleanup] 的理由与 [decideRcAdmission] 相同：
  // 必须能穷举 + 变异证伪，尤其要钉住**"不误伤另一个授权控制端"**。
  group('UR-D 撤销后的在途作业清场（判据）', () {
    RcRevokePlan plan({
      required String revoked,
      String? scriptOwner,
      bool scriptRunning = false,
      String? callPeer,
      bool callActive = false,
    }) =>
        decideRevokeCleanup(
          revokedId: revoked,
          scriptOwnerId: scriptOwner,
          scriptRunning: scriptRunning,
          callPeerId: callPeer,
          callActive: callActive,
        );

    test('UR-14 在途指令组属于被撤销方 → 停指令组，不碰通话', () {
      final p = plan(revoked: 'a', scriptOwner: 'a', scriptRunning: true);
      expect(p.stopScript, isTrue);
      expect(p.hangUpCall, isFalse);
      expect(p.isEmpty, isFalse);
      expect(p.label, '指令组');
    });

    test('UR-15 在途通话对端是被撤销方 → 挂断通话', () {
      final p = plan(revoked: 'a', callPeer: 'a', callActive: true);
      expect(p.hangUpCall, isTrue);
      expect(p.stopScript, isFalse);
      expect(p.label, '通话');
    });

    test('UR-16 两者同时在途 → 两个都清，文案并列', () {
      final p = plan(
          revoked: 'a',
          scriptOwner: 'a',
          scriptRunning: true,
          callPeer: 'a',
          callActive: true);
      expect(p.stopScript, isTrue);
      expect(p.hangUpCall, isTrue);
      expect(p.label, '指令组、通话');
    });

    test('UR-17 ★ 不误伤：指令组是**另一个**控制端的 → 一根手指都不许碰', () {
      final p = plan(revoked: 'a', scriptOwner: 'b', scriptRunning: true);
      expect(p.stopScript, isFalse,
          reason: '★ 撤销必须是逐发送方的。写成"有在途就全停"会让 b 的指令组'
              '莫名其妙被终止（使用者看到"没人点它，它自己停了"）');
      expect(p.isEmpty, isTrue);
    });

    test('UR-18 ★ 归属未知（null）一律不停："不知道是谁在跑" ≠ "就是它"', () {
      final byScript =
          plan(revoked: 'a', scriptOwner: null, scriptRunning: true);
      final byCall = plan(revoked: 'a', callPeer: null, callActive: true);
      expect(byScript.isEmpty, isTrue, reason: '宁可漏停（下一条命令有准入兜底）');
      expect(byCall.isEmpty, isTrue);
    });

    test('UR-19 有归属但**没在跑** → 不清（不产生无意义审计）', () {
      final p = plan(revoked: 'a', scriptOwner: 'a', scriptRunning: false);
      expect(p.isEmpty, isTrue,
          reason: 'owner 可能是上一个刚结束的指令组残留；'
              '有 owner 不代表在跑');
    });

    test('UR-20 空 revokedId → 一律不停（防"传空串=全清"的脚枪）', () {
      final p = plan(
          revoked: '',
          scriptOwner: '',
          scriptRunning: true,
          callPeer: '',
          callActive: true);
      expect(p.isEmpty, isTrue,
          reason: '空串若被当成"匹配"，就会变成"一次清全部"');
    });

    // 下面两条是**行为测试**（不是源码锁）：`onPeerRevoked` 在没有在途作业时
    // 走的是"取当前单例状态 → 纯判据 → isEmpty 早退"这一条路，
    // 不碰 MQTT / 数据库，因此宿主机可直接跑。
    test('UR-20a 无在途作业时 onPeerRevoked 是**静默幂等**的空操作', () async {
      // 前提：单例未 start ⇒ 既无在途指令组也无在途通话。
      expect(RcScriptExecutor.instance.isRunning, isFalse,
          reason: '前提：宿主机上没有在途指令组');
      expect(CallService.instance.inCall, isFalse, reason: '前提：没有在途通话');

      // 不抛、不写审计、可重复调用。
      await RcEndpointService.instance.onPeerRevoked('a' * 16);
      await RcEndpointService.instance.onPeerRevoked('a' * 16);
      await RcEndpointService.instance.onPeerRevoked('');
      // 若这里抛异常（例如 `_db!` 空指针），使用者点"删除设备"就会崩 ——
      // 这也正是 UR-26 锁的那条早退的运行时兜底。
    });

    test('UR-20b 传空 deviceId 立即返回（不查任何单例状态）', () async {
      await RcEndpointService.instance.onPeerRevoked('');
      expect(decideRevokeCleanup(
        revokedId: '',
        scriptOwnerId: 'x',
        scriptRunning: true,
        callPeerId: 'x',
        callActive: true,
      ).isEmpty, isTrue);
    });
  });

  group('UR-E 接线锁：清场必须真的被两处入口调用', () {
    final dlSrc = File('lib/features/remote/device_list_screen.dart')
        .readAsStringSync();
    final rsSrc =
        File('lib/features/remote/remote_screen.dart').readAsStringSync();

    test('UR-21 ★ 两处解除配对入口都调用了 onPeerRevoked', () {
      expect(dlSrc.contains('RcEndpointService.instance.onPeerRevoked('), isTrue,
          reason: '「我的设备」页删除设备后必须清场');
      expect(rsSrc.contains('RcEndpointService.instance.onPeerRevoked('), isTrue,
          reason: '远程总览页"取消配对"同样必须清场 —— 漏一处就是半个修复');
    });

    test('UR-22 ★ 顺序：先 removePaired，后 onPeerRevoked（不能反）', () {
      for (final entry in {'device_list_screen.dart': dlSrc, 'remote_screen.dart': rsSrc}.entries) {
        final src = entry.value;
        final removeAt = src.indexOf('removePaired(');
        final revokeAt = src.indexOf('onPeerRevoked(');
        expect(removeAt, greaterThanOrEqualTo(0), reason: '${entry.key} 缺 removePaired');
        expect(revokeAt, greaterThanOrEqualTo(0));
        expect(removeAt, lessThan(revokeAt),
            reason: '★ 必须**先**踢出配对表（后续命令立刻被准入拒掉）、'
                '**再**清在途作业。反了就会出现窗口期：在途已停，'
                '但对方在这个空档又下发了一条新命令并被放行');
      }
    });

    test('UR-23 onPeerRevoked 真的被 await（不 fire-and-forget）', () {
      expect(
          RegExp(r'await\s+RcEndpointService\.instance\.onPeerRevoked\(')
              .hasMatch(dlSrc),
          isTrue);
      expect(
          RegExp(r'await\s+RcEndpointService\.instance\.onPeerRevoked\(')
              .hasMatch(rsSrc),
          isTrue);
    });

    test('UR-24 通话归属复用 CallService.peerDeviceId（不另存一份会漂移的状态）', () {
      final body = methodBody(source, 'Future<void> onPeerRevoked(');
      expect(body.contains('CallService.instance.peerDeviceId'), isTrue,
          reason: '_peer 会在通话唯一的收尾路径里被清空，天然不漂移；'
              '另存字段就要自己维护生命周期，是新的脚枪');
      expect(body.contains('decideRevokeCleanup('), isTrue,
          reason: '决策必须走判据（可穷举），不能在方法里手写 if');
    });

    test('UR-25 ★ 反退化：stop() 必须在 plan.stopScript 之下（不得无条件停）', () {
      final body = methodBody(source, 'Future<void> onPeerRevoked(');
      final guardAt = body.indexOf('if (plan.stopScript)');
      final stopAt = body.indexOf('RcScriptExecutor.instance.stop()');
      expect(guardAt, greaterThanOrEqualTo(0));
      expect(stopAt, greaterThan(guardAt),
          reason: '★ 无条件 stop() = 撤销任何设备都顺手掐掉别人的指令组');
      expect(body.contains('if (plan.hangUpCall)'), isTrue);
    });

    test('UR-26 无在途作业时不写审计（避免把日志刷成噪声）', () {
      final body = methodBody(source, 'Future<void> onPeerRevoked(');
      final emptyAt = body.indexOf('if (plan.isEmpty) return;');
      final logAt = body.indexOf('LogRepository(');
      expect(emptyAt, greaterThanOrEqualTo(0),
          reason: '必须有 isEmpty 早退：每次删设备都写一条"已终止在途"是假审计');
      expect(logAt, greaterThan(emptyAt),
          reason: '早退必须在写审计**之前**');
    });

    test('UR-27 指令组归属在 run() 之前落、之后清（无窗口期、无残留）', () {
      // BUG-121 把一次执行拆成「预占段 `_runScript`」+「实跑段
      // `_runClaimedScript`」：归属赋值跟着 `run()` 一起搬进了实跑段，
      // 而释放仍在 `_runScript` 的 finally 里（异常逃逸也要清）。
      final claim = methodBody(source, 'Future<void> _runClaimedScript(');
      final outer = methodBody(source, 'Future<void> _runScript(');
      final setAt = claim.indexOf('_activeScriptOwner = peer.deviceId;');
      final runAt = claim.indexOf('RcScriptExecutor.instance.run(');
      expect(setAt, greaterThanOrEqualTo(0), reason: '缺归属赋值');
      expect(runAt, greaterThan(setAt),
          reason: '★ 必须在 run() **之前**落归属：否则"已在跑但 owner 还是 null"'
              '这段窗口期里解除配对会漏掉它 —— 正是要修的形状');
      // 释放：外层 finally 里清空（正常返回 / 异常 / 被终止都要清）
      final finAt = outer.indexOf('finally');
      final clearAt = outer.indexOf('_activeScriptOwner = null;');
      expect(finAt, greaterThanOrEqualTo(0), reason: '预占段必须有 try/finally');
      expect(clearAt, greaterThan(finAt),
          reason: '结束（含被终止）后必须清空，否则下次撤销会误停别人的作业；'
              '且必须写在 finally 里，异常路径才不会留下残留归属');
      // 置位点唯一 —— 多一条路径就会绕开归属
      expect('_activeScriptOwner = peer.deviceId;'.allMatches(source).length, 1);
    });
  });
}
