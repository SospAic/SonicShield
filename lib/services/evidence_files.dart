import 'dart:io';

/// 一条录音取证文件的元数据。
class EvidenceFile {
  const EvidenceFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  /// 完整路径（导出/删除用）。
  final String path;

  /// 文件名（界面展示用）。
  final String name;

  /// 文件大小（字节）。
  final int sizeBytes;

  /// 最后修改时间（列表排序/展示用）。
  final DateTime modifiedAt;
}

/// 取证文件管理（P2-11；`docs/07` §4「数据生命周期」/ §5「备份与恢复」）。
///
/// ## 为什么需要
/// 引擎把取证录音写到应用私有目录（`evidence_*.evidence.m4a`，见
/// `background_engine.dart` 与 `endpoint_service.dart`），`docs/07` 承诺
/// **永不自动删除、提供手动清理与导出** —— 但此前没有任何应用内闭环：
/// 用户既看不到占了多少空间，也无法导出或清理。
///
/// ## 为什么抽成独立类
/// 与 [RetentionMaintenance] 同一理由：页面本身依赖真实平台目录与文件 I/O，
/// 宿主 widget 测试里跑不通；把「扫描 → 过滤 → 排序」「删除」抽成纯文件操作，
/// 就能在真实临时目录上断言**真的只认取证文件、只删指定的那一个**。
///
/// ## 边界
/// 只读/删**取证文件**（`*.evidence.m4a`）；绝不触碰其它文件，也**永不**被
/// 保留策略自动清理（与 `RetentionMaintenance` 的删除范围互斥，`docs/07` §4）。
class EvidenceStore {
  EvidenceStore({required this.directory});

  /// 取证文件所在目录（生产为应用文档目录，测试注入临时目录）。
  final Directory directory;

  /// 取证文件的扩展标记（`docs/06`/`docs/07`：`.evidence.m4a`）。
  static const String evidenceSuffix = '.evidence.m4a';

  /// 文件名是否是指纹取证文件（导出给测试/其它调用方复用同一判据）。
  static bool isEvidenceName(String name) => name.endsWith(evidenceSuffix);

  /// 列出目录里的取证文件，按**修改时间倒序**（最新在前）。
  ///
  /// 目录不存在时返回空表（首次运行尚无取证文件，不是错误）。
  Future<List<EvidenceFile>> list() async {
    if (!await directory.exists()) return const [];
    final out = <EvidenceFile>[];
    await for (final e in directory.list(followLinks: false)) {
      if (e is! File) continue;
      final name = baseName(e.path);
      if (!isEvidenceName(name)) continue;
      final st = await e.stat();
      out.add(EvidenceFile(
        path: e.path,
        name: name,
        sizeBytes: st.size,
        modifiedAt: st.modified,
      ));
    }
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  /// 删除一条取证文件（手动清理）。文件已不存在时视为成功（幂等）。
  ///
  /// ⚠️ 只允许删除**取证文件**：`docs/07` §4 明写「绝不触碰其它文件」。
  /// 传进来的若不是 `*.evidence.m4a`，直接 `ArgumentError` —— 调用方传错路径
  /// 是编程错误，**必须炸出来**，绝不能静默删掉用户别的重要文件。
  Future<void> delete(String path) async {
    final name = baseName(path);
    if (!isEvidenceName(name)) {
      throw ArgumentError.value(
          path, 'path', '只允许删除取证文件（$evidenceSuffix）');
    }
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  /// 取路径最后一段（文件名），跨平台兼容 `/` 与 `\` 分隔。
  static String baseName(String path) {
    final segs = File(path).uri.pathSegments;
    return segs.isEmpty ? path : segs.last;
  }
}