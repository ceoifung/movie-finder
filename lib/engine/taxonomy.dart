// 生物本体库 + 查询解析（中/英/日/韩四语言，纯 Dart 移植自 Python 版 taxonomy.py）
class ParsedQuery {
  final String raw;
  final List<String> creatures;
  final List<String> searchTerms;
  final Map<String, List<String>> termsByLang;
  final List<String> entities;
  final List<String> entitiesEn;
  final List<String> settingTerms;
  final bool descriptive;
  final String? genreZh;
  final String? genreEn;
  final String? impliedGenreEn;
  final int? yearFrom;
  final int? yearTo;
  final bool freeOnly;

  ParsedQuery({
    required this.raw,
    this.creatures = const [],
    this.searchTerms = const [],
    Map<String, List<String>>? termsByLang,
    this.entities = const [],
    this.entitiesEn = const [],
    this.settingTerms = const [],
    this.descriptive = false,
    this.genreZh,
    this.genreEn,
    this.impliedGenreEn,
    this.yearFrom,
    this.yearTo,
    this.freeOnly = false,
  }) : termsByLang = termsByLang ??
            {'zh': [], 'en': [], 'ja': [], 'ko': []};

  Map<String, dynamic> toMap() => {
        'raw': raw,
        'descriptive': descriptive,
        'entities': entities,
        'entities_en': entitiesEn,
        'creatures': creatures,
        'search_terms': searchTerms,
        'terms_by_lang': termsByLang,
        'genre': genreZh,
        'year_from': yearFrom,
        'year_to': yearTo,
      };
}

const Map<String, String> genres = {
  '恐怖': 'horror', '惊悚': 'thriller', '科幻': 'sci-fi', '奇幻': 'fantasy',
  '喜剧': 'comedy', '动作': 'action', '动画': 'animation', '冒险': 'adventure',
  '悬疑': 'mystery', '灾难': 'disaster',
};

const Map<String, int> tmdbGenreIds = {
  'horror': 27, 'thriller': 53, 'sci-fi': 878, 'fantasy': 14,
  'comedy': 35, 'action': 28, 'animation': 16, 'adventure': 12,
  'mystery': 9648, 'disaster': 0,
};

// 中文同义词：用户口语说法 -> 规范分类（僵尸/活尸 都算丧尸）
const Map<String, List<String>> zhSynonyms = {
  '丧尸': ['僵尸', '活尸', '行尸'],
  '巨型鲨鱼': ['鲨鱼'],
  '巨兽': ['怪兽', '哥斯拉', '特摄'],
  '外星生物': ['外星人'],
  '人工智能': ['机器人', 'AI', 'ai'],
  '雪怪': ['大脚怪'],
  '鬼魂': ['女鬼', '冤魂', '厉鬼'],
  '恶魔': ['魔鬼'],
  '深海怪物': ['海怪', '深海怪兽'],
  '变异生物': ['变种'],
  '猛兽': ['食人兽'],
  '寄生体': ['寄生兽'],
};

// 生物 -> 隐含类型（未显式选类型时过滤模糊噪音）
const Map<String, String> impliedGenre = {
  '外星生物': 'sci-fi', '人工智能': 'sci-fi', '巨兽': 'sci-fi', '龙': 'fantasy',
};

