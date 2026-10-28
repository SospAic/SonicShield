// GENERATED FILE —— 请勿手工编辑。改 lib/ 结构后跑：
//   dart run tool/gen_coverage_sentinel.dart
//
// 覆盖率哨兵：只 import、不调用。
//
// 作用：Dart 覆盖率只统计**运行期被加载过的库**，未被任何 import 触及的
// 文件在 lcov.info 里**完全不存在**（不计分子也不计分母）—— 于是"不测"
// 反而让覆盖率更好看。本文件让 `lib/` 下每个库都被加载，未执行的函数
// 自然记 `LH:0`，分母因此**完整且不可作弊**。
//
// 实测背景见 tool/gen_coverage_sentinel.dart 的文档注释。
// ignore_for_file: unused_import, depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sonic_shield/app.dart';
import 'package:sonic_shield/core/app_keys.dart';
import 'package:sonic_shield/core/constants.dart';
import 'package:sonic_shield/core/providers.dart';
import 'package:sonic_shield/core/router.dart';
import 'package:sonic_shield/core/theme.dart';
import 'package:sonic_shield/core/utils/endpoint_security.dart';
import 'package:sonic_shield/core/utils/random.dart';
import 'package:sonic_shield/core/widgets/number_field.dart';
import 'package:sonic_shield/core/widgets/section_scaffold.dart';
import 'package:sonic_shield/data/db/app_database.dart';
import 'package:sonic_shield/data/prefs/json_list_codec.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';
import 'package:sonic_shield/data/repositories/counter_plan_store.dart';
import 'package:sonic_shield/data/repositories/log_repository.dart';
import 'package:sonic_shield/data/repositories/occurrence_repository.dart';
import 'package:sonic_shield/data/repositories/task_repository.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/domain/models/condition.dart';
import 'package:sonic_shield/domain/models/counter_plan.dart';
import 'package:sonic_shield/domain/models/counter_plan_params.dart';
import 'package:sonic_shield/domain/models/task.dart';
import 'package:sonic_shield/domain/models/trigger.dart';
import 'package:sonic_shield/domain/models/tts_voice.dart';
import 'package:sonic_shield/domain/models/vibrate_caps.dart';
import 'package:sonic_shield/domain/scheduling/china_holidays.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_materializer.dart';
import 'package:sonic_shield/domain/scheduling/counter_plan_random.dart';
import 'package:sonic_shield/domain/scheduling/guard_orchestration.dart';
import 'package:sonic_shield/domain/scheduling/run_pause.dart';
import 'package:sonic_shield/domain/scheduling/schedule_engine.dart';
import 'package:sonic_shield/domain/scheduling/vibrate_resolve.dart';
import 'package:sonic_shield/features/dashboard/dashboard_screen.dart';
import 'package:sonic_shield/features/dashboard/quick_scripts_card.dart';
import 'package:sonic_shield/features/guard/guard_screen.dart';
import 'package:sonic_shield/features/guard/guard_toggle.dart';
import 'package:sonic_shield/features/local/local_section.dart';
import 'package:sonic_shield/features/logs/log_screen.dart';
import 'package:sonic_shield/features/logs/logs_section.dart';
import 'package:sonic_shield/features/remote/assist_host_screen.dart';
import 'package:sonic_shield/features/remote/assist_join_screen.dart';
import 'package:sonic_shield/features/remote/call_incoming_overlay.dart';
import 'package:sonic_shield/features/remote/call_screen.dart';
import 'package:sonic_shield/features/remote/device_list_screen.dart';
import 'package:sonic_shield/features/remote/multi_video_screen.dart';
import 'package:sonic_shield/features/remote/pair_qr_screen.dart';
import 'package:sonic_shield/features/remote/ptt_screen.dart';
import 'package:sonic_shield/features/remote/ptt_tab.dart';
import 'package:sonic_shield/features/remote/remote_console_tab.dart';
import 'package:sonic_shield/features/remote/remote_screen.dart';
import 'package:sonic_shield/features/remote/remote_scripts_tab.dart';
import 'package:sonic_shield/features/remote/remote_section.dart';
import 'package:sonic_shield/features/remote/remote_tasks_tab.dart';
import 'package:sonic_shield/features/remote/screen_viewer.dart';
import 'package:sonic_shield/features/remote/script_builder_screen.dart';
import 'package:sonic_shield/features/settings/evidence_screen.dart';
import 'package:sonic_shield/features/settings/settings_screen.dart';
import 'package:sonic_shield/features/sounds/sound_library_screen.dart';
import 'package:sonic_shield/features/stats/stats_screen.dart';
import 'package:sonic_shield/features/tasks/task_editor_screen.dart';
import 'package:sonic_shield/features/tasks/task_list_screen.dart';
import 'package:sonic_shield/main.dart';
import 'package:sonic_shield/remote/assist.dart';
import 'package:sonic_shield/remote/assist_host.dart';
import 'package:sonic_shield/remote/assist_join.dart';
import 'package:sonic_shield/remote/call_lifecycle.dart';
import 'package:sonic_shield/remote/call_media_profile.dart';
import 'package:sonic_shield/remote/call_permission.dart';
import 'package:sonic_shield/remote/call_service.dart';
import 'package:sonic_shield/remote/command_channel.dart';
import 'package:sonic_shield/remote/controller_service.dart';
import 'package:sonic_shield/remote/credential_sealer.dart';
import 'package:sonic_shield/remote/device_group.dart';
import 'package:sonic_shield/remote/endpoint_service.dart';
import 'package:sonic_shield/remote/guarded_dispatch.dart';
import 'package:sonic_shield/remote/inbound_seen_store.dart';
import 'package:sonic_shield/remote/kdf_salt_store.dart';
import 'package:sonic_shield/remote/multi_call_service.dart';
import 'package:sonic_shield/remote/node_catalog.dart';
import 'package:sonic_shield/remote/peer_key_store.dart';
import 'package:sonic_shield/remote/protocol.dart';
import 'package:sonic_shield/remote/rc_script.dart';
import 'package:sonic_shield/remote/remote_playback.dart';
import 'package:sonic_shield/remote/remote_store.dart';
import 'package:sonic_shield/remote/script_executor.dart';
import 'package:sonic_shield/remote/script_progress.dart';
import 'package:sonic_shield/remote/task_wire.dart';
import 'package:sonic_shield/services/background_engine.dart';
import 'package:sonic_shield/services/background_service_manager.dart';
import 'package:sonic_shield/services/condition_env.dart';
import 'package:sonic_shield/services/counter_plan_service.dart';
import 'package:sonic_shield/services/deepseek_service.dart';
import 'package:sonic_shield/services/device_name_service.dart';
import 'package:sonic_shield/services/evidence_files.dart';
import 'package:sonic_shield/services/export_crypto.dart';
import 'package:sonic_shield/services/holiday_update_service.dart';
import 'package:sonic_shield/services/native_bridge.dart';
import 'package:sonic_shield/services/neural_tts.dart';
import 'package:sonic_shield/services/notification_service.dart';
import 'package:sonic_shield/services/online_tts_client.dart';
import 'package:sonic_shield/services/permission_flow.dart';
import 'package:sonic_shield/services/playback_service.dart';
import 'package:sonic_shield/services/power_service.dart';
import 'package:sonic_shield/services/preset_import.dart';
import 'package:sonic_shield/services/ptt_stream_sink.dart';
import 'package:sonic_shield/services/reactive_counter_service.dart';
import 'package:sonic_shield/services/remote_tts_presets.dart';
import 'package:sonic_shield/services/retention_maintenance.dart';
import 'package:sonic_shield/services/run_master_service.dart';
import 'package:sonic_shield/services/sound_guard_service.dart';
import 'package:sonic_shield/services/tts_service.dart';
import 'package:sonic_shield/services/vibrate_session.dart';

