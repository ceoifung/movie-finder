// 片名 → 在线播放网页链接（引擎优先级：Yandex → DuckDuckGo → Bing 替代，纯 Dart）
//
// 反降级策略：结果相关性校验（标题须含片名）、关键词降级（在线播放→电影）、
// 引擎连续失败熔断 15 分钟、片名链接缓存 7 天。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

import 'http.dart';
import 'models.dart';

const _junkDomains = [
  'bing.com', 'microsoft.com', 'duckduckgo.com', 'go.microsoft',
  'support.microsoft', 'login.live',
];

final Map<String, int> _engineFails = {};
final Map<String, double> _engineDisabled = {};
const _failLimit = 2;
const _cooldownMs = 15 * 60 * 1000.0;

const _cacheVer = 'v1';
final Map<String, List<Object>> _linkCache = {}; // key -> [expiryMs, List<WebLink>]
const _cacheTtl = 7 * 24 * 3600 * 1000;

bool _engineOk(String name) =>
    (_engineDisabled[name] ?? 0) < DateTime.now().millisecondsSinceEpoch;

void _record(String name, bool ok) {
  if (ok) {
    _engineFails[name] = 0;
    return;
  }
  _engineFails[name] = (_engineFails[name] ?? 0) + 1;
  if (_engineFails[name]! >= _failLimit) {
    _engineDisabled[name] = DateTime.now().millisecondsSinceEpoch + _cooldownMs;
  }
}

/// 还原 bing /ck/a 跳转壳里的真实 URL（u=a1<Base64>）
String _decodeBingUrl(String url) {
  if (!url.contains('/ck/')) return url;
  try {
    final u = Uri.parse(url).queryParameters['u'] ?? '';
    var b64 = u.startsWith('a1') ? u.substring(2) : u;
    b64 += '=' * (-b64.length % 4);
    final bytes = base64Url.decode(b64);
    return utf8.decode(bytes);
  } catch (_) {
    return url;
  }
}

bool _domainOk(String url) {
  final m = RegExp(r'https?://([^/]+)').firstMatch(url);
  if (m == null) return false;
  final domain = m.group(1)!.toLowerCase();
  return !_junkDomains.any((j) => domain.contains(j));
}

List<WebLink> _takeTop5(List<WebLink> links) {
  final out = <WebLink>[];
  final seenDomain = <String>{};
  for (final l in links) {
    final m = RegExp(r'https?://([^/]+)').firstMatch(l.url);
    if (m == null) continue;
    final domain = m.group(1)!.toLowerCase();
    if (seenDomain.contains(domain)) continue;
    seenDomain.add(domain);
    out.add(l);
    if (out.length >= 5) break;
  }
  return out;
}

// ---------------- Yandex ----------------

Future<List<WebLink>> _searchYandex(String query, String? apiKey) async {
  if (apiKey != null && apiKey.isNotEmpty) {
    final r = await throttleHost('yandex.ru').then((_) => httpGet(
          Uri.https('yandex.ru', '/search/xml', {
            'key': apiKey, 'query': query, 'l10n': 'en',
            'filter': 'strict', 'groupby': 'attr=().mode=flat.groups=10',
          }),
          headers: browserHeaders(),
        ));
    if (r.statusCode != 200) throw Exception('yandex api HTTP ${r.statusCode}');
    // XML 解析用正则轻量抽取（避免引 xml 包）
    final out = <WebLink>[];
    for (final doc in RegExp(r'<doc>(.*?)</doc>', dotAll: true)
        .allMatches(utf8.decode(r.bodyBytes))) {
      final block = doc.group(1)!;
      final urlM = RegExp(r'<url>(.*?)</url>').firstMatch(block);
      final titleM = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(block);
      if (urlM == null) continue;
      final url = urlM.group(1)!;
      final title = (titleM?.group(1) ?? url)
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (url.startsWith('http')) out.add(WebLink(title.substring(0, title.length.clamp(0, 60)), url));
    }
    final top = _takeTop5(out);
    if (top.isEmpty) throw Exception('yandex api no results');
    return top;
  }

  final r = await throttleHost('yandex.com').then((_) => httpGet(
        Uri.https('yandex.com', '/search', {'text': query, 'lr': '87'}),
        headers: browserHeaders(),
      ));
  if (r.statusCode == 403 ||
      r.request?.url.toString().contains('showcaptcha') == true ||
      utf8.decode(r.bodyBytes.sublist(0, r.bodyBytes.length.clamp(0, 6000)))
          .contains('SmartCaptcha')) {
    throw Exception('yandex captcha/blocked');
  }
  if (r.statusCode != 200) throw Exception('yandex HTTP ${r.statusCode}');
  final soup = html_parser.parse(utf8.decode(r.bodyBytes));
  final out = <WebLink>[];
  for (final item in soup.querySelectorAll('li.serp-item, li.OrganicItem')) {
    final a = item.querySelector('h2 a, a.OrganicTitle-Link');
    if (a == null) continue;
    final url = a.attributes['href'] ?? '';
    final title = a.text.trim();
    if (url.startsWith('http') && title.isNotEmpty && _domainOk(url)) {
      out.add(WebLink(title.substring(0, title.length.clamp(0, 60)), url));
    }
  }
  final top = _takeTop5(out);
  if (top.isEmpty) throw Exception('yandex no organic results');
  return top;
}

// ---------------- Bing ----------------

