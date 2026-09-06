// 其余爬虫/可选 key 适配器：IMDb 高级搜索 / Letterboxd 标签 / Internet Archive / TMDB（可选key）
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

import 'http.dart';
import 'models.dart';
import 'taxonomy.dart';

// ---------------- IMDb：高级关键词搜索（住宅 IP 可用，数据中心被挑战页拦截） ----------------

class ImdbAdapter {
  final status = SourceStatus('imdb', 'scrape');

  Future<List<Movie>> search(ParsedQuery pq, String country) async {
    final params = <String>[
      'title_type=feature,tv_movie', 'sort=user_rating,desc', 'numVotes=2000',
      if (pq.searchTerms.isNotEmpty)
        'keywords=${Uri.encodeComponent(pq.searchTerms.take(2).join(','))}',
      if (pq.genreEn != null) 'genres=${Uri.encodeComponent(pq.genreEn!)}',
      if (pq.yearFrom != null)
        'release_date=$pq.yearFrom-01-01,${pq.yearTo ?? pq.yearFrom}-12-31',
    ];
    final url = 'https://www.imdb.com/search/title/?${params.join('&')}';
    final sw = Stopwatch()..start();
    final r = await throttleHost('www.imdb.com')
        .then((_) => httpGet(Uri.parse(url), headers: browserHeaders()));
    if (r.statusCode != 200 || r.bodyBytes.length < 30 * 1024) {
      status.recordFail('blocked/challenge (HTTP ${r.statusCode}, ${r.bodyBytes.length}B)');
      throw Exception('imdb anti-bot challenge');
    }

    final soup = html_parser.parse(utf8.decode(r.bodyBytes));
    final movies = <Movie>[];
    final titleRe = RegExp(r'^\d+\.\s*');
    final yearRe = RegExp(r'^(.+?)\s*\((\d{4})\)\s*$');
    for (final li in soup.querySelectorAll('li.ipc-metadata-list-summary-item').take(20)) {
      final h = li.querySelector('h3.ipc-title__text');
      if (h == null) continue;
      var text = h.text.trim().replaceFirst(titleRe, '');
      String title;
      int? year;
      final m = yearRe.firstMatch(text);
      if (m != null) {
        title = m.group(1)!;
        year = int.parse(m.group(2)!);
      } else {
        title = text;
      }
      String imdbId = '';
      final link = li.querySelector("a[href*='/title/tt']");
      if (link != null) {
        final mm = RegExp(r'/title/(tt\d+)').firstMatch(link.attributes['href'] ?? '');
        if (mm != null) imdbId = mm.group(1)!;
      }
      movies.add(Movie(
        title: title,
        year: year,
        imdbId: imdbId,
        genres: [if (pq.genreEn != null) pq.genreEn!],
        creatures: List.from(pq.creatures),
        sources: ['imdb'],
        links: imdbId.isNotEmpty ? {'IMDb': 'https://www.imdb.com/title/$imdbId'} : {},
      ));
    }
    if (movies.isEmpty) {
      status.recordFail('no results parsed');
      throw Exception('imdb parse failed');
    }
    status.recordOk(sw.elapsedMilliseconds * 1.0);
    return movies;
  }
}

// ---------------- Letterboxd：社区生物标签（Cloudflare 严，住宅 IP 可用） ----------------

class LetterboxdAdapter {
  final status = SourceStatus('letterboxd', 'scrape');

  Future<List<Movie>> search(ParsedQuery pq, String country) async {
    final term = pq.searchTerms.isNotEmpty ? pq.searchTerms.first : 'monster';
    final slug = term.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-');
    final sw = Stopwatch()..start();
    final r = await throttleHost('letterboxd.com')
        .then((_) => httpGet(Uri.https('letterboxd.com', '/films/tags/$slug/'),
            headers: browserHeaders()));
    if (r.statusCode == 403) {
      status.recordFail('cloudflare 403');
      throw Exception('letterboxd blocked (403)');
    }
    if (r.statusCode != 200 || r.bodyBytes.length < 10 * 1024) {
      status.recordFail('HTTP ${r.statusCode}');
      throw Exception('letterboxd HTTP ${r.statusCode}');
    }

    final soup = html_parser.parse(utf8.decode(r.bodyBytes));
    final movies = <Movie>[];
    final seen = <String>{};
    for (final img in soup.querySelectorAll('img.film-poster, div.film-poster img')) {
      final title = (img.attributes['alt'] ?? '').trim();
      if (title.isEmpty || seen.contains(title.toLowerCase())) continue;
      seen.add(title.toLowerCase());
      movies.add(Movie(
        title: title,
        creatures: List.from(pq.creatures),
        sources: ['letterboxd'],
        links: {'Letterboxd': 'https://letterboxd.com/search/films/${title.replaceAll(' ', '+')}/'},
      ));
      if (movies.length >= 20) break;
    }
    if (movies.isEmpty) {
      status.recordFail('no results parsed');
      throw Exception('letterboxd parse failed');
    }
    status.recordOk(sw.elapsedMilliseconds * 1.0);
    return movies;
  }
}

// ---------------- Internet Archive：公共领域免费老片 ----------------

