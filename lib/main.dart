// CreatureFinder APP —— 怪物电影聚合检索
// 后端：movie-finder（FastAPI），默认地址可在设置里修改。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const CreatureFinderApp());

const kAccent = Color(0xFFF02E4C);
const kBg = Color(0xFF0D1117);
const kPanel = Color(0xFF161B22);
const kBorder = Color(0xFF2D3646);
const kFree = Color(0xFF2EA862);
const kSub = Color(0xFF3B82F6);
const kMuted = Color(0xFF8B949E);

class CreatureFinderApp extends StatelessWidget {
  const CreatureFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '怪物电影聚合检索',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent, secondary: kAccent, surface: kPanel,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true, fillColor: kPanel,
          border: OutlineInputBorder(borderSide: BorderSide(color: kBorder)),
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kAccent)),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------- 数据模型 ----------------

class Offer {
  final String platform, kind, url, price;
  Offer(this.platform, this.kind, this.url, this.price);
  factory Offer.fromJson(Map<String, dynamic> j) =>
      Offer(j['platform'] ?? '?', j['kind'] ?? 'other', j['url'] ?? '', j['price'] ?? '');
}

class WebLink {
  final String title, url;
  WebLink(this.title, this.url);
  factory WebLink.fromJson(Map<String, dynamic> j) => WebLink(j['title'] ?? '', j['url'] ?? '');
}

class Movie {
  final String title, originalTitle;
  final int? year;
  final String poster, overview, imdbId;
  final Map<String, dynamic> ratings;
  final List<String> creatures, genres, sources;
  final List<Offer> offers;
  final List<WebLink> webLinks;
  Movie({
    required this.title, this.originalTitle = '', this.year,
    this.poster = '', this.overview = '', this.imdbId = '',
    this.ratings = const {}, this.creatures = const [],
    this.genres = const [], this.sources = const [],
    this.offers = const [], this.webLinks = const [],
  });
  factory Movie.fromJson(Map<String, dynamic> j) => Movie(
    title: j['title'] ?? '',
    originalTitle: j['original_title'] ?? '',
    year: j['year'],
    poster: j['poster'] ?? '',
    overview: j['overview'] ?? '',
    imdbId: j['imdb_id'] ?? '',
    ratings: (j['ratings'] as Map?)?.cast<String, dynamic>() ?? {},
    creatures: List<String>.from(j['creatures'] ?? []),
    genres: List<String>.from(j['genres'] ?? []),
    sources: List<String>.from(j['sources'] ?? []),
    offers: (j['offers'] as List? ?? []).map((o) => Offer.fromJson(o)).toList(),
    webLinks: (j['web_links'] as List? ?? []).map((l) => WebLink.fromJson(l)).toList(),
  );
  bool get hasFree => offers.any((o) => o.kind == 'free');
}

class SearchResponse {
  final List<Movie> results;
  final List<Map<String, dynamic>> sources;
  final int tookMs;
  SearchResponse(this.results, this.sources, this.tookMs);
}

class Taxonomy {
  final Map<String, String> genres;       // zh -> en
  final Map<String, dynamic> creatures;   // zh -> {en:[..], ja:[..], ko:[..]}
  final List<List<String>> countries;     // [code, zh]
  Taxonomy(this.genres, this.creatures, this.countries);
}

// ---------------- API 客户端 ----------------

class ApiClient {
  static String server = 'http://10.0.2.2:8300'; // Android 模拟器访问宿主机后端
  static const _timeout = Duration(seconds: 75);

  static Future<void> loadSaved() async {
    final sp = await SharedPreferences.getInstance();
    server = sp.getString('server_url') ?? server;
  }

