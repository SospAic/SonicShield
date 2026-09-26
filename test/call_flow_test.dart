import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';

import 'support/source_text.dart';

/// **通话"点了没反应"（BUG-D）的回归锁。**
///
/// ## 真机症状
///
/// 发起视频/语音通话 —— **两端都无反应**。逐环节读代码后确证的是**四件事**，
/// 每一件单独都足以让通话不可用，且每一件都是**静默**的：
///
/// | # | 缺陷 | 静默之处 |
/// |---|---|---|
/// | 1 | 主叫点下按钮后 `pushNamed('/remote/call/in-call')` —— 该路由**从未声明**（`router.dart` 只有 `/remote/call`），而 go_router 的 Navigator 用 `pages:` 构建、**没有** `onGenerateRoute` ⇒ 当场抛异常 | 异常发生在 async 回调里 → 用户看到的只是"界面毫无变化" |
/// | 2 | `onCandidate` 用 `_pc == null` 直接 return ⇒ **早到的 ICE 候选被全部丢弃**（被叫手动接听时，振铃期间到达的候选全丢；主叫的 gathering 早已结束、不会补发） | 表现为"接通了但没画面没声音" |
/// | 3 | `_sendCallMsg` 丢弃 `sendTo` 的返回值 ⇒ `call.answer` 发不出去时被叫照样"接通成功"，主叫一路等到 45s 报"对方无应答" | 把"网络故障"误报成"没人接"（成功/失败双向失真） |
/// | 4 | 没有任何音频路由设置 ⇒ Android 把通话声音送**听筒**；且发起前不校验权限、失败文案一锅端 | "听不到"被当成"功能坏了" |
///
/// 本文件同时锁两层：
/// 1. **判定逻辑本身**（`call_lifecycle.dart` 的纯函数，宿主机可断言）；
/// 2. **接线**（服务/界面真的用了它）—— 否则纯逻辑可以"全绿但没人调用"，
///    那正是本项目最熟悉的那类假绿。
void main() {
  /// 剥掉行注释后再断言（注释掉的代码不算数 —— 本项目踩过）。
  String code(String src) => src.split('\n').map((l) {
        final i = l.indexOf('//');
        return i < 0 ? l : l.substring(0, i);
      }).join('\n');


  late String lifecycle;
  late String callService;
  late String callScreen;

  setUpAll(() {
    File read(String p) {
      final f = File(p);
      if (!f.existsSync()) {
        throw StateError('找不到 $p（cwd=${Directory.current.path}）');
      }
      return f;
    }

    lifecycle = code(read('lib/remote/call_lifecycle.dart').readAsStringSync());
    callService = code(read('lib/remote/call_service.dart').readAsStringSync());
    callScreen =
        code(read('lib/features/remote/call_screen.dart').readAsStringSync());
  });

  // =====================================================================
  // 1 · 发起呼叫的前置拦截（失败必须可诊断）
  // =====================================================================

  group('CF 发起呼叫的拦截与文案', () {
    test('CF-01 麦克风被拒一律拦下（语音呼叫也不例外 —— 没麦克风等于假成功）', () {
      expect(
        callStartBlockFor(micGranted: false, cameraGranted: true, video: true),
        CallStartBlock.micDenied,
      );
      expect(
        callStartBlockFor(micGranted: false, cameraGranted: false, video: false),
        CallStartBlock.micDenied,
        reason: '语音呼叫也要麦克风；放行等于让用户接起一通"对方听不到我"的电话',
      );
    });

    test('CF-02 视频呼叫且相机被拒 → cameraDenied', () {
      expect(
        callStartBlockFor(micGranted: true, cameraGranted: false, video: true),
        CallStartBlock.cameraDenied,
      );
    });

    test('CF-03 【不得把可用功能拦下】语音呼叫不看相机', () {
      expect(
        callStartBlockFor(micGranted: true, cameraGranted: false, video: false),
        isNull,
        reason: '相机被拒就把语音呼叫拦掉 = 把能用的功能报成不能用',
      );
    });

    test('CF-04 权限齐全 → 放行', () {
      expect(
        callStartBlockFor(micGranted: true, cameraGranted: true, video: true),
        isNull,
      );
      expect(
        callStartBlockFor(micGranted: true, cameraGranted: true, video: false),
        isNull,
      );
    });

    test('CF-05 每个拦截原因都有非空、互不相同的可执行文案', () {
      final texts = <String>[];
      for (final b in CallStartBlock.values) {
        final t = callStartBlockText(b);
        expect(t, isNotEmpty, reason: '$b 没有文案');
        expect(t.length, greaterThan(10),
            reason: '$b 的文案说不清"缺什么/下一步怎么办"（BUG-D 就是不可诊断）');
        texts.add(t);
      }
      expect(texts.toSet().length, CallStartBlock.values.length,
          reason: '有两个拦截原因显示了同一句话：$texts');
    });

    test('CF-06 源码锁：文案是穷尽 switch 表达式（不得有兜底分支）', () {
      final fn = lifecycle.substring(lifecycle.indexOf('String callStartBlockText'));
      final body = fn.substring(0, fn.indexOf(';'));
      expect(body.contains('_ =>'), isFalse,
          reason: '`_ =>` 兜底会静默吃掉新增的拦截原因（BUG-058 同形状）');
      expect(body.contains('default:'), isFalse);
      // 反向自检：抓不到东西说明锁本身失效了。
      expect(body.contains('CallStartBlock.endpointOffline'), isTrue);
    });

    test('CF-07 源码锁：startCall 的每条失败路径都必须说明原因', () {
      final body = methodBody(callService, 'Future<String?> startCall(');
      for (final b in [
        'CallStartBlock.alreadyInCall',
        'CallStartBlock.mediaFailed',
        'CallStartBlock.offerFailed',
        'CallStartBlock.endpointOffline',
      ]) {
        expect(body, contains(b),
            reason: 'startCall 少了 `$b` —— 调用方只能显示一句不可执行的兜底文案');
      }
      // 每一条 `return null` 之前都必须先登记原因。
      final returns = RegExp(r'return null;').allMatches(body).length;
      final assigns =
          RegExp(r'_lastStartBlock = CallStartBlock\.').allMatches(body).length;
      expect(assigns, returns,
          reason: '`return null`($returns 处) 与登记原因($assigns 处) 数量不等 —— '
              '有失败路径在静默返回');
    });

    test('CF-08 源码锁：空 SDP 不得当成"已发出"（假成功会让主叫白等 45s）', () {
      final body = methodBody(callService, 'Future<String?> startCall(');
      expect(body, contains('sdp.isEmpty'),
          reason: '空 SDP 的 invite 一定协商失败；必须在本地当场判失败');
    });

    test('CF-09 源码锁：界面按 lastStartBlock 给精确文案，且不得再有"一锅端"兜底', () {
      expect(callScreen, contains('lastStartBlock'),
          reason: '不读原因就只能是"权限或离线"那种不可执行的话');
      expect(callScreen, contains('callStartBlockText'),
          reason: '文案必须取自纯逻辑，不得在界面里另写一套');
      expect(callScreen, isNot(contains('权限或端点离线')),
          reason: '把四种原因压成一句 = 把可诊断的失败重新变成不可诊断（BUG-D）');
    });
  });

  // =====================================================================
  // 2 · ICE candidate 的到达时序（早到必须缓存 + 重放）
  // =====================================================================

  group('CF ICE candidate 时序', () {
    test('CF-10 只有"PC 就绪 + 远端描述已设置"才可直接投递', () {
      expect(
        candidateDeliverable(pcReady: true, remoteDescriptionSet: true),
        isTrue,
      );
      for (final combo in [
        (true, false),
        (false, true),
        (false, false),
      ]) {
        expect(
          candidateDeliverable(
              pcReady: combo.$1, remoteDescriptionSet: combo.$2),
          isFalse,
          reason: 'WebRTC 硬要求：addCandidate 必须在 setRemoteDescription 之后；'
              '这一组合必须走缓存而不是直接喂',
        );
      }
    });

    test('CF-11 缓存上限存在且非零（无界缓存会被对端刷爆内存）', () {
      expect(maxBufferedCandidates, greaterThan(0));
    });

    test('CF-12 【核心锁】onCandidate 不得在 `_pc == null` 时直接丢弃候选', () {
      final body = methodBody(callService, 'Future<void> onCandidate(');
      expect(body, contains('candidateDeliverable('),
          reason: '可投递判定必须走纯逻辑');
      expect(body, contains('_bufferCandidate('),
          reason: '不能立刻投递的候选必须**缓存**：直接丢弃就是 BUG-D 的真因 '
              '（被叫手动接听时振铃期间的候选全丢 → ICE 永不完成）');
      expect(body.contains('_pc == null) return'), isFalse,
          reason: '`_pc == null` 直接 return = 静默丢候选，禁止复活');
    });

    test('CF-13 【核心锁】重放必须发生在 setRemoteDescription 之后（两条路径都要）', () {
      final caller = methodBody(callService, 'Future<void> onAnswer(');
      expect(caller, contains('_flushPendingCandidates()'),
          reason: '主叫：被叫的候选在 answer 之前就发出，必须在这里补喂');
      final callee = methodBody(callService, 'Future<bool> acceptIncoming(');
      expect(callee, contains('_flushPendingCandidates()'),
          reason: '被叫：振铃期间缓存的候选必须在这里补喂');
      for (final body in [caller, callee]) {
        final desc = body.indexOf('setRemoteDescription');
        final flush = body.indexOf('_flushPendingCandidates()');
        expect(desc >= 0 && flush > desc, isTrue,
            reason: '重放必须在 setRemoteDescription **之后**（顺序反了候选会被平台拒绝）');
      }
    });

    test('CF-14 会话收尾必须清缓存；而 `_createPc` **不得**清（那会把修复原地抵消）', () {
      final teardown = methodBody(callService, 'Future<void> _teardown(');
      expect(teardown, contains('_pendingCandidates.clear()'),
          reason: '不清缓存 → 下一通会把上一通的候选喂给新连接（连错人）');
      expect(teardown, contains('_remoteDescSet = false'));

      final create = methodBody(callService, 'Future<void> _createPc(');
      expect(create, contains('_remoteDescSet = false'),
          reason: '新 PeerConnection 的远端描述必然未设置');
      expect(create.contains('_pendingCandidates.clear()'), isFalse,
          reason: '被叫的 `_pc` 要到用户点「接听」才创建，而候选在**振铃期间**'
              '就已进缓存 —— 在 `_createPc` 里清掉等于把 BUG-D 原样复现。'
              '缓存的生命周期是一次会话，只能由 `_teardown`/会话起点清空。');
    });
  });

  // =====================================================================
  // 3 · 信令发送失败不得被当成成功
  // =====================================================================

  group('CF 信令发送失败必须可见', () {
    test('CF-20 源码锁：_sendCallMsg 必须返回发送结果（不得吞掉 sendTo 的返回值）', () {
      expect(callService, contains('Future<bool> _sendCallMsg('),
          reason: '返回 void 就没法判断"发没发出去"，BUG-D 的误报就是这样来的');
    });

    test('CF-21 【核心锁】call.answer 发不出去时必须当场收场并告知', () {
      final body = methodBody(callService, 'Future<bool> acceptIncoming(');
      expect(body, contains('if (!sent)'),
          reason: 'answer 发失败却继续"接通成功" → 主叫等到 45s 报"对方无应答"');
      expect(body, contains('_teardown(reason: CallEndReason.failed)'),
          reason: '失败必须给出用户可见的结束原因（失败路径不得静默）');
    });

    test('CF-22 源码锁：候选发送不得再用 catchError 空处理器（bool 化后的类型陷阱）', () {
      expect(callService.contains('.catchError((Object _) {})'), isFalse,
          reason: '`Future<bool>.catchError` 的处理器必须返回 bool；'
              '空处理器会在**出错时**再抛 TypeError');
      expect(callService, contains('_sendLocalCandidate'),
          reason: '候选发送要有一个可 await、可 try/catch 的出口');
    });
  });

  // =====================================================================
  // 4 · 免提音频路由 / 主叫可见性 / 未知路由
  // =====================================================================

  group('CF 免提与主叫可见性', () {
    test('CF-30 源码锁：通话要显式打开免提扬声器，并在收尾时归位', () {
      expect(callService, contains('_setSpeakerphone(true)'),
          reason: '不切扬声器 → Android 走听筒 → 用户听到"没有声音"');
      expect(callService, contains('_setSpeakerphone(false)'),
          reason: '不归位 → 通话结束后整个应用的媒体播放仍走扬声器');
      expect(callService, contains('Helper.setSpeakerphoneOn'),
          reason: '必须真的调平台接口，不能只是注释里写着"免提"');
    });

    test('CF-31 【核心锁】界面不得 push 一个不存在的路由（go_router 没有 onGenerateRoute）', () {
      expect(callScreen, isNot(contains('pushNamed')),
          reason: '`/remote/call/in-call` 从未声明过；go_router 的 Navigator 用 '
              '`pages:` 构建、没有 onGenerateRoute ⇒ pushNamed 当场抛异常，'
              '用户看到的就是"点了按钮什么都没发生"（BUG-D）');
    });

    test('CF-32 【类锁】lib/ 下任何 `pushNamed` 都必须被判红', () {
      // ⚠️ 必须先剥注释再扫：本项目**故意**在注释里写下这条禁令与它的原因
      // （`call_screen.dart` 里就有 "不再 Navigator.pushNamed(...)"），
      // 直接 contains 会把那段说明当成违规 → 恒红。剥注释是这里的关键，
      // 不是可选项（`code()` 的由来见文件头）。
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (code(e.readAsStringSync()).contains('pushNamed(')) {
          offenders.add(e.path.replaceAll(r'\', '/'));
        }
      }
      expect(offenders, isEmpty,
          reason: '本项目用 go_router（声明式 `pages:`，无 onGenerateRoute）：'
              '`Navigator.pushNamed` 在**任何**位置都会抛异常。'
              '要跳转请用 `context.push/go`，且目标必须在 `core/router.dart` 声明。'
              '违规文件：$offenders');
    });

    test('CF-33 【核心锁】主叫的 connecting 阶段必须有界面 + 挂断入口', () {
      expect(callScreen, contains('CallPhase.connecting'),
          reason: '主叫阶段是 connecting；不渲染它 = 主叫全程看不到任何反馈');
      expect(callScreen, contains('connectingText('),
          reason: '文案取自纯逻辑（ringing → "对方振铃中…"），'
              '让用户能区分"对方在响"与"信令没送到"');
      expect(callScreen, contains('hangUp'),
          reason: '没有挂断入口，用户在这 45s 里无法取消呼叫');
    });

    test('CF-34 源码锁：发起前必须先要权限并**校验结果**（不得等 getUserMedia 失败）', () {
      final body = methodBody(callScreen, 'Future<void> _call(');
      expect(body, contains('.request()'),
          reason: '发起前不请求权限 → 用户先看到"呼叫失败"却不知道是权限问题');
      expect(body, contains('callStartBlockFor('),
          reason: 'request 的结果必须被判定，不得丢弃（BUG-062 同形状）');
      expect(body, contains('callStartBlockText('),
          reason: '被拦下时必须给出具体原因');
    });

    test('CF-35 源码锁：被叫的自动接通开关判定不得被绕过（BUG-056 不回潮）', () {
      expect(callService, contains('calleeActionFor('),
          reason: '"开关关闭 ⇒ 只振铃、绝不自动接通"这条隐私规则必须继续生效');
      expect(callScreen, contains('autoAnswerBlockFor('),
          reason: 'BUG-062 的权限判定必须留在界面上（AAP-07 也锁这一条）');
    });
  });
}