const Map<String, Map<String, List<String>>> creatures = {
  '丧尸': {'en': ['zombie', 'undead', 'living dead'], 'ja': ['ゾンビ'], 'ko': ['좀비']},
  '吸血鬼': {'en': ['vampire'], 'ja': ['吸血鬼', 'ヴァンパイア'], 'ko': ['뱀파이어', '흡혈귀']},
  '狼人': {'en': ['werewolf'], 'ja': ['狼男'], 'ko': ['늑대인간']},
  '巨型鲨鱼': {'en': ['shark', 'mega shark'], 'ja': ['メガシャーク', 'シャークパニック'], 'ko': ['메가 샤크', '상어']},
  '巨兽': {'en': ['kaiju', 'godzilla', 'giant monster', 'monster'], 'ja': ['怪獣'], 'ko': ['괴수', '괴물']},
  '外星生物': {'en': ['alien', 'extraterrestrial', 'alien invasion'], 'ja': ['エイリアン', '宇宙人'], 'ko': ['에일리언', '외계인']},
  '深海怪物': {'en': ['sea monster', 'kraken', 'giant squid', 'deep sea horror'], 'ja': ['深海の怪物', 'クラーケン'], 'ko': ['심해 괴물', '크라켄']},
  '克苏鲁': {'en': ['lovecraft', 'cthulhu', 'cosmic horror'], 'ja': ['クトゥルフ', 'ラヴクラフト'], 'ko': ['크툴후', '러브크래프트']},
  '变异生物': {'en': ['mutant', 'mutation'], 'ja': ['突然変異', 'ミュータント'], 'ko': ['돌연변이', '뮤턴트']},
  '巨型猿': {'en': ['king kong', 'giant ape'], 'ja': ['キングコング', '大猿'], 'ko': ['킹콩']},
  '雪怪': {'en': ['yeti', 'abominable snowman', 'bigfoot', 'sasquatch'], 'ja': ['雪男', 'イエティ'], 'ko': ['예티', '빅풋']},
  '食人鱼': {'en': ['piranha'], 'ja': ['ピラニア'], 'ko': ['피라냐']},
  '鳄鱼': {'en': ['crocodile', 'alligator'], 'ja': ['クロコダイル', '巨大ワニ'], 'ko': ['악어', '크로커다일']},
  '巨蛇': {'en': ['snake', 'anaconda'], 'ja': ['アナコンダ', '大蛇'], 'ko': ['아나콘다', '거대 뱀']},
  '蜘蛛': {'en': ['spider', 'tarantula'], 'ja': ['蜘蛛', 'スパイダー'], 'ko': ['거미']},
  '虫群': {'en': ['killer insects', 'giant ants', 'deadly swarm', 'cockroach'], 'ja': ['殺人虫', '昆虫パニック'], 'ko': ['벌레 떼', '살인 곤충']},
  '鬼魂': {'en': ['ghost', 'haunted', 'poltergeist'], 'ja': ['幽霊', '心霊'], 'ko': ['유령', '괴담']},
  '恶魔': {'en': ['demon', 'demonic possession'], 'ja': ['悪魔', '悪魔憑依'], 'ko': ['악마', '빙의']},
  '小丑': {'en': ['killer clown', 'evil clown'], 'ja': ['殺人ピエロ'], 'ko': ['살인 광대']},
  '寄生体': {'en': ['parasite', 'body snatchers'], 'ja': ['寄生生物', 'パラサイト'], 'ko': ['기생체']},
  '木乃伊': {'en': ['mummy'], 'ja': ['ミイラ'], 'ko': ['미라']},
  '鱼人': {'en': ['gill man', 'creature from the black lagoon'], 'ja': ['半魚人'], 'ko': ['반어인']},
  '人工智能': {'en': ['evil ai', 'killer robot', 'android'], 'ja': ['悪役AI', '殺人ロボット'], 'ko': ['악성 AI', '살인 로봇']},
  '龙': {'en': ['dragon'], 'ja': ['ドラゴン'], 'ko': ['드래곤']},
  '猛兽': {'en': ['killer bear', 'grizzly', 'man-eating animal'], 'ja': ['猛獣', '人喰い熊'], 'ko': ['맹수', '식인곰']},
  '杀人植物': {'en': ['killer plants', 'triffid'], 'ja': ['人喰い植物'], 'ko': ['식인 식물']},
};

// Yandex 多语言检索的语境词
const Map<String, String> movieWords = {
  'en': 'best horror movies', 'ja': 'おすすめ 映画', 'ko': '영화 추천', 'zh': '电影 推荐',
};

const Map<String, String> settingWords = {
  '荒山': 'wilderness mountains', '深山': 'deep mountains', '山中': 'mountain',
  '雪山': 'snowy mountain', '孤岛': 'deserted island', '荒岛': 'deserted island',
  '森林': 'forest', '树林': 'woods', '沙漠': 'desert', '荒漠': 'desert',
  '海上': 'at sea', '太空': 'outer space', '宇宙': 'outer space',
  '木屋': 'cabin in the woods', '小屋': 'cabin', '地下室': 'basement',
  '医院': 'hospital', '精神病院': 'asylum', '学校': 'school', '小镇': 'small town',
  '公寓': 'apartment', '酒店': 'hotel', '监狱': 'prison', '灯塔': 'lighthouse',
  '洞穴': 'cave', '海底': 'underwater', '极地': 'antarctic', '农场': 'farm',
};

