<!-- 本模板的「测试质量自检」勾选项由 docs/17 §100.2（A15 立规）钉住。 -->

## 变更摘要

<!-- 一两句话说明「为什么」，而不是「做了什么」。 -->

## 变更类型

- [ ] 产品代码（`lib/**`）
- [ ] 测试代码（`test/**`）
- [ ] 文档（`docs/**` / `README` / `HANDOVER` / `CHANGELOG`）
- [ ] 原生层（`android/**` / `ios/**`）
- [ ] 门禁 / 工具链（`scripts/**` / `tool/**`）

## 测试质量自检（A15 立规，见 `docs/17 §100.2`）

- [ ] 若**新增/修改源码文本锁**（`methodBody` / `balancedSlice` / 文本断言）：**已同时提交反面样本用例**
      （故意把被锁源码改坏 ⇒ 该锁应判红，证明锁能抓到漂移，而非恒真；命名 `<锁前缀>-90a` / `-90b` …）
- [ ] 若断言源码文本：**已剥注释**（`stripComments`）后再断言，避免文档注释里的签名导致假红
- [ ] 硬编码缩进切片已改用 `test/support/source_text.dart` 公共 helper
- [ ] 若本 PR 提升覆盖率：**已同步抬高 ratchet**（`COVERAGE_MIN` / `MIN_COVERED` **三处同步**：
      `scripts/gates.sh` + `scripts/gates.ps1` + `CHANGELOG` 已知限制段）

## 门禁

- [ ] `flutter analyze` 零问题
- [ ] `flutter test --exclude-tags perf` 全绿
- [ ] `flutter test --tags perf --concurrency=1` 全绿
- [ ] 覆盖率 ratchet 通过（可测面 ≥ `COVERAGE_MIN` 且 ≥ `MIN_COVERED`）
- [ ] 机器锁全绿（`test/doc_gate_consistency_test.dart` 等）

## 文档同步（若升级基线）

- [ ] `docs/12` / `docs/17` 新节 + `HANDOVER` ★ 块 + `CHANGELOG` 首条已加
- [ ] 7 落点（`README` / `docs/00` / `docs/09` / `docs/21` / `docs/22` / `HANDOVER` / `CHANGELOG` 已知限制段）
      已**逐位**回刷绝对分数（百分比相同、数字不同 ⇒ `DGC` 抓不到，须人工核对）