  static Future<void> saveServer(String url) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('server_url', url);
    server = url;
  }

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('$server$path').replace(queryParameters: q);

  Future<Taxonomy> taxonomy() async {
    final r = await http.get(_u('/api/taxonomy')).timeout(_timeout);
    if (r.statusCode != 200) throw Exception('taxonomy HTTP ${r.statusCode}');
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return Taxonomy(
      (d['genres'] as Map).cast<String, String>(),
      (d['creatures'] as Map).cast<String, dynamic>(),
      (d['countries'] as List).map((c) => List<String>.from(c)).toList(),
    );
  }

  Future<SearchResponse> search({
    required String q,
    String? genre,
    List<String> creatures = const [],
    String country = 'ALL',
    bool free = false,
  }) async {
    final params = <String, String>{if (q.isNotEmpty) 'q': q, 'country': country};
    if (genre != null && genre.isNotEmpty) params['genre'] = genre;
    if (free) params['free'] = 'true';
    final uri = Uri.parse('$server/api/search').replace(
      queryParameters: {
        ...params,
        for (final c in creatures) 'creature': c,
      },
    );
    final r = await http.get(uri).timeout(_timeout);
    if (r.statusCode != 200) throw Exception('search HTTP ${r.statusCode}');
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return SearchResponse(
      (d['results'] as List? ?? []).map((m) => Movie.fromJson(m)).toList(),
      (d['sources'] as List? ?? []).map((s) => Map<String, dynamic>.from(s)).toList(),
      d['took_ms'] ?? 0,
    );
  }
}

