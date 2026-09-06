// JustWatch 适配器（逆向其网页端 GraphQL，纯 Dart 移植）
//
// 接口要点（2026-09 逆向验证）：
// - 未使用的变量会返回 422，查询里每个变量都必须出现；
// - translation(language: "en") 是字符串标量，字面量必须带引号小写；
// - language=zh 时 content.title 直接是中文译名（无译名回退原名）；
// - searchQuery 多词会稀释结果，只传主词；类型用 genres 短码（hrr=恐怖…）；
// - releaseYear 是 IntFilter，字段名 min/max；offers 的 platform 枚举用 IOS；
// - posterUrl 相对路径，{profile} 占位符替换为 s332 加 images 前缀。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http.dart';
import 'models.dart';
import 't2s.dart';
import 'taxonomy.dart';

const _gqlUrl = 'https://apis.justwatch.com/graphql';
const _imgPrefix = 'https://images.justwatch.com';

const _headers = {
  'Content-Type': 'application/json',
  'Origin': 'https://www.justwatch.com',
  'Referer': 'https://www.justwatch.com/',
  'User-Agent': kBrowserUa,
};

const _query = r'''
query($f: TitleFilter, $c: Country!, $l: Language!, $p: Platform!, $n: Int!) {
  popularTitles(filter: $f, country: $c, language: $l, first: $n) {
    edges { node {
      id
      content(country: $c, language: $l) {
        title originalTitle fullPath shortDescription
        originalReleaseYear
        scoring { imdbScore imdbVotes }
        externalIds { imdbId tmdbId }
        genres { shortName translation(language: "en") }
        posterUrl(format: JPG)
      }
      offers(country: $c, platform: $p) {
        monetizationType standardWebURL presentationType
        package { shortName technicalName clearName }
        retailPrice(language: $l) currency
      }
    } }
  }
}''';

const _monetizationKind = {
  'FREE': 'free', 'ADS': 'free', // 免费广告支撑平台——没会员也能看
  'FLATRATE': 'sub', // 订阅制
  'RENT': 'rent', 'BUY': 'buy',
  'CINEMA': 'other', 'DOWNLOAD': 'buy', 'DVD': 'other',
};

const jwGenreCodes = {
  'horror': 'hrr', 'thriller': 'trl', 'sci-fi': 'scf', 'fantasy': 'fnt',
  'comedy': 'cmy', 'action': 'act', 'animation': 'ani', 'adventure': 'act',
  'mystery': 'trl', 'disaster': '',
};

class JustWatchAdapter {
  final status = SourceStatus('justwatch', 'scrape');

  Future<List<dynamic>> _fetch(Map<String, dynamic> titleFilter, String country,
      {int n = 24, bool record = true}) async {
    final variables = {'f': titleFilter, 'c': country, 'l': 'zh', 'p': 'IOS', 'n': n};
    final sw = Stopwatch()..start();
    try {
      final r = await throttleHost('apis.justwatch.com').then((_) => httpPost(
            Uri.parse(_gqlUrl),
            headers: _headers,
            body: jsonEncode({'query': _query, 'variables': variables}),
          ));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final data = (d['data'] as Map?)?['popularTitles'];
      if (d['errors'] != null && data == null) {
        final errs = d['errors'] as List;
        throw Exception((errs.first as Map)['message']);
      }
      final edges = ((data as Map?)?['edges'] as List?) ?? [];
      if (record) status.recordOk(sw.elapsedMilliseconds * 1.0);
      return edges.whereType<Map>().map((e) => e['node']).whereType<Map>().toList();
    } catch (e) {
      if (record) status.recordFail(e.toString());
      rethrow;
    }
  }

  Future<List<Movie>> search(ParsedQuery pq, String country) async {
    // 「所有国家」：美区发现 + 英/日区补查观看渠道
    final multiRegion = country == 'ALL';
    final baseCountry = multiRegion ? 'US' : country;

    final terms = <String>[];
    for (final lang in ['en', 'ja', 'ko']) {
      final l = pq.termsByLang[lang] ?? const [];
      if (l.isNotEmpty && !terms.contains(l.first)) terms.add(l.first);
    }
    if (terms.isEmpty) terms.add(pq.searchTerms.isNotEmpty ? pq.searchTerms.first : 'monster');

    final effGenre = pq.genreEn ?? pq.impliedGenreEn;
    final baseFilter = <String, dynamic>{};
    final code = jwGenreCodes[effGenre] ?? '';
    if (effGenre != null && code.isNotEmpty) baseFilter['genres'] = [code];
    if (pq.yearFrom != null) {
      baseFilter['releaseYear'] = {
        'min': pq.yearFrom,
        'max': pq.yearTo ?? (pq.yearFrom! + 9),
      };
    }

    final movies = <Movie>[];
    final seenKeys = <String>{};
    for (var i = 0; i < terms.take(3).length; i++) {
      final tf = {'searchQuery': terms[i], ...baseFilter};
      List<dynamic> nodes;
      try {
        nodes = await _fetch(tf, baseCountry, n: i == 0 ? 16 : 12, record: i == 0);
      } catch (_) {
        if (i == 0) rethrow;
        continue;
      }
      var added = 0;
      for (final node in nodes) {
        final m = _toMovie(node, pq);
        final keys = m.strongKeys.toSet();
        if (keys.intersection(seenKeys).isNotEmpty) continue;
        seenKeys.addAll(keys);
        movies.add(m);
        added++;
        if (i > 0 && added >= 8) break;
      }
    }

    if (pq.yearFrom != null) {
      movies.removeWhere((m) =>
          m.year != null &&
          !(pq.yearFrom! <= m.year! && m.year! <= (pq.yearTo ?? pq.yearFrom! + 9)));
    }
    if (multiRegion && movies.isNotEmpty) {
      await _mergeExtraRegions(movies, terms.first, baseFilter);
    }
    return movies;
  }

