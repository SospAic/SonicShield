/// 源码契约锁的公共文本工具 —— **本项目唯一真源**（A11 系统性项，第 36 轮收敛）。
///
/// ## 为什么必须有一个公共实现
///
/// 本项目大量回归锁是「**源码契约锁**」：读 `lib/` 下的源码文本，断言某段接线
/// 存在 / 不存在（因为端点服务、平台通道、单例等在宿主机上**无法实例化**，
/// 只能用文本锁兜底 —— 这是权衡，不是理想解）。
///
/// 这类锁有一个共同的致命失效模式：**注释也能满足断言**。
///
/// | 断言方向 | 不剥注释的后果 |
/// |---|---|
/// | 存在性 `expect(src.contains('foo()'), isTrue)` | 注释里写一句 `// 这里应该调用 foo()` 就**喂绿** ⇒ 锁退化成恒真的装饰品 |
/// | 禁止性 `expect(src.contains('_ =>'), isFalse)` | 注释里写一句 `// 不要写 _ =>` 反而**判红** ⇒ 逼人删掉说明注释，锁变负资产 |
///
/// 所以：**任何读源码文本的锁，都必须先剥注释。**
///
/// ## 为什么收敛到本文件
///
/// 2026-09-26（第 36 轮）实测：`test/` 下曾散落 **16 份** `stripComments`
/// 实现，其中 **10 份逐字相同**、另 6 份是它的退化版（不认字符串字面量 /
/// 只认单引号 / 行级粗糙实现）。同一件事写 16 遍的代价是**修一处漏十五处** ——
/// 第 34/35 轮两次加固都只覆盖了被点名的那几个文件。
///
/// 从本文件起：新锁**一律 import 这里**，不要再复制粘贴。
///
/// ## 本文件的锁
///
/// 见 `test/support_source_text_test.dart`（STX 系列）。它含**反面样本**，
/// 用来证明这些函数不是恒真/恒假的（本项目强制要求：恒真断言 = 没测）。
library;

