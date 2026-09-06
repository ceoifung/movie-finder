// CreatureFinder APP —— 怪物电影聚合检索（纯客户端版：引擎在手机本地运行，无后端依赖）
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'engine/aggregator.dart';
import 'engine/models.dart' as eng;
import 'engine/taxonomy.dart' as tax;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sp = await SharedPreferences.getInstance();
  EngineHolder.init(EngineConfig(
    tmdbKey: sp.getString('tmdb_key'),
    yandexKey: sp.getString('yandex_key'),
  ));
  runApp(const CreatureFinderApp());
}

class EngineHolder {
  static Engine engine = Engine(EngineConfig());
  static void init(EngineConfig cfg) => engine = Engine(cfg);
  static Future<void> rebuild(String? tmdbKey, String? yandexKey) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('tmdb_key', tmdbKey ?? '');
    await sp.setString('yandex_key', yandexKey ?? '');
    EngineHolder.engine = Engine(EngineConfig(tmdbKey: tmdbKey, yandexKey: yandexKey));
  }
}

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

Future<void> openUrl(String url) async {
  if (url.isEmpty) return;
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ---------------- 首页 ----------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _qCtrl = TextEditingController();
  String? _genre;
  String _country = 'ALL';
  bool _freeOnly = false;
  final Set<String> _picked = {};
  eng.SearchResponse? _resp;
  bool _loading = false;
  String? _error;

  bool _allSourcesFailed() {
    if (_resp == null || _resp!.sources.isEmpty) return false;
    return _resp!.sources.every((s) {
      final st = s.values.first as Map<String, dynamic>;
      return (st['results'] ?? 0) == 0 && (st['status'] != 'idle');
    });
  }

  Future<void> _doSearch() async {
    if (_qCtrl.text.trim().isEmpty && _picked.isEmpty && (_genre == null || _genre!.isEmpty)) {
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final r = await EngineHolder.engine.search(SearchInput(
        _qCtrl.text.trim(),
        genre: _genre,
        creatures: _picked.toList(),
        country: _country,
        freeOnly: _freeOnly,
      ));
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
          IconButton(icon: const Icon(Icons.settings), onPressed: () async {
            await Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()));
            setState(() {}); // 引擎可能已重建
          }),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildChips(),
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
                      Text('本地引擎并发检索多个数据源…', style: TextStyle(color: kMuted, fontSize: 13)),
                    ],
                  ))
                : _resp == null
                    ? const Center(child: Text('输入条件或点选生物标签开始搜索\n所有检索都在手机本地完成，无需服务器',
                        textAlign: TextAlign.center, style: TextStyle(color: kMuted, height: 1.8)))
                    : _resp!.results.isEmpty
                        ? Center(child: Text(
                            _allSourcesFailed()
                                ? '所有数据源都失败了：请检查手机网络是否能访问外网\n'
                                  '（需科学上网的环境请先开启）\n\n上方状态条可看各源错误详情'
                                : '没有找到符合条件的影片，试试放宽条件',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: kMuted, height: 1.8)))
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
                  for (final g in tax.genres.keys)
                    DropdownMenuItem(value: g, child: Text(g, style: const TextStyle(fontSize: 13))),
                ],
                onChanged: (v) => setState(() => _genre = (v == '' ? null : v)),
              ),
            )),
            const SizedBox(width: 12),
            Expanded(child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true, value: _country,
                dropdownColor: kPanel,
                items: [
                  for (final c in tax.countries)
                    DropdownMenuItem(value: c[0], child: Text(c[1], style: const TextStyle(fontSize: 13))),
                ],
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
        children: tax.creatures.keys.map((zh) {
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
          final ok = (n as int) > 0;
          return Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: kPanel, borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kBorder),
            ),
            child: Text(
              '$name ${ok ? '✓' : '✗'} $n',
              style: TextStyle(fontSize: 11, color: ok ? kFree : kMuted),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ---------------- 结果卡片 ----------------

const _kindLabel = {'free': '免费', 'sub': '订阅', 'rent': '租', 'buy': '买', 'other': '其他'};

class MovieCard extends StatelessWidget {
  final eng.Movie m;
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
                Text(m.originalTitle, style: const TextStyle(fontSize: 11, color: kMuted)),
              const SizedBox(height: 6),
              _ratings(),
              const SizedBox(height: 6),
              _tags(),
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 4,
                  children: m.sources.map(_srcBadge).toList()),
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
            child: Wrap(spacing: 6, runSpacing: 6,
                children: m.offers.take(8).map(_offerChip).toList()),
          ),
        if (m.webLinks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('▶ 在线播放 / 相关网页',
                  style: TextStyle(fontSize: 11, color: Color(0xFFFF7A45))),
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
    ];
    return Wrap(spacing: 6, runSpacing: 4, children: items);
  }

  Widget _rate(String text, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
        color: const Color(0xFF1C2330), borderRadius: BorderRadius.circular(5)),
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
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(5)),
    child: Text(s, style: const TextStyle(fontSize: 10, color: kMuted)),
  );

  Widget _offerChip(eng.Offer o) {
    final color = switch (o.kind) {
      'free' => kFree, 'sub' => kSub, _ => const Color(0xFFD29922),
    };
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
            decoration: BoxDecoration(
                color: color.withValues(alpha: .2),
                borderRadius: BorderRadius.circular(4)),
            child: Text(_kindLabel[o.kind] ?? o.kind,
                style: TextStyle(fontSize: 10, color: color)),
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

  Widget _webLinkRow(eng.WebLink l) {
    var domain = l.url;
    try {
      domain = Uri.parse(l.url).host.replaceFirst('www.', '');
    } catch (_) {}
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

// ---------------- 设置页（可选 API key） ----------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _tmdbCtrl;
  late final TextEditingController _yandexCtrl;

  @override
  void initState() {
    super.initState();
    _tmdbCtrl = TextEditingController(text: EngineHolder.engine.config.tmdbKey ?? '');
    _yandexCtrl = TextEditingController(text: EngineHolder.engine.config.yandexKey ?? '');
  }

  Future<void> _save() async {
    await EngineHolder.rebuild(
      _tmdbCtrl.text.trim().isEmpty ? null : _tmdbCtrl.text.trim(),
      _yandexCtrl.text.trim().isEmpty ? null : _yandexCtrl.text.trim(),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kPanel,
        title: const Text('设置'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存', style: TextStyle(color: kAccent))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('可选：TMDB API Key（免费申请 themoviedb.org/settings/api）',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        TextField(controller: _tmdbCtrl, style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '填入后启用 TMDB 中文片名/关键词通道', isDense: true)),
        const SizedBox(height: 20),
        const Text('可选：Yandex Search API Key（yandex.ru/dev/search/api）',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        TextField(controller: _yandexCtrl, style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '填入后在线播放链接优先走 Yandex 官方接口', isDense: true)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorder)),
          child: const Text(
            '说明：\n'
            '1. 本 APP 为纯客户端架构——所有检索（JustWatch/WhatIsMyMovie/搜索引擎）'
            '都在手机本地执行，不需要任何服务器。\n'
            '2. 不填 key 也完全可用；填 key 只是增强（TMDB 中文片名更全、Yandex 免验证码）。\n'
            '3. key 只保存在手机本地，不会上传。',
            style: TextStyle(fontSize: 12, color: kMuted, height: 1.7),
          ),
        ),
      ]),
    );
  }
}