Future<void> openUrl(String url) async {
  if (url.isEmpty) return;
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

// ---------------- 首页 ----------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiClient();
  final _qCtrl = TextEditingController();
  Taxonomy? _tax;
  String? _genre;
  String _country = 'ALL';
  bool _freeOnly = false;
  final Set<String> _picked = {};
  SearchResponse? _resp;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await ApiClient.loadSaved();
    try {
      final t = await _api.taxonomy();
      setState(() => _tax = t);
    } catch (e) {
      setState(() => _error = '无法连接后端（$e）。请点右上角设置服务地址。');
    }
  }

  Future<void> _doSearch() async {
    if (_qCtrl.text.trim().isEmpty && _picked.isEmpty && (_genre == null || _genre!.isEmpty)) {
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final r = await _api.search(
        q: _qCtrl.text.trim(),
        genre: _genre,
        creatures: _picked.toList(),
        country: _country,
        free: _freeOnly,
      );
      setState(() { _resp = r; _loading = false; });
    } catch (e) {
      setState(() { _error = '检索失败：$e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kPanel,
        title: const Text('🧟 怪物电影聚合检索', style: TextStyle(fontSize: 18)),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          if (_tax != null) _buildChips(),
          if (_resp != null) _buildSourceStatus(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          Expanded(
            child: _loading
                ? const Center(child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: kAccent),
                      SizedBox(height: 12),
                      Text('正在并发检索多个数据源…', style: TextStyle(color: kMuted, fontSize: 13)),
                    ],
                  ))
                : _resp == null
                    ? const Center(child: Text('输入条件或点选生物标签开始搜索',
                        style: TextStyle(color: kMuted)))
                    : _resp!.results.isEmpty
                        ? const Center(child: Text('没有找到符合条件的影片', style: TextStyle(color: kMuted)))
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                            itemCount: _resp!.results.length,
                            itemBuilder: (_, i) => MovieCard(m: _resp!.results[i]),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        children: [
          Row(children: [
            Expanded(child: TextField(
              controller: _qCtrl,
              onSubmitted: (_) => _doSearch(),
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: '恐怖片 巨型鲨鱼 90年代 / 丧尸 / 雪怪 杀人',
                isDense: true, contentPadding: EdgeInsets.all(12),
              ),
            )),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _doSearch,
              style: FilledButton.styleFrom(backgroundColor: kAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
              child: const Text('搜索'),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true, value: _genre,
                hint: const Text('全部类型', style: TextStyle(fontSize: 13)),
                dropdownColor: kPanel,
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部类型', style: TextStyle(fontSize: 13))),
                  ...?_tax?.genres.keys.map((g) =>
                      DropdownMenuItem(value: g, child: Text(g, style: const TextStyle(fontSize: 13)))),
                ],
                onChanged: (v) => setState(() => _genre = (v == '' ? null : v)),
              ),
            )),
            const SizedBox(width: 12),
            Expanded(child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true, value: _country,
                dropdownColor: kPanel,
                items: (_tax?.countries ?? const [['ALL', '所有国家']])
                    .map((c) => DropdownMenuItem(
                        value: c[0], child: Text(c[1], style: const TextStyle(fontSize: 13))))
                    .toList(),
                onChanged: (v) => setState(() => _country = v ?? 'ALL'),
              ),
            )),
            const SizedBox(width: 12),
            FilterChip(
              label: const Text('仅免费', style: TextStyle(fontSize: 12)),
              selected: _freeOnly,
              selectedColor: kFree.withValues(alpha: .25),
              checkmarkColor: kFree,
              onSelected: (v) => setState(() => _freeOnly = v),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildChips() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: _tax!.creatures.keys.map((zh) {
          final on = _picked.contains(zh);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(zh, style: TextStyle(fontSize: 12, color: on ? const Color(0xFFFF8598) : kMuted)),
              selected: on,
              showCheckmark: false,
              selectedColor: kAccent.withValues(alpha: .15),
              backgroundColor: kPanel,
              side: BorderSide(color: on ? kAccent : kBorder),
              onSelected: (_) => setState(() => on ? _picked.remove(zh) : _picked.add(zh)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSourceStatus() {
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: _resp!.sources.map((s) {
          final name = s.keys.first;
          final st = s.values.first as Map<String, dynamic>;
          final n = st['results'] ?? 0;
          final ok = n > 0;
          final skipped = st['skipped'] == true;
          return Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: kPanel, borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kBorder),
            ),
            child: Text(
              '$name ${skipped ? '·' : (ok ? '✓' : '✗')} $n',
              style: TextStyle(fontSize: 11, color: ok ? kFree : kMuted),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()));
    _init();
  }
}

// ---------------- 结果卡片 ----------------

const _kindLabel = {'free': '免费', 'sub': '订阅', 'rent': '租', 'buy': '买', 'other': '其他'};

class MovieCard extends StatelessWidget {
  final Movie m;
  const MovieCard({super.key, required this.m});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kPanel, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _poster(),
          Expanded(child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m.title}${m.year != null ? '（${m.year}）' : ''}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              if (m.originalTitle.isNotEmpty)
                Text(m.originalTitle,
                    style: const TextStyle(fontSize: 11, color: kMuted)),
              const SizedBox(height: 6),
              _ratings(),
              const SizedBox(height: 6),
              _tags(),
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 4, children: m.sources.map(_srcBadge).toList()),
            ]),
          )),
        ]),
        if (m.overview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(m.overview, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: kMuted, height: 1.5)),
          ),
        if (m.offers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(spacing: 6, runSpacing: 6, children: m.offers.take(8).map(_offerChip).toList()),
          ),
        if (m.webLinks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('▶ 在线播放 / 相关网页', style: TextStyle(fontSize: 11, color: Color(0xFFFF7A45))),
              const SizedBox(height: 6),
              ...m.webLinks.map(_webLinkRow),
            ]),
          ),
      ]),
    );
  }

  Widget _poster() {
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
      child: m.poster.isEmpty
          ? Container(width: 100, height: 140, color: const Color(0xFF1C2330),
              child: const Icon(Icons.movie, size: 30, color: kMuted))
          : Image.network(m.poster, width: 100, height: 140, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(width: 100, height: 140,
                  color: const Color(0xFF1C2330),
                  child: const Icon(Icons.movie, size: 30, color: kMuted))),
    );
  }

  Widget _ratings() {
    final r = m.ratings;
    final items = <Widget>[
      if (r['imdb'] != null) _rate('IMDb ${r['imdb']}', const Color(0xFFF5C518)),
      if (r['tmdb'] != null) _rate('TMDB ${r['tmdb']}', const Color(0xFF01B4E4)),
      if (r['metascore'] != null) _rate('MC ${r['metascore']}', const Color(0xFF66CC33)),
      if (r['rt'] != null) _rate('🍅 ${r['rt']}%', const Color(0xFFFA320A)),
    ];
    return Wrap(spacing: 6, runSpacing: 4, children: items);
  }

  Widget _rate(String text, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: const Color(0xFF1C2330), borderRadius: BorderRadius.circular(5)),
    child: Text(text, style: TextStyle(fontSize: 11, color: c)),
  );

  Widget _tags() {
    final tags = <Widget>[
      ...m.creatures.map((c) => _tag(c, const Color(0xFFFF8598))),
      ...m.genres.take(3).map((g) => _tag(g, kMuted)),
    ];
    return Wrap(spacing: 5, runSpacing: 4, children: tags);
  }

  Widget _tag(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: c == kMuted ? const Color(0xFF1C2330) : c.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(99)),
    child: Text(t, style: TextStyle(fontSize: 10, color: c)),
  );

  Widget _srcBadge(String s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: kBorder, style: BorderStyle.solid),
      borderRadius: BorderRadius.circular(5)),
    child: Text(s, style: const TextStyle(fontSize: 10, color: kMuted)),
  );

  Widget _offerChip(Offer o) {
    final color = switch (o.kind) { 'free' => kFree, 'sub' => kSub, _ => const Color(0xFFD29922) };
    return InkWell(
      onTap: () => openUrl(o.url),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1C2330),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: color.withValues(alpha: .2), borderRadius: BorderRadius.circular(4)),
            child: Text(_kindLabel[o.kind] ?? o.kind, style: TextStyle(fontSize: 10, color: color)),
          ),
          const SizedBox(width: 6),
          Flexible(child: Text(
            o.price.isEmpty ? o.platform : '${o.platform} ${o.price}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          )),
        ]),
      ),
    );
  }

  Widget _webLinkRow(WebLink l) {
    String domain = l.url;
    try { domain = Uri.parse(l.url).host.replaceFirst('www.', ''); } catch (_) {}
    return InkWell(
      onTap: () => openUrl(l.url),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C2330),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorder),
        ),
        child: Row(children: [
          Expanded(child: Text(l.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF7DB3FF)))),
          const SizedBox(width: 8),
          Text(domain, style: const TextStyle(fontSize: 10, color: kMuted)),
          const Icon(Icons.open_in_new, size: 12, color: kMuted),
        ]),
      ),
    );
  }
}