const Map<String, String> plotWords = {
  '杀人': 'murder', '连环杀手': 'serial killer', '失踪': 'missing',
  '诅咒': 'cursed', '附身': 'possession', '驱魔': 'exorcism', '复仇': 'revenge',
  '逃生': 'survival', '实验': 'experiment', '病毒': 'virus', '仪式': 'ritual',
  '祭祀': 'cult sacrifice', '邪教': 'cult', '直播': 'livestream', '录像': 'found footage',
  '纪录片': 'found footage', '目击': 'witness', '追踪': 'stalker',
};

final RegExp _entityRe = RegExp(
    r'(?:主角|主人公|男主|女主|主角名字|名字)?(?:叫|名为)\s*([\u4e00-\u9fff]{2,4}|[A-Za-z][a-zA-Z]{1,15})');
const Set<String> _entityStop = {'的', '是', '和', '与', '这部', '什么', '一部', '一个', '电影', '恐怖'};

final RegExp _decadeRe =
    RegExp(r"\b((?:19|20)?\d0)\s*(?:年代|'s|s)", caseSensitive: false);

List<int> _decadeToYears(String tok) {
  var n = int.parse(tok);
  if (tok.length == 2) n = n > 30 ? 1900 + n : 2000 + n;
  return [n, n + 9];
}

bool _hasCjk(String s) => s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

List<String> extractEntities(String text) {
  final out = <String>[];
  for (final m in _entityRe.allMatches(text)) {
    var name = m.group(1)!.trim();
    for (final tail in ['的', '是', '和', '与']) {
      if (name.endsWith(tail)) name = name.substring(0, name.length - tail.length);
    }
    if (name.length >= 2 && !_entityStop.contains(name) && !out.contains(name)) {
      out.add(name);
    }
    if (out.length >= 3) break;
  }
  return out;
}

List<String> extractSettings(String text) => [
      for (final e in settingWords.entries)
        if (text.contains(e.key)) e.value
    ].toSet().take(2).toList();

List<String> extractPlots(String text) => [
      for (final e in plotWords.entries)
        if (text.contains(e.key)) e.value
    ].toSet().take(2).toList();

List<String> _matchCreatures(String text) {
  final low = text.toLowerCase();
  final hits = <String>[];
  for (final e in creatures.entries) {
    var found = low.contains(e.key) ||
        (zhSynonyms[e.key] ?? const []).any((s) => low.contains(s));
    if (!found) {
      for (final terms in e.value.values) {
        for (final t in terms) {
          if (_hasCjk(t) || _hasHangul(t)) {
            if (low.contains(t.toLowerCase())) { found = true; break; }
          } else if (RegExp('\\b${RegExp.escape(t)}\\b', caseSensitive: false).hasMatch(low)) {
            found = true; break;
          }
        }
        if (found) break;
      }
    }
    if (found) hits.add(e.key);
  }
  return hits;
}

bool _hasHangul(String s) => s.runes.any((r) => r >= 0xAC00 && r <= 0xD7AF);

String? _matchGenre(String text) {
  final low = text.toLowerCase();
  for (final e in genres.entries) {
    if (low.contains(e.key)) return e.key;
  }
  for (final e in genres.entries) {
    if (RegExp('\\b${RegExp.escape(e.value)}\\b', caseSensitive: false).hasMatch(low)) {
      return e.key;
    }
  }
  return null;
}