  /// 标题 → 完整条目（供语义通道回链解析；失败不影响健康度）
  Future<List<Movie>> resolveTitle(String title, String country, ParsedQuery? pq) async {
    try {
      final nodes = await _fetch({'searchQuery': title}, country == 'ALL' ? 'US' : country,
          n: 3, record: false);
      return [for (final n in nodes) _toMovie(n, pq)];
    } catch (_) {
      return [];
    }
  }

  Future<void> _mergeExtraRegions(
      List<Movie> movies, String mainTerm, Map<String, dynamic> baseFilter) async {
    final index = <String, Movie>{};
    for (final m in movies) {
      for (final k in m.strongKeys) {
        index.putIfAbsent(k, () => m);
      }
      index.putIfAbsent('t|${_normKey(m.title)}|${m.year}', () => m);
    }
    for (final region in ['GB', 'JP']) {
      List<dynamic> nodes;
      try {
        nodes = await _fetch({'searchQuery': mainTerm, ...baseFilter}, region,
            n: 12, record: false);
      } catch (_) {
        continue;
      }
      for (final node in nodes) {
        final tmp = _toMovie(node, null);
        Movie? target;
        for (final k in tmp.strongKeys) {
          if (index.containsKey(k)) {
            target = index[k];
            break;
          }
        }
        target ??= index['t|${_normKey(tmp.title)}|${tmp.year}'];
        if (target == null) continue;
        final seen = target.offers.map((o) => o.dedupKey).toSet();
        for (final o in tmp.offers) {
          if (!seen.contains(o.dedupKey)) {
            target.offers.add(Offer('${o.platform}·$region', o.kind, o.url, o.price));
            seen.add(o.dedupKey);
          }
        }
        _sortOffers(target.offers);
      }
    }
  }

  Movie _toMovie(dynamic node, ParsedQuery? pq) {
    final n = node as Map;
    final c = (n['content'] ?? {}) as Map;
    final scoring = (c['scoring'] ?? {}) as Map;
    final ext = (c['externalIds'] ?? {}) as Map;
    final genres = [
      for (final g in ((c['genres'] ?? []) as List))
        ((g as Map)['translation'] ?? g['shortName'] ?? '').toString()
    ]..where((s) => s.isNotEmpty).toList();

    final offers = <Offer>[];
    final seen = <String>{};
    for (final o in ((n['offers'] ?? []) as List)) {
      final om = o as Map;
      final pkg = (om['package'] ?? {}) as Map;
      final pkgName = (pkg['clearName'] ?? pkg['shortName'] ?? pkg['technicalName'] ?? '?').toString();
      final kind = _monetizationKind[om['monetizationType']?.toString()] ?? 'other';
      final url = om['standardWebURL']?.toString() ?? '';
      var price = '';
      if (om['retailPrice'] != null) {
        price = '${om['retailPrice']} ${om['currency'] ?? ''}'.trim();
      }
      final off = Offer(pkgName, kind, url, price);
      if (url.isEmpty || seen.contains(off.dedupKey)) continue;
      seen.add(off.dedupKey);
      offers.add(off);
    }
    _sortOffers(offers);

    final fullPath = c['fullPath']?.toString() ?? '';
    var poster = '';
    final posterUrl = c['posterUrl']?.toString();
    if (posterUrl != null && posterUrl.isNotEmpty) {
      poster = '$_imgPrefix$posterUrl'.replaceAll('{profile}', 's332');
    }

    final year = _extYear(c, fullPath);
    final ratings = <String, dynamic>{};
    if (scoring['imdbScore'] != null) ratings['imdb'] = scoring['imdbScore'];

    return Movie(
      title: t2s(c['title']?.toString() ?? ''),
      originalTitle: c['originalTitle']?.toString() ?? '',
      year: year,
      poster: poster,
      overview: (c['shortDescription']?.toString() ?? ''),
      imdbId: ext['imdbId']?.toString() ?? '',
      tmdbId: ext['tmdbId']?.toString() ?? '',
      ratings: ratings,
      imdbVotes: int.tryParse(scoring['imdbVotes']?.toString() ?? '0') ?? 0,
      genres: genres.where((g) => g.isNotEmpty).toList(),
      creatures: pq != null ? List.from(pq.creatures) : [],
      sources: ['justwatch'],
      links: fullPath.isNotEmpty ? {'JustWatch': 'https://www.justwatch.com$fullPath'} : {},
      offers: offers,
    );
  }
}

void _sortOffers(List<Offer> offers) {
  const order = {'free': 0, 'sub': 1, 'rent': 2, 'buy': 3, 'other': 4};
  offers.sort((a, b) {
    final ka = order[a.kind] ?? 9, kb = order[b.kind] ?? 9;
    return ka != kb ? ka.compareTo(kb) : a.platform.compareTo(b.platform);
  });
}

int? _extYear(Map c, String fullPath) {
  final y = c['originalReleaseYear'];
  if (y is int && y > 1880) return y;
  final m = RegExp(r'-(\d{4})$').firstMatch(fullPath.trimRight());
  return m != null ? int.parse(m.group(1)!) : null;
}

String _normKey(String t) => t.toLowerCase().replaceAll(RegExp(r'[\W_]+'), '');
