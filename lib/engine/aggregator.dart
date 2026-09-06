// 聚合引擎：并发扇出 → 归一化 → 去重合并 → 排序 → 缓存 → 网页链接富集（纯 Dart）
import 'dart:async';

import 'justwatch.dart';
import 'models.dart';
import 'scrapers.dart';
import 'taxonomy.dart';
import 'translate.dart';
import 'weblinks.dart';
import 'wimm.dart';

class EngineConfig {
  final String? tmdbKey;
  final String? yandexKey;
  EngineConfig({this.tmdbKey, this.yandexKey});
}

class _AdapterRef {
  final String name;
  final Future<List<Movie>?> Function(ParsedQuery, String) search;
  final SourceStatus status;
  final double timeoutSec;
  _AdapterRef(this.name, this.search, this.status, {this.timeoutSec = 12});

  bool get available => status.available;
}

class SearchInput {
  final String q;
  final String? genre;
  final List<String> creatures;
  final String country;
  final bool freeOnly;
  final int limit;
  SearchInput(this.q, {this.genre, this.creatures = const [], this.country = 'ALL',
      this.freeOnly = false, this.limit = 24});
}

class Engine {
  final EngineConfig config;
  late final JustWatchAdapter justwatch;
  late final WimmAdapter wimm;
  late final TmdbAdapter tmdb;
  late final ImdbAdapter imdb;
  late final LetterboxdAdapter letterboxd;
  late final ArchiveAdapter archive;
  late final List<_AdapterRef> _adapters;

  final Map<String, List<Object>> _cache = {}; // key -> [expiryMs, SearchResponse]
  final _cacheTtl = 6 * 3600 * 1000;

  Engine(this.config) {
    justwatch = JustWatchAdapter();
    wimm = WimmAdapter(justwatch);
    tmdb = TmdbAdapter(config.tmdbKey);
    imdb = ImdbAdapter();
    letterboxd = LetterboxdAdapter();
    archive = ArchiveAdapter();
    _adapters = [
      _AdapterRef('justwatch', (pq, c) => justwatch.search(pq, c), justwatch.status,
          timeoutSec: 15), // en/ja/ko 三次请求 + 400ms 节流，预算充足
      _AdapterRef('tmdb', tmdb.enabled ? (pq, c) => tmdb.search(pq, c) : _skip,
          tmdb.status),
      _AdapterRef('whatismymovie', (pq, c) => wimm.search(pq, c), wimm.status,
          timeoutSec: 30),
      _AdapterRef('imdb', (pq, c) => imdb.search(pq, c), imdb.status),
      _AdapterRef('letterboxd', (pq, c) => letterboxd.search(pq, c), letterboxd.status),
      _AdapterRef('archive', (pq, c) => archive.search(pq, c), archive.status),
    ];
  }

  static Future<List<Movie>?> _skip(ParsedQuery pq, String c) async => null;

  Map<String, Map<String, dynamic>> statusMap() => {
        for (final a in _adapters) a.name: a.status.toMap(),
      };

  // ---------------- 查询缓存键 ----------------

  String _cacheKey(ParsedQuery pq, String country, bool freeOnly) =>
      '${pq.raw}|${pq.creatures.join(',')}|${pq.genreZh}|$country|$freeOnly|'
      '${pq.yearFrom}|${pq.searchTerms.join(',')}';

  Future<SearchResponse> search(SearchInput input) async {
    var pq = parseQuery(input.q, genre: input.genre, pickedCreatures: input.creatures);
    if (pq.raw.isEmpty && pq.creatures.isEmpty && pq.genreZh == null) {
      return SearchResponse(const [], [], 0, {'error': 'empty query'});
    }

    // 描述式查询：实体名翻译成英文（拿破仑 -> napoleon）
    if (pq.descriptive && pq.entities.isNotEmpty) {
      final translated = <String>[];
      for (final e in pq.entities) {
        final t = await translateZhTo(e, 'en');
        translated.add(t.isNotEmpty ? t.toLowerCase().trim() : e);
      }
      pq = ParsedQuery(
        raw: pq.raw, creatures: pq.creatures, searchTerms: translated,
        termsByLang: {...pq.termsByLang, 'en': translated},
        entities: pq.entities, entitiesEn: translated, settingTerms: pq.settingTerms,
        descriptive: true, genreZh: pq.genreZh, genreEn: pq.genreEn,
        impliedGenreEn: null, yearFrom: pq.yearFrom, yearTo: pq.yearTo,
        freeOnly: pq.freeOnly,
      );
    }

    final ck = _cacheKey(pq, input.country, input.freeOnly);
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _cache[ck];
    if (hit != null && (hit[0] as int) > now) {
      return hit[1] as SearchResponse;
    }

    final sw = Stopwatch()..start();
    final effectiveCountry = input.country == 'ALL' ? 'US' : input.country;

    // 并发扇出（JustWatch 自己处理 ALL，其余源统一单一国家）
    final outcomes = await Future.wait(_adapters.where((a) => a.available).map((a) async {
      try {
        final c = a.name == 'justwatch' ? input.country : effectiveCountry;
        final movies = await a.search(pq, c).timeout(Duration(milliseconds: (a.timeoutSec * 1000).round()));
        return (a, movies, null);
      } on TimeoutException {
        return (a, null, 'timeout');
      } catch (e) {
        return (a, null, e.toString().substring(0, e.toString().length.clamp(0, 120)));
      }
    }));

    final lists = <List<Movie>>[];
    final sourcesJson = <Map<String, dynamic>>[];
    for (final (a, movies, err) in outcomes) {
      final skipped = err != null && err.startsWith('Exception: skip');
      a.status.results = 0;
      if (movies != null && movies.isNotEmpty) {
        a.status.results = movies.length;
        lists.add(movies);
      } else if (err != null && !skipped && a.status.lastError == null) {
        a.status.recordFail(err);
      }
      sourcesJson.add({
        a.name: {
          'kind': a.status.kind,
          'enabled': true,
          ...a.status.toMap(),
        }
      });
    }

    final merged = mergeMovies(lists);
    for (final m in merged) {
      m.score = computeScore(m);
    }
    merged.sort((a, b) => b.score.compareTo(a.score));
    var results = input.freeOnly ? merged.where((m) => m.hasFree).toList() : merged;
    results = results.take(input.limit).toList();

    // 网页搜索结果富集（Yandex→DDG→Bing）
    try {
      await enrichWebLinks(results, yandexKey: config.yandexKey)
          .timeout(const Duration(seconds: 20));
    } catch (_) {}

    final resp = SearchResponse(
      results, sourcesJson, sw.elapsedMilliseconds, pq.toMap(),
    );
    _cache[ck] = [now + _cacheTtl, resp];
    if (_cache.length > 200) {
      _cache.clear(); // 简单容量控制
    }
    return resp;
  }

