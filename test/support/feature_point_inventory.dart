// ignore_for_file: avoid_print
/// **全功能点测试用例库（追溯矩阵）** —— `docs/02-需求规格说明书.md` 的
/// 全部 FR/NFR 编号 → 现有可执行用例 / 人工验收用例 / 已被取代项。
///
/// ## 为什么需要它
///
/// 需求规格里 61 个功能点，此前**没有任何机器可判的追溯**：
/// 用例散在 160+ 个测试文件里，"某功能点到底有没有用例"只能靠人肉记忆。
/// 一旦有人删掉/改名一个用例文件，或新增需求却忘了补用例，
/// **没有任何东西会报错** —— 这正是"测试覆盖率 100%"最容易变成口号的地方。
///
/// 本文件是矩阵的**唯一数据源**；判据与完整性校验在
/// `test/feature_point_coverage_lock_test.dart`（含反例，证明非恒真）。
///
/// ## 三类证据（诚实分类，不注水）
///
/// | 类别 | evidenceFile 前缀 | 含义 |
/// |---|---|---|
/// | host       | `test/`             | 宿主机单测，`flutter test` 可跑 |
/// | device     | `integration_test/` | 真机/模拟器集成用例（`flutter test integration_test/ -d`） |
/// | manual     | `docs/`             | **观测/现场型**指标（24h 长跑、内存/电量采样、iOS 走查、隐私代码审计），其验收标准本身要求人工/现场取证 |
/// | superseded | `docs/`             | 已被后续需求取代的需求项（不计入分母，须在文档里留下取代依据） |
///
/// `manual` **不是**"没测"：它是需求规格**自己写明**只能靠长跑/采样/审计验收的项
/// （见 docs/09 §4/§5、docs/02 各条验收标准）。把它们与自动化用例**分列**，
/// 是为了不把"人工观测"混进"自动化通过率"里造成虚高。
///
/// ## 不变量（由锁强制）
///
/// 1. 矩阵的编号集合 **必须与** `docs/02` 解析出的编号集合**完全相等**（无遗漏、无多出、无重复）；
/// 2. 每条证据的 `evidenceFile` 必须存在，且**确实包含** `token`（防止死链/改名后静默失效）；
/// 3. host/device 证据文件必须**含至少一条** `test(`/`testWidgets(`/`group(`（是真用例文件，不是空壳）；
/// 4. 非 superseded 功能点的覆盖率必须 = **100%**。
library;

/// 一个功能点的追溯条目。
class FeaturePoint {
  final String id; // 如 'FR-13' / 'NFR-04'
  final String name; // 一句话名称（≤30 字，便于人读）
  final String evidenceFile; // 证据文件（相对仓库根，正斜杠）
  final String token; // 必须出现在 evidenceFile 里的稳定标识串
  final bool superseded; // true = 已被后续需求取代（不计入覆盖率分母）
  final String note; // superseded / manual 的理由或人工验收口径

  const FeaturePoint(
    this.id,
    this.name, {
    required this.evidenceFile,
    required this.token,
    this.superseded = false,
    this.note = '',
  });
}