void main() {
  // ① 分母自检：lib/ 现场枚举 vs 哨兵 import 列表，必须完全一致。
  //    ⚠️ 这条是**真锁**：新增 lib 文件却忘了刷新哨兵 → 直接红。
  test('COV-01 覆盖率哨兵覆盖 lib 下全部 .dart（分母完整性）', () {
    final src = File('test/coverage_sentinel_test.dart').readAsStringSync();
    final imported = RegExp(r"import 'package:sonic_shield/([^']+)';")
        .allMatches(src)
        .map((m) => 'lib/${m.group(1)}')
        .toSet();

    final onDisk = libDartFilesForTest().toSet();

    final missing = onDisk.difference(imported).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason: 'lib 下这些文件没有被哨兵 import，覆盖率分母会漏算它们：\n'
          '  ${missing.join('\n  ')}\n'
          '修复：dart run tool/gen_coverage_sentinel.dart',
    );

    final stale = imported.difference(onDisk).toList()..sort();
    expect(
      stale,
      isEmpty,
      reason: '哨兵引用了已不存在的文件（重命名/删除后没刷新）：\n'
          '  ${stale.join('\n  ')}\n'
          '修复：dart run tool/gen_coverage_sentinel.dart',
    );

    // 反向自检：确认扫描本身确实读到了东西。
    // 防"正则写错 → 两边都空 → 断言恒绿"这种**假锁**。
    expect(imported.length, greaterThan(50),
        reason: '哨兵 import 数异常（${imported.length}）—— 正则或路径可能写错了');
    expect(onDisk.length, greaterThan(50),
        reason: 'lib 枚举数异常（${onDisk.length}）—— 工作目录可能不对');
  });
}

/// 与 tool/gen_coverage_sentinel.dart 的 [libDartFiles] 同逻辑。
///
/// 这里**故意复制一份**而不是 import tool/ 下的脚本：
/// 测试不应依赖 `tool/` 的实现细节。两份各自独立，若哪天分叉，
/// COV-01 会因为"枚举结果对不上"而红 —— 这正是我们要的。
List<String> libDartFilesForTest() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path.replaceAll(r'\', '/'))
    .where((p) => p.endsWith('.dart'))
    .toList();
