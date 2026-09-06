// 统一数据模型（纯 Dart，无 Flutter 依赖）
class Offer {
  final String platform;
  final String kind; // free / sub / rent / buy / other
  final String url;
  final String price;
  Offer(this.platform, this.kind, this.url, this.price);

  String get dedupKey => '$platform\x1f$kind\x1f$url';
  Map<String, dynamic> toJson() =>
      {'platform': platform, 'kind': kind, 'url': url, 'price': price};
  factory Offer.fromJson(Map<String, dynamic> j) =>
      Offer(j['platform'] ?? '?', j['kind'] ?? 'other', j['url'] ?? '', j['price'] ?? '');
}

class WebLink {
  final String title;
  final String url;
  WebLink(this.title, this.url);
  Map<String, dynamic> toJson() => {'title': title, 'url': url};
  factory WebLink.fromJson(Map<String, dynamic> j) =>
      WebLink(j['title'] ?? '', j['url'] ?? '');
}

class Movie {
  String title;
  String originalTitle;
  int? year;
  String poster;
  String overview;
  String imdbId;
  String tmdbId;
  Map<String, dynamic> ratings;
  int imdbVotes;
  List<String> genres;
  List<String> creatures;
  List<String> sources;
  Map<String, String> links;
  List<Offer> offers;
  List<WebLink> webLinks;
  double score;

  Movie({
    required this.title,
    this.originalTitle = '',
    this.year,
    this.poster = '',
    this.overview = '',
    this.imdbId = '',
    this.tmdbId = '',
    Map<String, dynamic>? ratings,
    this.imdbVotes = 0,
    List<String>? genres,
    List<String>? creatures,
    List<String>? sources,
    Map<String, String>? links,
    List<Offer>? offers,
    List<WebLink>? webLinks,
    this.score = 0,
  })  : ratings = ratings ?? {},
        genres = genres ?? [],
        creatures = creatures ?? [],
        sources = sources ?? [],
        links = links ?? {},
        offers = offers ?? [],
        webLinks = webLinks ?? [];

  factory Movie.fromJson(Map<String, dynamic> j) => Movie(
        title: j['title'] ?? '',
        originalTitle: j['original_title'] ?? j['originalTitle'] ?? '',
        year: j['year'],
        poster: j['poster'] ?? '',
        overview: j['overview'] ?? '',
        imdbId: j['imdb_id'] ?? j['imdbId'] ?? '',
        tmdbId: (j['tmdb_id'] ?? j['tmdbId'] ?? '').toString(),
        ratings: (j['ratings'] as Map?)?.cast<String, dynamic>() ?? {},
        imdbVotes: j['imdb_votes'] ?? j['imdbVotes'] ?? 0,
        genres: List<String>.from(j['genres'] ?? []),
        creatures: List<String>.from(j['creatures'] ?? []),
        sources: List<String>.from(j['sources'] ?? []),
        links: (j['links'] as Map?)?.cast<String, String>() ?? {},
        offers: (j['offers'] as List? ?? []).map((o) => Offer.fromJson(o)).toList(),
        webLinks: (j['web_links'] as List? ?? []).map((l) => WebLink.fromJson(l)).toList(),
        score: (j['score'] ?? 0).toDouble(),
      );

  List<String> get strongKeys => [
        if (imdbId.isNotEmpty) 'imdb:$imdbId',
        if (tmdbId.isNotEmpty) 'tmdb:$tmdbId',
      ];

  bool get hasFree => offers.any((o) => o.kind == 'free');
  bool get hasCjkTitle => title.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);
}

class SourceStatus {
  String name;
  String kind;
  int okCount;
  int failCount;
  int failStreak;
  String? lastError;
  double? lastLatencyMs;
  double disabledUntil; // epoch ms
  int results;

  SourceStatus(this.name, this.kind)
      : okCount = 0,
        failCount = 0,
        failStreak = 0,
        disabledUntil = 0,
        results = 0;

  bool get available => DateTime.now().millisecondsSinceEpoch > disabledUntil;

  void recordOk(double ms) {
    okCount++;
    failStreak = 0;
    lastError = null;
    lastLatencyMs = ms;
  }

  void recordFail(String err) {
    failCount++;
    failStreak++;
    lastError = err;
    if (failStreak >= 3) {
      disabledUntil = DateTime.now().millisecondsSinceEpoch + 600 * 1000.0;
    }
  }

  String get state {
    if (!available) return 'circuit-open';
    if (failStreak > 0) return 'degraded';
    if (okCount > 0) return 'ok';
    return 'idle';
  }

  Map<String, dynamic> toMap() => {
        'kind': kind,
        'status': state,
        'ok': okCount,
        'fail': failCount,
        'results': results,
        'error': lastError,
      };
}

class SearchResponse {
  final List<Movie> results;
  final List<Map<String, dynamic>> sources;
  final int tookMs;
  final Map<String, dynamic> queryEcho;
  final bool cached;
  SearchResponse(this.results, this.sources, this.tookMs, this.queryEcho,
      {this.cached = false});
}
