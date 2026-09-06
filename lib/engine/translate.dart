// 自由文本翻译：MyMemory 免费 API + 缓存 + 静默降级（纯 Dart）
import 'dart:convert';

import 'package:http/http.dart' as http;

final Map<String, List<Object>> _cache = {}; // key -> [expiryMs, text]
const _ttlOk = 24 * 3600 * 1000;
const _ttlFail = 10 * 60 * 1000;

Future<String> translateZhTo(String text, String target) async {
  if (text.isEmpty) return '';
  final key = '$text|$target';
  final now = DateTime.now().millisecondsSinceEpoch;
  final hit = _cache[key];
  if (hit != null && (hit[0] as int) > now) return hit[1] as String;
  try {
    final r = await http
        .get(Uri.https('api.mymemory.translated.net', '/get',
            {'q': text, 'langpair': 'zh-CN|$target'}))
        .timeout(const Duration(seconds: 6));
    if (r.statusCode == 200) {
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final out = ((d['responseData'] ?? {}) as Map)['translatedText'] ?? '';
      if (out is String && out.isNotEmpty && !out.toUpperCase().contains('MYMEMORY WARNING')) {
        _cache[key] = [now + _ttlOk, out];
        return out;
      }
    }
  } catch (_) {}
  _cache[key] = [now + _ttlFail, ''];
  return '';
}
