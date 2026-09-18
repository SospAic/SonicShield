import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_shield/domain/models/action.dart';
import 'package:sonic_shield/services/playback_service.dart';

/// 音频焦点策略契约测试（v1.7）。
///
/// ## 为什么这条值得单独锁一个测试
///
/// 焦点类型藏在 `AudioSession.configure` 的参数里，**改错了不会编译报错、
/// 也不会运行期抛异常** —— 只会表现为"应用一放提示音，我的音乐就被打断"。
/// 这类回归没有任何自动化信号能捕获，除非把它抽成纯函数并断言。
///
/// 行业依据（Android 官方《管理音频焦点》）：
/// - 短暂的提示音应请求 `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`，
///   让其他应用**降低音量继续播放**而不是暂停；
/// - 只有闹钟类"必须被听见"的音频才应抢占（`AUDIOFOCUS_GAIN`）。
void main() {
  group('PB 音频焦点策略', () {
    test('PB-01 media 通道使用 mayDuck（不打断他人音乐）', () {
      expect(
        PlaybackService.focusGainFor(AudioChannel.media),
        AndroidAudioFocusGainType.gainTransientMayDuck,
      );
    });

    test('PB-02 alarm 通道使用抢占式 gain（必须被听见）', () {
      expect(
        PlaybackService.focusGainFor(AudioChannel.alarm),
        AndroidAudioFocusGainType.gain,
      );
    });

    test('PB-03 两个通道的焦点类型必须不同（否则媒体通道会打断音乐）', () {
      expect(
        PlaybackService.focusGainFor(AudioChannel.media),
        isNot(PlaybackService.focusGainFor(AudioChannel.alarm)),
      );
    });

    test('PB-04 不得对 media 使用永久性 gain', () {
      // 显式反例：这是本轮修正前的行为，锁定它不再回归。
      expect(
        PlaybackService.focusGainFor(AudioChannel.media),
        isNot(AndroidAudioFocusGainType.gain),
      );
    });
  });
}