/// 剥掉行注释（`//`）、块注释（`/* ... */`）与 **XML 注释**（`<!-- ... -->`），
/// **保留字符串字面量整段**。
///
/// 为什么要保留字符串：字符串里的违规仍是**代码级**违规，必须被抓到。
/// 例如 `expect(src.contains("'1883'"), isFalse)` 这类"不得出现明文端口"
/// 的判据，若把字符串也剥掉，锁就永远绿了。
///
/// 为什么必须处理字符串：`'https://example.com'` 里的 `//` 不是注释开始。
/// 退化版实现会把这一行从 `//` 起截断 ⇒ 既可能假绿（截掉的正好是违规代码）
/// 也可能假红（截掉的是合法代码）。
///
/// 为什么必须处理 XML 注释：本项目刻意在 AndroidManifest / Info.plist 的注释里
/// **写明**"为什么不加某权限"（`docs/03 §5` 最小必要原则的决策留痕）。
/// 不剥 `<!-- -->` 的话，`contains()` 会把这段**说明文字**当成"权限已声明" ——
/// `rc_location_gate_test.dart` 的 LG-13 正是被这种假红教过的（其本地
/// `stripXmlComments` 与本分支同判据；按本文件纪律，新实现一律收敛到这里）。
/// 这类假红最坏的后果不是浪费时间，而是逼下一个人**删掉最有价值的注释**。
///
/// 转义（`\'` / `\"` / `\\`）按 Dart 规则处理；`r'...'` 原始字符串中的
/// 反斜杠**不是**转义符，但本函数只按字符流处理引号配对，对原始字符串的
/// 处理结果是"整段保留"（与目标一致），故不需要单独识别 `r` 前缀。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    // XML 注释（`<!-- ... -->`）：与块注释同理，未闭合时截到文件末尾而非抛错
    // （STX-07 同款纪律）。
    if (c == '<' &&
        i + 3 < src.length &&
        src[i + 1] == '!' &&
        src[i + 2] == '-' &&
        src[i + 3] == '-') {
      i += 4;
      while (i + 2 < src.length &&
          !(src[i] == '-' && src[i + 1] == '-' && src[i + 2] == '>')) {
        i++;
      }
      i += 3;
      continue;
    }
    if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length) {
        if (src[i] == r'\') {
          out.write(src[i]);
          i++;
          if (i < src.length) {
            out.write(src[i]);
            i++;
          }
          continue;
        }
        out.write(src[i]);
        if (src[i] == q) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取 `signature` 所指方法的**块体**（含两端大括号），按括号配对截取。
///
/// ## 支持的签名写法（**四种约定**，全部是本仓库实测在用的）
///
/// | 形态 | 例子 | 说明 |
/// |---|---|---|
/// | A 止于 `(` | `'Future<void> broadcast('` | 参数表交给本工具配对 |
/// | B1 含具名参数表开括号 | `'Future<void> _recordEvidence({'` | 参数表开括号在签名里 |
/// | B2 含函数体开括号 | `'Future<void> dispose() async {'` | 该 `{` 即函数体 |
/// | C 完整签名 | `'Future<void> _dispatch(RcMessage msg, PairedEndpoint peer)'` | 参数表已闭合 |
/// | D 完整签名 + `async` | `'Future<void> _connect() async'` | 同上 |
///
/// 也接受**多行签名的片段**（例：`'RcMessage request, {'` 对应
/// `endpoint_service.dart` 里 `requestPairing` 的跨行参数表）。
///
/// ## 为什么必须四种都认（**实测数据，不是推断**）
/// 全仓 76 个真实调用点的分布是 A 51 / B 9 / C 9 / D 7。若本实现只认 A，
/// 其余 **25 处会静默取错窗口** —— 不抛错、切片"平衡但错误"，断言仍可能
/// 碰巧通过（`_mbprobe_test.dart` 逐调用点对照实测：mismatches=25）。
/// 这正是 A10/A11 记录的同一类"静默失效"。
///
/// ## 契约（**唯一真源**，17/18 份本地副本已经就是这个契约）
/// * 返回**含两端大括号**的切片；
/// * 定位失败 / 括号不配对 / 表达式体 → **显式抛 [StateError]**，
///   绝不返回空串或"悄悄错掉的区间"。
///
/// 唯一的例外是 `playback_dispose_lock_test.dart` 的本地副本（返回**不含**
/// 大括号、失败返回 `''`）；它迁移到本函数时会连带收紧那一条守卫，
/// 属**有意**的行为变化，已在该文件内注明。
///
/// ⚠️ 为什么不能简单 `indexOf('{', start)`：签名只写到 `(` 时，那个 `{`
/// 命中的是**具名参数表**，配对结果是一个"平衡但错误"的切片。
///
/// ⚠️ 为什么不支持表达式体（`=>`）：本工具只服务块体。表达式体传入会
/// **显式抛错**，而不是返回一个悄悄错掉的区间。
///
/// 推荐先 `methodBody(stripComments(src), signature)`：剥注释后字符串里的
/// 大括号才不会污染配对。
String methodBody(String src, String signature) {
  final i = src.indexOf(signature);
  if (i < 0) throw StateError('找不到 `$signature`');

  // 1) 签名自身的括号配平。`sawParen` 用来区分
  //    「以 `{` 收尾的**函数体**」与「以 `{` 收尾的**具名参数表**」：
  //    前者前缀里一定有一个**配平**的 `(...)` 参数表，后者没有。
  var bal = 0;
  var sawParen = false;
  for (var j = 0; j < signature.length; j++) {
    final c = signature[j];
    if (c == '(') {
      bal++;
      sawParen = true;
    } else if (c == '[' || c == '{') {
      bal++;
    } else if (c == ')' || c == ']' || c == '}') {
      bal--;
    }
  }
  if (bal < 0) throw StateError('`$signature` 的括号不配平');

  // 2) 约定 B2：签名以 `{` 收尾，且其前缀含配平的参数表 ⇒ 那个 `{` 就是函数体。
  //    （例：'Future<void> dispose() async {'）
  if (signature.endsWith('{') && sawParen && bal == 1) {
    final s = balancedSlice(src, i + signature.length - 1);
    if (s == null) throw StateError('`$signature` 的函数体未闭合');
    return s;
  }

  // 3) 其余约定：从签名末尾之后扫，按 `bal` 跳过参数表，
  //    取第一个处于 depth 0 的 `{` 作为函数体起点。
  //
  //    ⚠️ `tolerant`：签名可能是**多行签名的片段**（例：`'RcMessage request, {'`
  //    取自 `requestPairing` 跨行的参数表）—— 这种情况下参数表的 `(` 根本不在
  //    签名里，`bal` 会**少算一层**，扫到参数表闭合的 `)` 时 depth 会下溢。
  //    判据：签名里一个 `(` 都没有（`sawParen == false`）⇒ 片段 ⇒ 夹到 0 继续。
  //    含 `(` 的签名仍保持严格，下溢即报错。
  final tolerant = !sawParen;
  var depth = bal;
  var paramEnd = depth == 0 ? i + signature.length : -1;
  for (var j = i + signature.length; j < src.length; j++) {
    final c = src[j];
    if (c == '{') {
      if (depth == 0) {
        // 参数表与函数体之间出现 `=>` ⇒ 表达式体，显式拒绝。
        final from = paramEnd < 0 ? j : paramEnd;
        if (src.substring(from, j).contains('=>')) {
          throw StateError('`$signature` 是表达式体，本工具只支持块体');
        }
        final s = balancedSlice(src, j);
        if (s == null) throw StateError('`$signature` 的函数体未闭合');
        return s;
      }
      depth++;
    } else if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0 && paramEnd < 0) paramEnd = j + 1;
      if (depth < 0) {
        if (tolerant) {
          depth = 0;
        } else {
          throw StateError('`$signature` 的参数表未闭合');
        }
      }
    }
  }
  throw StateError('`$signature` 没有函数体');
}

