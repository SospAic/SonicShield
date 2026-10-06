import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_shield/data/repositories/api_config_store.dart';

/// [ApiConfigStore] 的**默认值与清除**回归锁（计划第 23 条）。
///
/// 锁的不是"读到了值"，而是四条容易被后续重构悄悄改坏的**约定**：
/// 1. 未配置 / 空串都收敛成**可直接用**的默认值（调用点无需到处写 `??`）；
/// 2. `chatCompletionsUrl` 无论基址带几个尾斜杠都拼成**唯一**合法端点；
/// 3. DeepSeek Key 有**内置默认**（开箱可用），但可被显式清空/改写 —— 即
///    "默认"必须始终可覆盖，绝不能退化成写死不可变；
/// 4. `clearAll` 后基址/模型/Key 各自回到**内置默认**、在线语音回到**内置默认**
///    （内置免 Key 端点，出厂可用）。
void main() {
  Future<ApiConfigStore> fresh([Map<String, Object>? seed]) async {
    SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
    return ApiConfigStore(await SharedPreferences.getInstance());
  }

  group('API 接口配置默认值与清除', () {
    test('AC-01 未配置时回落到 DeepSeek 官方默认值', () async {
      final s = await fresh();
      expect(s.baseUrl, ApiConfigStore.defaultBaseUrl);
      expect(s.model, ApiConfigStore.defaultModel);
      expect(s.apiKey, ApiConfigStore.defaultApiKey);
      expect(s.hasApiKey, isTrue,
          reason: '出厂即内置默认 Key（开箱可用；可编译期 --dart-define 或运行期改写）');
      expect(s.chatCompletionsUrl,
          '${ApiConfigStore.defaultBaseUrl}/chat/completions');
    });

    test('AC-02 空串/纯空白 → 回到默认（语义等同"用默认"）', () async {
      final s = await fresh();
      await s.setBaseUrl('   ');
      await s.setModel('');
      expect(s.baseUrl, ApiConfigStore.defaultBaseUrl);
      expect(s.model, ApiConfigStore.defaultModel);

      // apiKey 不同：显式保存空串 = "停用内置默认"，如实回到无 Key。
      await s.setApiKey('  ');
      expect(s.apiKey, '');
      expect(s.hasApiKey, isFalse);
    });

    test('AC-03 自定义基址（含尾斜杠）拼出的端点唯一且合法', () async {
      final s = await fresh();
      // baseUrl 原样保留（仅去首尾空白），归一化只发生在 chatCompletionsUrl。
      for (final raw in [
        'https://x.example.com',
        'https://x.example.com/',
        'https://x.example.com///',
      ]) {
        await s.setBaseUrl(raw);
        expect(s.baseUrl, raw, reason: 'baseUrl 原样保留');
        expect(s.chatCompletionsUrl, 'https://x.example.com/chat/completions',
            reason: '尾斜杠必须被归一化，避免出现 //chat/completions');
      }
    });

    test('AC-04 hasApiKey 只认非空白', () async {
      final s = await fresh();
      await s.setApiKey('sk-abc');
      expect(s.hasApiKey, isTrue);
      await s.setApiKey('   ');
      expect(s.hasApiKey, isFalse);
    });

    test('AC-05 在线语音：内置免 Key 端点即可用；REST 端点需 Key；空端点=关闭', () async {
      final s = await fresh();
      // 出厂内置默认 = 免 Key（ws/wss）端点 → 开箱即用。
      expect(s.ttsEndpoint, ApiConfigStore.defaultTtsEndpoint);
      expect(s.onlineTtsConfigured, isTrue,
          reason: '内置免 Key 端点（ws/wss）无需 Key 即可用');

      // 改成 Azure 兼容 REST：有端点但没 Key → 不可用。
      await s.setOnlineTts(endpoint: 'https://r.tts.example/v1', apiKey: '');
      expect(s.onlineTtsConfigured, isFalse, reason: 'REST 端点缺 Key 不算已配置');

      // 只有 Key、没端点 → 也不可用。
      await s.setOnlineTts(endpoint: '', apiKey: 'k');
      expect(s.onlineTtsConfigured, isFalse, reason: '没有端点不算已配置');

      // REST 端点 + Key → 可用（两端空白被裁剪）。
      await s.setOnlineTts(endpoint: ' https://r.tts.example/v1 ', apiKey: ' k ');
      expect(s.ttsEndpoint, 'https://r.tts.example/v1');
      expect(s.ttsApiKey, 'k');
      expect(s.onlineTtsConfigured, isTrue);

      // 显式清空端点 = 关闭（不再回落内置默认）。
      await s.setOnlineTts(endpoint: '', apiKey: '');
      expect(s.ttsEndpoint, '');
      expect(s.onlineTtsConfigured, isFalse, reason: '清空端点即关闭在线语音');
    });

    test('AC-06 clearAll 回到内置默认（含在线语音回到内置免 Key 端点）', () async {
      final s = await fresh();
      await s.setBaseUrl('https://custom.example');
      await s.setApiKey('sk-abc');
      await s.setModel('deepseek-reasoner');
      await s.setOnlineTts(endpoint: 'https://r.tts.example/v1', apiKey: 'k');
      expect(s.apiKey, 'sk-abc');
      expect(s.hasApiKey, isTrue);
      expect(s.onlineTtsConfigured, isTrue);

      await s.clearAll();

      expect(s.baseUrl, ApiConfigStore.defaultBaseUrl);
      expect(s.model, ApiConfigStore.defaultModel);
      expect(s.apiKey, ApiConfigStore.defaultApiKey,
          reason: '清除后 Key 回到内置默认（而非留空）');
      expect(s.hasApiKey, isTrue);
      expect(s.ttsEndpoint, ApiConfigStore.defaultTtsEndpoint,
          reason: '清除后在线语音回到内置默认端点');
      expect(s.onlineTtsConfigured, isTrue,
          reason: '内置免 Key 端点出厂可用；要停用须显式 setOnlineTts("", "")');
    });

    test('AC-07 从既有持久化值读取（模拟重启后仍生效）', () async {
      final s = await fresh({
        'api_base_url': 'https://custom.example/',
        'api_model': 'deepseek-chat',
        'api_key': 'sk-persist',
        'tts_endpoint': 'https://r.tts.example/v1',
        'tts_api_key': 'k2',
      });
      expect(s.baseUrl, 'https://custom.example/');
      expect(s.chatCompletionsUrl, 'https://custom.example/chat/completions');
      expect(s.hasApiKey, isTrue);
      expect(s.onlineTtsConfigured, isTrue);
    });

    test('AC-08 内置默认可改写、可停用（"默认"不等于"写死"）', () async {
      final s = await fresh();
      expect(ApiConfigStore.defaultApiKey, isNotEmpty,
          reason: '出厂默认必须非空（开箱可用）');

      await s.setApiKey('sk-mine');
      expect(s.apiKey, 'sk-mine', reason: '运行期改写优先于内置默认');
      expect(s.hasApiKey, isTrue);

      await s.setApiKey('');
      expect(s.apiKey, '', reason: '显式停用后不回落到内置默认');
      expect(s.hasApiKey, isFalse);

      await s.setApiKey('sk-again');
      expect(s.apiKey, 'sk-again', reason: '停用后可再次启用');
    });
  });
}