// ---------------- 设置页 ----------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _ctrl;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ApiClient.server);
  }

  Future<void> _test() async {
    setState(() => _testResult = '测试中…');
    try {
      final r = await http.get(Uri.parse('${_ctrl.text.trim()}/api/taxonomy'))
          .timeout(const Duration(seconds: 10));
      setState(() => _testResult = r.statusCode == 200
          ? '✓ 连接成功（genres: ${(jsonDecode(r.body)['genres'] as Map).length} 个）'
          : '✗ HTTP ${r.statusCode}');
    } catch (e) {
      setState(() => _testResult = '✗ $e');
    }
  }

  Future<void> _save() async {
    await ApiClient.saveServer(_ctrl.text.trim().replaceAll(RegExp(r'/+$'), ''));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kPanel,
        title: const Text('设置'),
        actions: [TextButton(onPressed: _save, child: const Text('保存', style: TextStyle(color: kAccent)))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('后端服务地址', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'http://192.168.1.100:8300', isDense: true),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _test,
          icon: const Icon(Icons.wifi_tethering, size: 18),
          label: const Text('测试连接'),
        ),
        if (_testResult != null) Text(_testResult!, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorder)),
          child: const Text(
            '说明：\n'
            '1. 后端是 movie-finder 项目（FastAPI），先在你的电脑/服务器上运行：\n'
            '   .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8300\n'
            '2. 手机与后端需在同一网络（局域网/WiFi），地址填电脑的局域网 IP。\n'
            '3. Android 模拟器请用 http://10.0.2.2:8300（默认值）。\n'
            '4. 正式使用建议把后端部署到云服务器并配 HTTPS。',
            style: TextStyle(fontSize: 12, color: kMuted, height: 1.7),
          ),
        ),
      ]),
    );
  }
}
