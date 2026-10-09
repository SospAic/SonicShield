import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/services/remote_tts_presets.dart';

/// 远程 TTS 喊话的 **5 个可自定义预置位**（RTP 系列）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RTP 远程 TTS 预置位', () {
    test('RTP-01 normalize：恰好 5 条、去空白、不足补默认', () {
      expect(RemoteTtsPresets.normalize(const []), RemoteTtsPresets.defaults);
      final out = RemoteTtsPresets.normalize(const ['  a ', '', '   ', 'b']);
      expect(out.length, RemoteTtsPresets.slotCount);
      expect(out[0], 'a');
      expect(out[1], 'b');
      expect(out.sublist(2), RemoteTtsPresets.defaults.sublist(0, 3));
    });

    test('RTP-02 normalize：超长截断、多于 5 条截断', () {
      final long = 'x' * (RemoteTtsPresets.maxLen + 10);
      final out =
          RemoteTtsPresets.normalize([long, '1', '2', '3', '4', '5', '6']);
      expect(out.length, RemoteTtsPresets.slotCount);
      expect(out.first.length, RemoteTtsPresets.maxLen);
    });

    test('RTP-03 read/write 往返（落 SharedPreferences）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      expect(RemoteTtsPresets.read(prefs), RemoteTtsPresets.defaults);
      await RemoteTtsPresets.write(prefs, const ['你好', '再见']);
      final got = RemoteTtsPresets.read(prefs);
      expect(got.length, RemoteTtsPresets.slotCount);
      expect(got[0], '你好');
      expect(got[1], '再见');
    });

    test('RTP-04 slotCount=5 且 defaults 有 5 条', () {
      expect(RemoteTtsPresets.slotCount, 5);
      expect(RemoteTtsPresets.defaults.length, 5);
    });
  });
}
