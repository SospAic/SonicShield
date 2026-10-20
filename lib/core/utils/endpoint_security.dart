/// 外部接口端点的**传输安全**判据（R90-08，2026-10-19）。
///
/// ## 为什么抽到 core
///
/// BUG-132 曾为「在线语音」建过同构判据（`isSecureTtsEndpoint`），但**只装在
/// TTS 通路上**。R90 审计发现 DeepSeek 通路（`Authorization: Bearer <key>`）
/// 完全没有这条闸：用户在设置里把基址填成 `http://…`，API Key 与提示词就明文
/// 上网。同一规则写在两个地方、只落在一处，是本轮缺陷的主线形态 —— 所以把
/// 判据收敛到**一个纯函数**，两条通路共用。
///
/// ## 判据
///
/// - `https` / `wss` 一律允许；
/// - 明文 `http` / `ws` **只**允许回环与 RFC1918 私有地址
///   （本机 / 家庭局域网自建服务是真实用法）；
/// - 其它（公网明文、无法解析、空 host）一律拒绝。
library;

/// 端点是否满足"携带凭据也不至于明文外泄"的最低要求。
bool isSecureEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint.trim());
  if (uri == null || uri.host.isEmpty) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https' || scheme == 'wss') return true;
  if (scheme != 'http' && scheme != 'ws') return false;
  return isLocalHost(uri.host);
}

/// 回环 / 私有网段判定（[isSecureEndpoint] 专用，公开以便单测穷举）。
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]') {
    return true;
  }
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  if (a == 127) return true; // 回环
  if (a == 10) return true; // 10/8
  if (a == 192 && b == 168) return true; // 192.168/16
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16/12
  return false;
}