/// 从 [openIndex] 处的开括号起，返回**配对到闭合**的切片（含两端括号，
/// **不含**开括号之前的被调者名字 —— 调用方本来就知道自己在取谁的括号）。
///
/// [openIndex] 指向的字符必须是 `(` / `[` / `{` 之一；否则返回 `null`。
/// 未闭合返回 `null`（**调用方必须自己加哨兵**，不许把 `null` 当"扫到末尾"）。
///
/// 用途：替代 A10 点名的"朴素 `indexOf('{')` + 写死缩进右边界"切片法 ——
/// 那种写法失配时要么抛 `RangeError`（假红），要么静默取错区间（假绿）。
String? balancedSlice(String src, int openIndex) {
  if (openIndex < 0 || openIndex >= src.length) return null;
  final first = src[openIndex];
  if (first != '(' && first != '[' && first != '{') return null;
  var depth = 0;
  for (var i = openIndex; i < src.length; i++) {
    final c = src[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return src.substring(openIndex, i + 1);
    }
  }
  return null;
}

/// 取 `signature` 之后**第一个**开括号的配对切片（含括号，**不含**被调者名字）。
///
/// 找不到签名或括号不配对 → `null`。语义同 [balancedSlice]，只是省掉
/// 手工 `indexOf`。**调用方必须加哨兵**（`expect(x, isNotNull, reason: ...)`），
/// 否则"没找到"会静默变成"断言不成立"。
String? balancedSliceAfter(String src, String signature) {
  final i = src.indexOf(signature);
  if (i < 0) return null;
  final open = src.indexOf('(', i + signature.length - 1);
  if (open < 0) return null;
  return balancedSlice(src, open);
}