ParsedQuery parseQuery(String q, {String? genre, List<String>? pickedCreatures}) {
  final raw = q.trim();
  final low = raw.toLowerCase();

  final seen = <String>[];
  for (final c in [...(pickedCreatures ?? []), ..._matchCreatures(low)]) {
    if (creatures.containsKey(c) && !seen.contains(c)) seen.add(c);
  }

  String? genreZh;
  if (genres.containsKey(genre ?? '')) {
    genreZh = genre;
  } else {
    genreZh = _matchGenre(low);
  }

  int? yearFrom, yearTo;
  final dm = _decadeRe.firstMatch(low);
  if (dm != null) {
    final ys = _decadeToYears(dm.group(1)!);
    yearFrom = ys[0];
    yearTo = ys[1];
  }

  final freeOnly = low.contains('免费') || low.contains('free');

  final termsByLang = <String, List<String>>{
    for (final k in ['zh', 'en', 'ja', 'ko']) k: <String>[],
  };
  for (final c in seen) {
    final langs = creatures[c]!;
    for (final t in langs['en']!) {
      if (!termsByLang['en']!.contains(t)) termsByLang['en']!.add(t);
    }
    termsByLang['ja']!.add(langs['ja']!.first);
    termsByLang['ko']!.add(langs['ko']!.first);
    termsByLang['zh']!.add(c);
  }

  // 描述式查询：实体优先（语义通道接管）
  final entities = seen.isEmpty ? extractEntities(raw) : <String>[];
  final settingTerms = seen.isEmpty ? extractSettings(raw) : <String>[];
  final descriptive = entities.isNotEmpty;

  if (descriptive) {
    final plotTerms = extractPlots(raw);
    termsByLang['zh'] = [if (raw.isNotEmpty) raw.substring(0, raw.length.clamp(0, 40))];
    termsByLang['en'] = [...settingTerms, ...plotTerms];
    return ParsedQuery(
      raw: raw,
      creatures: seen,
      searchTerms: [...entities, if (settingTerms.isNotEmpty) settingTerms.first],
      termsByLang: termsByLang,
      entities: entities,
      settingTerms: settingTerms,
      descriptive: true,
      genreZh: genreZh,
      genreEn: genreZh != null ? genres[genreZh] : null,
      impliedGenreEn: null,
      yearFrom: yearFrom,
      yearTo: yearTo,
      freeOnly: freeOnly,
    );
  }

  // 常规：英文主词 = 生物词 + 去重后的自由文本
  final terms = <String>[...termsByLang['en']!];
  var leftover = low;
  for (final c in seen) {
    leftover = leftover.replaceAll(c.toLowerCase(), ' ');
    for (final syn in zhSynonyms[c] ?? const []) {
      leftover = leftover.replaceAll(syn.toLowerCase(), ' ');
    }
    for (final t in creatures[c]!['en']!) {
      leftover = leftover.replaceAll(RegExp('\\b${RegExp.escape(t)}\\b'), ' ');
    }
  }
  if (genreZh != null) {
    leftover = leftover.replaceAll(genreZh.toLowerCase(), ' ').replaceAll(genres[genreZh]!, ' ');
  }
  for (final junk in ['电影', '片', '推荐', 'movie', 'film', 'horror', 'sci-fi']) {
    leftover = leftover.replaceAll(junk, ' ');
  }
  final freeText = leftover.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (freeText.length >= 2 && !terms.contains(freeText)) {
    terms.add(freeText);
    termsByLang['zh']!.add(freeText);
  }
  if (terms.isEmpty) {
    terms.addAll(['monster', 'creature']);
    termsByLang['en'] = ['monster'];
  }

  return ParsedQuery(
    raw: raw,
    creatures: seen,
    searchTerms: terms,
    termsByLang: termsByLang,
    genreZh: genreZh,
    genreEn: genreZh != null ? genres[genreZh] : null,
    impliedGenreEn: seen.isNotEmpty && genreZh == null ? (impliedGenre[seen.first] ?? 'horror') : null,
    yearFrom: yearFrom,
    yearTo: yearTo,
    freeOnly: freeOnly,
  );
}

const List<List<String>> countries = [
  ['ALL', '所有国家'],
  ['US', '美国'], ['GB', '英国'], ['CA', '加拿大'], ['AU', '澳大利亚'],
  ['DE', '德国'], ['FR', '法国'], ['JP', '日本'], ['KR', '韩国'],
  ['HK', '香港'], ['TW', '台湾'], ['SG', '新加坡'], ['BR', '巴西'],
  ['MX', '墨西哥'], ['IN', '印度'], ['ES', '西班牙'], ['IT', '意大利'],
  ['NL', '荷兰'], ['SE', '瑞典'],
];