  // ---------------- 合并去重 ----------------

  static String normTitle(String t) {
    var s = t.toLowerCase();
    s = s.replaceAll(RegExp(r'[^\w\s]+'), ' ');
    s = s.replaceFirst(RegExp(r'^(the|a|an|le|la|les|el|los)\s+'), '');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static bool _yearCompatible(Movie a, Movie b) {
    if (a.year == null || b.year == null) return true;
    return (a.year! - b.year!).abs() <= 1;
  }

  static void absorb(Movie base, Movie m) {
    // 标题优先中文
    if (!_hasCjk(base.title) && _hasCjk(m.title)) {
      if (base.originalTitle.isEmpty && base.title.isNotEmpty) {
        base.originalTitle = base.title;
      }
      base.title = m.title;
    }
    if (base.title.isEmpty) base.title = m.title;
    if (base.originalTitle.isEmpty) base.originalTitle = m.originalTitle;
    base.poster = base.poster.isNotEmpty ? base.poster : m.poster;
    base.overview = base.overview.isNotEmpty ? base.overview : m.overview;
    base.imdbId = base.imdbId.isNotEmpty ? base.imdbId : m.imdbId;
    base.tmdbId = base.tmdbId.isNotEmpty ? base.tmdbId : m.tmdbId;
    base.year ??= m.year;
    for (final e in m.ratings.entries) {
      if (e.value != null && base.ratings[e.key] == null) base.ratings[e.key] = e.value;
    }
    if (m.imdbVotes > base.imdbVotes) base.imdbVotes = m.imdbVotes;
    base.genres = [...base.genres, ...m.genres].toSet().toList();
    base.creatures = [...base.creatures, ...m.creatures].toSet().toList();
    base.sources = [...base.sources, ...m.sources].toSet().toList();
    base.links.addAll(m.links);
    final seen = base.offers.map((o) => o.dedupKey).toSet();
    for (final o in m.offers) {
      if (!seen.contains(o.dedupKey)) {
        base.offers.add(o);
        seen.add(o.dedupKey);
      }
    }
  }

  static bool _hasCjk(String s) => s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

  static List<Movie> mergeMovies(List<List<Movie>> lists) {
    final byKey = <String, Movie>{};
    final byTitle = <String, List<Movie>>{};
    final out = <Movie>[];
    for (final movies in lists) {
      for (final m in movies) {
        if (m.title.isEmpty && m.originalTitle.isEmpty) continue;
        Movie? target;
        for (final k in m.strongKeys) {
          if (byKey.containsKey(k)) {
            target = byKey[k];
            break;
          }
        }
        if (target == null) {
          final nt = normTitle(m.title.isNotEmpty ? m.title : m.originalTitle);
          for (final cand in byTitle[nt] ?? const []) {
            if (_yearCompatible(cand, m)) {
              target = cand;
              break;
            }
          }
        }
        if (target == null) {
          out.add(m);
          final nt = normTitle(m.title.isNotEmpty ? m.title : m.originalTitle);
          if (nt.isNotEmpty) {
            byTitle.putIfAbsent(nt, () => []).add(m);
          }
          for (final k in m.strongKeys) {
            byKey[k] = m;
          }
        } else {
          absorb(target, m);
          for (final k in m.strongKeys) {
            byKey[k] = target;
          }
        }
      }
    }
    return out;
  }

  static double computeScore(Movie m) {
    var s = 2.5 * m.sources.length;
    final imdb = m.ratings['imdb'];
    if (imdb is num) s += imdb * 1.2;
    final tmdb = m.ratings['tmdb'];
    if (tmdb is num) s += tmdb * 0.4;
    s += (m.imdbVotes / 100000).clamp(0, 3);
    if (m.hasFree) {
      s += 2;
    } else if (m.offers.any((o) => o.kind == 'sub')) {
      s += 0.5;
    }
    if (m.year != null) s += ((m.year! - 1960) / 10).clamp(0, 6.5);
    return s;
  }
}