class ArchiveAdapter {
  final status = SourceStatus('archive', 'scrape');

  Future<List<Movie>> search(ParsedQuery pq, String country) async {
    final term = pq.searchTerms.isNotEmpty ? pq.searchTerms.first : 'monster';
    final sw = Stopwatch()..start();
    final r = await throttleHost('archive.org').then((_) => httpGet(
          Uri.https('archive.org', '/advancedsearch.php', {
            'q': 'title:("$term") AND mediatype:(movies)',
            'fl[]': ['identifier', 'title', 'year'],
            'rows': '12', 'page': '1', 'output': 'json',
          }),
          headers: browserHeaders(),
        ));
    if (r.statusCode != 200) {
      status.recordFail('HTTP ${r.statusCode}');
      throw Exception('archive HTTP ${r.statusCode}');
    }
    final docs =
        (((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['response'] ?? {}) as Map)['docs'] as List? ?? [];
    final movies = <Movie>[];
    for (final d in docs) {
      final dm = d as Map;
      final ident = dm['identifier'].toString();
      final url = 'https://archive.org/details/$ident';
      final yearStr = dm['year']?.toString() ?? '';
      movies.add(Movie(
        title: dm['title'].toString().split(' / ').first,
        year: int.tryParse(yearStr.length >= 4 ? yearStr.substring(0, 4) : yearStr),
        creatures: List.from(pq.creatures),
        sources: ['archive'],
        links: {'Internet Archive': url},
        offers: [Offer('Internet Archive', 'free', url, '')],
      ));
    }
    if (movies.isEmpty) {
      status.recordFail('no results');
      throw Exception('archive no results');
    }
    status.recordOk(sw.elapsedMilliseconds * 1.0);
    return movies;
  }
}

// ---------------- TMDB：官方 API（可选，用户在设置里自己填 key） ----------------

class TmdbAdapter {
  final status = SourceStatus('tmdb', 'official');
  final String? apiKey;
  TmdbAdapter(this.apiKey);

  bool get enabled => apiKey != null && apiKey!.isNotEmpty;

  Future<Map<String, dynamic>> _api(String path, Map<String, String> params) async {
    params['api_key'] = apiKey!;
    final r = await throttleHost('api.themoviedb.org')
        .then((_) => httpGet(Uri.https('api.themoviedb.org', '/3$path', params)));
    if (r.statusCode == 401) throw Exception('invalid TMDB key');
    if (r.statusCode != 200) throw Exception('TMDB HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<Movie>?> search(ParsedQuery pq, String country) async {
    if (!enabled) return null;
    final sw = Stopwatch()..start();
    try {
      final kwIds = <String>[];
      for (final term in pq.searchTerms.take(3)) {
        final d = await _api('/search/keyword', {'query': term});
        for (final k in ((d['results'] ?? []) as List).take(2)) {
          kwIds.add((k as Map)['id'].toString());
        }
      }
      final params = <String, String>{
        'sort_by': 'popularity.desc',
        'language': 'zh-CN',
        'include_adult': 'false',
        if (pq.genreEn != null && (tmdbGenreIds[pq.genreEn] ?? 0) > 0)
          'with_genres': '${tmdbGenreIds[pq.genreEn]}',
        if (kwIds.isNotEmpty) 'with_keywords': kwIds.toSet().join('|'),
        if (pq.yearFrom != null) 'primary_release_date.gte': '${pq.yearFrom}-01-01',
        if (pq.yearFrom != null)
          'primary_release_date.lte': '${pq.yearTo ?? pq.yearFrom}-12-31',
      };
      final d = await _api('/discover/movie', params);
      final genreMap = <String, String>{};
      try {
        final gd = await _api('/genre/movie/list', {'language': 'zh-CN'});
        for (final g in ((gd['genres'] ?? []) as List)) {
          genreMap[(g as Map)['id'].toString()] = g['name'].toString();
        }
      } catch (_) {}

      final movies = <Movie>[];
      for (final item in ((d['results'] ?? []) as List).take(24)) {
        final im = item as Map;
        movies.add(Movie(
          title: (im['title'] ?? im['original_title'] ?? '').toString(),
          originalTitle: (im['original_title'] ?? '').toString(),
          year: im['release_date'] != null
              ? int.tryParse(im['release_date'].toString().substring(0, 4))
              : null,
          poster: im['poster_path'] != null
              ? 'https://image.tmdb.org/t/p/w500${im['poster_path']}'
              : '',
          overview: (im['overview'] ?? '').toString(),
          tmdbId: im['id'].toString(),
          ratings: {'tmdb': im['vote_average']},
          genres: [
            for (final gid in ((im['genre_ids'] ?? []) as List))
              if (genreMap.containsKey(gid.toString())) genreMap[gid.toString()]!
          ],
          creatures: List.from(pq.creatures),
          sources: ['tmdb'],
          links: {'TMDB': 'https://www.themoviedb.org/movie/${im['id']}'},
        ));
      }
      status.recordOk(sw.elapsedMilliseconds * 1.0);
      return movies;
    } catch (e) {
      status.recordFail(e.toString());
      rethrow;
    }
  }
}