/// 追溯矩阵。编号集合必须与 `docs/02-需求规格说明书.md` 解析结果**逐字相等**。
const List<FeaturePoint> featurePoints = <FeaturePoint>[
  // ── 1.1 任务管理 ──────────────────────────────────────────────────────
  FeaturePoint('FR-01', '任务增删改启停与级联清理',
      evidenceFile: 'test/db_repository_test.dart', token: 'deleteForTask'),
  FeaturePoint('FR-02', '任务命名与音源池绑定（空池失败可见）',
      evidenceFile: 'test/task_editor_deep_test.dart', token: 'TEI-A2-4'),
  FeaturePoint('FR-03', '任务列表展示触发/动作/下次触发',
      evidenceFile: 'test/task_list_screen_test.dart', token: 'TLS-02b'),

  // ── 1.2 触发方式 ──────────────────────────────────────────────────────
  FeaturePoint('FR-10', 'fixedOnce 固定一次',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'TriggerType.fixedOnce'),
  FeaturePoint('FR-11', 'dailyAt 每日定时',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'TriggerType.dailyAt'),
  FeaturePoint('FR-12', 'weeklyAt 每周定时',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'TriggerType.weeklyAt'),
  FeaturePoint('FR-13', 'randomWindow 随机窗口',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'TriggerType.randomWindow'),
  FeaturePoint('FR-14', 'randomInterval 随机间隔',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'TriggerType.randomInterval'),
  FeaturePoint('FR-15', 'soundTriggered 声音触发',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'TriggerType.soundTriggered'),
  FeaturePoint('FR-16', '免打扰命中：skip / shift',
      evidenceFile: 'test/quiet_window_test.dart', token: 'resolveQuiet'),

  // ── 1.3 随机化 ────────────────────────────────────────────────────────
  FeaturePoint('FR-20', '随机时刻（窗口内均匀+最小间隔）',
      evidenceFile: 'test/schedule_engine_test.dart', token: 'sampleInWindow'),
  FeaturePoint('FR-21', '随机日期范围',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'DateRange'),
  FeaturePoint('FR-22', '随机时长 [min,max]',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'durationSecMin'),
  FeaturePoint('FR-23', '随机音量 [min,max]',
      evidenceFile: 'integration_test/fp_local_task_test.dart',
      token: 'volumeMin'),
  FeaturePoint('FR-24', '音源按权重随机',
      evidenceFile: 'test/schedule_engine_test.dart', token: 'pickWeighted'),
  FeaturePoint('FR-25', '确定性随机 seed=hash(taskId,日)',
      evidenceFile: 'test/schedule_engine_test.dart', token: 'planSeed'),

  // ── 1.4 动作 ──────────────────────────────────────────────────────────
  FeaturePoint('FR-30', 'playAudio 通道/淡入淡出/停止',
      evidenceFile: 'test/task_wire_test.dart', token: 'PlayAudioAction'),
  FeaturePoint('FR-31', 'tts 系统播报',
      evidenceFile: 'test/task_wire_test.dart', token: 'TtsAction'),
  FeaturePoint('FR-32', 'notify 系统通知',
      evidenceFile: 'test/task_wire_test.dart', token: 'NotifyAction'),
  FeaturePoint('FR-33', 'recordEvidence 录音取证',
      evidenceFile: 'test/task_wire_test.dart', token: 'RecordEvidenceAction'),
  FeaturePoint('FR-34', 'vibrate 固定节奏',
      evidenceFile: 'test/action_kind_coverage_test.dart', token: 'VibrateAction'),
  FeaturePoint('FR-35', 'composite 前缀通知+主动作',
      evidenceFile: 'test/task_wire_test.dart', token: 'CompositeAction'),
  FeaturePoint('FR-36', '随机振动（脉冲串，maxPulses）',
      evidenceFile: 'test/task_editor_vibrate_test.dart', token: 'maxPulses'),
  FeaturePoint('FR-37', '持续振动（渐强/渐弱/占空比）',
      evidenceFile: 'test/task_editor_vibrate_test.dart',
      token: 'continuousVibrate'),
  FeaturePoint('FR-38', '振动能力探测与降级提示',
      evidenceFile: 'test/task_editor_vibrate_test.dart', token: 'hasVibrator'),
  FeaturePoint('FR-39', '夜间独立豁免（双重开关）',
      evidenceFile: 'test/quiet_exempt_lock_test.dart', token: 'quietExempted'),
  FeaturePoint('FR-39a', '振动失效安全（四条可停路径）',
      evidenceFile: 'test/vibrate_session_test.dart', token: 'VibrateSession'),
  FeaturePoint('FR-39b', '全局执行总开关（节假日自动暂停）',
      evidenceFile: 'test/run_pause_test.dart', token: 'inWindow'),

  // ── 1.5 后台执行与电源管理 ────────────────────────────────────────────
  FeaturePoint('FR-40', '前台服务常驻+常驻通知',
      evidenceFile: 'test/foreground_service_lock_test.dart',
      token: 'foregroundServiceTypes'),
  FeaturePoint('FR-41', '精确闹钟看门狗',
      evidenceFile: 'test/android_compat_lock_test.dart',
      token: 'setExactAndAllowWhileIdle'),
  FeaturePoint('FR-42', '开机/升级自恢复',
      evidenceFile: 'test/android_compat_lock_test.dart', token: 'BootReceiver'),
  FeaturePoint('FR-43', '电池优化白名单与厂商自启动引导',
      evidenceFile: 'test/permission_flow_test.dart', token: '厂商自启动页'),
  FeaturePoint('FR-44', '电源模式三档+低电量降级',
      evidenceFile: 'test/cov_services_test.dart', token: 'PowerMode'),
  FeaturePoint('FR-45', 'iOS 前台/后台执行与通知兜底',
      evidenceFile: 'docs/20-振动能力设计（随机振动与持续振动）.md',
      token: 'FR-45',
      note: 'iOS 能力边界为 UI 走查项（docs/20 §12 明示 FR-45），'
          '本项目当前发布矩阵为 Android（docs/02 §3 平台约束），iOS 走查为人工验收'),

  // ── 1.6 声音守卫 ──────────────────────────────────────────────────────
  FeaturePoint('FR-50', '能量阈值检测（阈值/时长/冷却可配）',
      evidenceFile: 'test/sound_guard_lifecycle_test.dart', token: 'thresholdDb'),
  FeaturePoint('FR-51', '麦克风数据仅内存计算、不落盘不上传',
      evidenceFile: 'docs/08-合规与安全使用白皮书.md', token: '麦克风数据不落盘',
      note: '验收标准即"代码审计确认 + 隐私政策声明"（docs/02 FR-51），'
          '属隐私审计人工项，非可用例化断言替代'),
  FeaturePoint('FR-52', '守卫触发执行并留痕 source=sound',
      evidenceFile: 'test/execution_outcome_lock_test.dart', token: 'runGuardPlan'),
  FeaturePoint('FR-53', '仅充电时启用守卫',
      evidenceFile: 'test/guard_screen_test.dart', token: 'only_while_charging'),

  // ── 1.7 审计与合规 ────────────────────────────────────────────────────
  FeaturePoint('FR-60', '每次执行写日志',
      evidenceFile: 'test/db_repository_test.dart', token: 'LogRepository'),
  FeaturePoint('FR-61', '首次启动合规门',
      evidenceFile: 'test/dashboard_screen_test.dart',
      token: 'compliance_accepted_v1'),
  FeaturePoint('FR-62', '强制免打扰默认 22:00–07:00',
      evidenceFile: 'test/quiet_exempt_lock_test.dart',
      token: 'normalizeQuietWindow'),
  FeaturePoint('FR-63', '同任务最小冷却 ≥ 60s',
      evidenceFile: 'test/qz_sweep_data_test.dart', token: '最小冷却 60s'),

  // ── 1.8 执行条件 ──────────────────────────────────────────────────────
  FeaturePoint('FR-64', '仅充电时执行',
      evidenceFile: 'test/condition_test.dart', token: 'requireCharging'),
  FeaturePoint('FR-65', '最低电量阈值',
      evidenceFile: 'test/condition_test.dart', token: 'minBatteryPct'),
  FeaturePoint('FR-66', '每日时段窗口（含跨零点）',
      evidenceFile: 'test/condition_test.dart', token: 'windowStartMin'),
  FeaturePoint('FR-67', '仅 Wi-Fi 下执行',
      evidenceFile: 'test/condition_test.dart', token: 'requireWifi'),
  FeaturePoint('FR-68', '通话中不执行（默认开启）',
      evidenceFile: 'test/condition_test.dart', token: 'skipInCall'),
  FeaturePoint('FR-69', '条件无法判定按满足处理',
      evidenceFile: 'test/condition_env_test.dart', token: 'firstUnmetIn'),
  FeaturePoint('FR-70', '设置页 tab 分组（执行与护栏/保活与备份/语音与音色/数据与合规）',
      evidenceFile: 'test/settings_screen_test.dart', token: 'switchTab'),
  FeaturePoint('FR-71', '首页常驻全局执行总开关',
      evidenceFile: 'test/dashboard_screen_test.dart', token: 'DBS-15'),
  FeaturePoint('FR-72', '全局执行总开关支持远程控制（命令 + 回显 + 本机实时同步）',
      evidenceFile: 'test/remote_console_tab_test.dart', token: 'RCT-RM1'),
  FeaturePoint('FR-73', '远程连接方案可选 + 节点下拉 + 一键测速（TLS/WSS/QUIC）',
      evidenceFile: 'test/node_catalog_test.dart', token: 'NC-01'),
  FeaturePoint('FR-74', '首页全局执行开关与后台保活开关真实生效',
      evidenceFile: 'test/dashboard_screen_test.dart', token: 'DBS-15'),
  FeaturePoint('FR-75', '保活机制与反击策略分离可配置 + 默认自定义',
      evidenceFile: 'test/settings_screen_test.dart', token: 'switchTab'),
  FeaturePoint('FR-76', '远程界面从「一屏一堆」重构为「列表 + 点进去」',
      evidenceFile: 'test/remote_screen_test.dart', token: 'RRS-'),
  FeaturePoint('FR-77', '设备名称自定义 + 远端别名广播（别名只在本机显示）',
      evidenceFile: 'test/device_name_service_test.dart', token: 'DNS-01'),
  FeaturePoint('FR-78', '总执行开关从守卫页移至守护页 + 样式美化',
      evidenceFile: 'test/dashboard_screen_test.dart', token: 'DBS-RM-01'),
  FeaturePoint('FR-79', '远程控制台两行高命令行回执组件 + 去除逐动作反馈点',
      evidenceFile: 'test/remote_console_tab_test.dart', token: 'RCT-RC1'),
  FeaturePoint('FR-80', '反击计划独立成 TAB 页',
      evidenceFile: 'test/settings_screen_test.dart', token: 'switchTab'),
  FeaturePoint('FR-81', '版本号格式改为「版本号(当前日期)」并取消 alpha+N',
      evidenceFile: 'test/version_consistency_test.dart', token: 'pubspec 版本号不得含预发布后缀'),
  FeaturePoint('FR-82', '文件版本号与代码版本号强关联（机器锁兜底）',
      evidenceFile: 'test/version_consistency_test.dart', token: 'FR-82 文件版本引用一致性'),
  FeaturePoint('FR-83', '应用图标改为「用户拟定图标」样式（20 档 + 入库 + 可复现）',
      evidenceFile: 'test/app_icon_lock_test.dart', token: 'AIC-01'),
  FeaturePoint('FR-84', '性能优先档常驻唤醒锁 + 保活自检 + 精确闹钟强引导',
      evidenceFile: 'test/native_bridge_test.dart', token: 'setPersistentWakeLock'),

  // ── 2. 非功能需求 ─────────────────────────────────────────────────────
  FeaturePoint('NFR-01', '24h 执行成功率 ≥ 99%',
      evidenceFile: 'docs/09-测试计划与测试用例.md', token: 'LT-01',
      note: '长跑观测项（docs/09 §5 LT-01，3 台 × 24h），现场/长跑验收'),
  FeaturePoint('NFR-02', '进程被杀 60s 内看门狗恢复',
      evidenceFile: 'docs/09-测试计划与测试用例.md', token: 'ST-01',
      note: '现场项：`adb shell am kill` 后由精确闹钟重新拉起（docs/09 §4 ST-01）'),
  FeaturePoint('NFR-03', '常驻内存 ≤ 150MB',
      evidenceFile: 'docs/09-测试计划与测试用例.md', token: 'LT-03',
      note: '采样观测项：`dumpsys meminfo`（docs/09 §5 LT-03；docs/12 实测 97MB）'),
  FeaturePoint('NFR-04', '计划重算 ≤ 500ms（100 任务）',
      evidenceFile: 'integration_test/perf_nfr_test.dart', token: 'ScheduleEngine'),
  FeaturePoint('NFR-05', '后台日耗电 ≤ 3%',
      evidenceFile: 'docs/09-测试计划与测试用例.md', token: 'LT-04',
      note: '采样观测项：`batterystats` 24h（docs/09 §5 LT-04）'),
  FeaturePoint('NFR-06', 'Android 7.0–16 兼容',
      evidenceFile: 'test/android_compat_lock_test.dart', token: 'minSdk'),
  FeaturePoint('NFR-07', '全部数据本地、v1 不申请网络权限',
      evidenceFile: 'docs/17-接管审计与续作清单.md', token: 'NFR-07',
      superseded: true,
      note: '已被 v1.2 起的远程模块实质取代：远程控制/视频通话必需 INTERNET'
          '（主清单既有该权限），依据 docs/17 §一·02'),
  FeaturePoint('NFR-08', 'analyze 0 error / 覆盖达标',
      evidenceFile: 'test/coverage_sentinel_test.dart', token: 'COV-01'),
  FeaturePoint('NFR-09', '六页信息架构 + 创建引导',
      evidenceFile: 'test/router_test.dart', token: 'RTR-02'),
  FeaturePoint('NFR-10', '取证文件在私有目录且不入库',
      evidenceFile: 'test/evidence_files_test.dart', token: 'isEvidenceName'),
];