Future<List<WebLink>> _searchBing(String query, String host, {bool ensearch = false}) async {
  final params = <String, String>{'q': query, if (ensearch) 'ensearch': '1'};
  final r = await throttleHost(host).then(
      (_) => httpGet(Uri.https(host, '/search', params), headers: browserHeaders()));
  if (r.statusCode != 200) throw Exception('bing $host HTTP ${r.statusCode}');
  final soup = html_parser.parse(utf8.decode(r.bodyBytes));
  final out = <WebLink>[];
  for (final a in soup.querySelectorAll('li.b_algo h2 a')) {
    final url = _decodeBingUrl(a.attributes['href'] ?? '');
    final title = a.text.trim();
    if (url.startsWith('http') && title.isNotEmpty && _domainOk(url)) {
      out.add(WebLink(title.substring(0, title.length.clamp(0, 60)), url));
    }
  }
  final top = _takeTop5(out);
  if (top.isEmpty) throw Exception('bing no organic results');
  return top;
}

// ---------------- DuckDuckGo ----------------

Future<List<WebLink>> _searchDdg(String query) async {
  final r = await throttleHost('html.duckduckgo.com').then((_) =>
      httpGet(Uri.https('html.duckduckgo.com', '/html/', {'q': query}),
          headers: browserHeaders()));
  if (r.statusCode != 200) throw Exception('ddg HTTP ${r.statusCode}');
  final soup = html_parser.parse(utf8.decode(r.bodyBytes));
  final out = <WebLink>[];
  for (final a in soup.querySelectorAll('a.result__a')) {
    var url = a.attributes['href'] ?? '';
    if (url.contains('uddg=')) {
      url = Uri.decodeFull(Uri.parse(url).queryParameters['uddg'] ?? '');
    }
    final title = a.text.trim();
    if (url.startsWith('http') && title.isNotEmpty && _domainOk(url)) {
      out.add(WebLink(title.substring(0, title.length.clamp(0, 60)), url));
    }
  }
  final top = _takeTop5(out);
  if (top.isEmpty) throw Exception('ddg no results');
  return top;
}

// ---------------- 相关性校验 + 主入口 ----------------

const _stopWords = {'the', 'movie', 'film', 'watch', 'online', 'series', 'list', 'video'};

List<WebLink> _relevant(List<WebLink> links, String zhName, String enName) {
  bool ok(WebLink l) {
    final t = l.title.replaceAll(RegExp(r'\s+'), '');
    if (zhName.isNotEmpty &&
        (t.contains(zhName) || (zhName.length >= 4 && t.contains(zhName.substring(0, 3))))) {
      return true;
    }
    final low = l.title.toLowerCase();
    final words = enName
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((w) => w.length >= 3 && !_stopWords.contains(w))
        .toList();
    final strong = words.where((w) => w.length >= 5).toList();
    final candidates = strong.isNotEmpty ? strong : words;
    return candidates.any((w) => low.contains(w));
  }

  final hits = links.where(ok).toList();
  return hits.isNotEmpty ? hits : [];
}

typedef _EngineDef = (String, List<String>, Future<List<WebLink>> Function(String));

Future<List<WebLink>> searchWebLinks(Movie m, {String? yandexKey}) async {
  final zhName = m.hasCjkTitle ? m.title : (m.originalTitle.isNotEmpty ? m.originalTitle : m.title);
  final enName = m.originalTitle.isNotEmpty ? m.originalTitle : m.title;
  final queries = <String, List<String>>{
    'zh': ['$zhName在线播放', '$zhName电影'],
    'en': ['${enName}watch online', '${enName}film'],
  };
  final ck = '$_cacheVer|$zhName|${m.year}';
  final now = DateTime.now().millisecondsSinceEpoch;
  final hit = _linkCache[ck];
  if (hit != null && (hit[0] as int) > now) return hit[1] as List<WebLink>;

  final engines = <_EngineDef>[
    ('yandex', ['zh', 'en'], (q) => _searchYandex(q, yandexKey)),
    ('ddg', ['zh', 'en'], _searchDdg),
    ('bing_cn', ['zh'], (q) => _searchBing(q, 'cn.bing.com')),
    ('bing_ensearch', ['en'], (q) => _searchBing(q, 'cn.bing.com', ensearch: true)),
    ('bing_global', ['en'], (q) => _searchBing(q, 'www.bing.com')),
  ];

  for (final (name, langs, fn) in engines) {
    if (!_engineOk(name)) continue;
    final attempts = <String>[
      for (final lang in langs) ...queries[lang]!,
    ];
    for (final q in attempts.take(2)) {
      try {
        final links = _relevant(await fn(q), zhName, enName);
        if (links.isEmpty) throw Exception('irrelevant results');
        _record(name, true);
        _linkCache[ck] = [now + _cacheTtl, links];
        return links;
      } catch (_) {
        continue;
      }
    }
    _record(name, false);
  }
  return [];
}

/// 为头部影片填充 webLinks（并发 2 + 引擎级节流）
Future<void> enrichWebLinks(List<Movie> movies, {int limit = 6, String? yandexKey}) async {
  final sem = Semaphore(2);
  await Future.wait(movies.take(limit).map((m) async {
    await sem.acquire();
    try {
      m.webLinks = await searchWebLinks(m, yandexKey: yandexKey);
    } catch (_) {
      m.webLinks = [];
    } finally {
      sem.release();
    }
  }));
}
