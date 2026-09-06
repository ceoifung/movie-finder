"""生物本体库 + 查询解析：把中文口语查询解析成结构化检索条件。

多语言设计：每个生物分类内置 中/英/日/韩 四语言检索词（日韩恐怖片产量大，
母语检索词在 Yandex/各源上的召回率远高于只用英文）。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

GENRES = {
    "恐怖": "horror",
    "惊悚": "thriller",
    "科幻": "sci-fi",
    "奇幻": "fantasy",
    "喜剧": "comedy",
    "动作": "action",
    "动画": "animation",
    "冒险": "adventure",
    "悬疑": "mystery",
    "灾难": "disaster",
}

# TMDB genre id 映射（官方 API 用）
TMDB_GENRE_IDS = {
    "horror": 27, "thriller": 53, "sci-fi": 878, "fantasy": 14,
    "comedy": 35, "action": 28, "animation": 16, "adventure": 12,
    "mystery": 9648, "disaster": 0,  # disaster 无独立 id，退化为空
}

# 规范分类名 -> 多语言检索词（含同义词）
CREATURES: dict[str, dict[str, list[str]]] = {
    "丧尸": {"en": ["zombie", "undead", "living dead"], "ja": ["ゾンビ"], "ko": ["좀비"]},
    "吸血鬼": {"en": ["vampire"], "ja": ["吸血鬼", "ヴァンパイア"], "ko": ["뱀파이어", "흡혈귀"]},
    "狼人": {"en": ["werewolf"], "ja": ["狼男"], "ko": ["늑대인간"]},
    "巨型鲨鱼": {"en": ["shark", "mega shark"], "ja": ["メガシャーク", "シャークパニック"], "ko": ["메가 샤크", "상어"]},
    "巨兽": {"en": ["kaiju", "godzilla", "giant monster", "monster"], "ja": ["怪獣"], "ko": ["괴수", "괴물"]},
    "外星生物": {"en": ["alien", "extraterrestrial", "alien invasion"], "ja": ["エイリアン", "宇宙人"], "ko": ["에일리언", "외계인"]},
    "深海怪物": {"en": ["sea monster", "kraken", "giant squid", "deep sea horror"], "ja": ["深海の怪物", "クラーケン"], "ko": ["심해 괴물", "크라켄"]},
    "克苏鲁": {"en": ["lovecraft", "cthulhu", "cosmic horror"], "ja": ["クトゥルフ", "ラヴクラフト"], "ko": ["크툴후", "러브크래프트"]},
    "变异生物": {"en": ["mutant", "mutation"], "ja": ["突然変異", "ミュータント"], "ko": ["돌연변이", "뮤턴트"]},
    "巨型猿": {"en": ["king kong", "giant ape"], "ja": ["キングコング", "大猿"], "ko": ["킹콩"]},
    "雪怪": {"en": ["yeti", "abominable snowman", "bigfoot", "sasquatch"], "ja": ["雪男", "イエティ"], "ko": ["예티", "빅풋"]},
    "食人鱼": {"en": ["piranha"], "ja": ["ピラニア"], "ko": ["피라냐"]},
    "鳄鱼": {"en": ["crocodile", "alligator"], "ja": ["クロコダイル", "巨大ワニ"], "ko": ["악어", "크로커다일"]},
    "巨蛇": {"en": ["snake", "anaconda"], "ja": ["アナコンダ", "大蛇"], "ko": ["아나콘다", "거대 뱀"]},
    "蜘蛛": {"en": ["spider", "tarantula"], "ja": ["蜘蛛", "スパイダー"], "ko": ["거미"]},
    "虫群": {"en": ["killer insects", "giant ants", "deadly swarm", "cockroach"], "ja": ["殺人虫", "昆虫パニック"], "ko": ["벌레 떼", "살인 곤충"]},
    "鬼魂": {"en": ["ghost", "haunted", "poltergeist"], "ja": ["幽霊", "心霊"], "ko": ["유령", "괴담"]},
    "恶魔": {"en": ["demon", "demonic possession"], "ja": ["悪魔", "悪魔憑依"], "ko": ["악마", "빙의"]},
    "小丑": {"en": ["killer clown", "evil clown"], "ja": ["殺人ピエロ"], "ko": ["살인 광대"]},
    "寄生体": {"en": ["parasite", "body snatchers"], "ja": ["寄生生物", "パラサイト"], "ko": ["기생체"]},
    "木乃伊": {"en": ["mummy"], "ja": ["ミイラ"], "ko": ["미라"]},
    "鱼人": {"en": ["gill man", "creature from the black lagoon"], "ja": ["半魚人"], "ko": ["반어인"]},
    "人工智能": {"en": ["evil ai", "killer robot", "android"], "ja": ["悪役AI", "殺人ロボット"], "ko": ["악성 AI", "살인 로봇"]},
    "龙": {"en": ["dragon"], "ja": ["ドラゴン"], "ko": ["드래곤"]},
    "猛兽": {"en": ["killer bear", "grizzly", "man-eating animal"], "ja": ["猛獣", "人喰い熊"], "ko": ["맹수", "식인곰"]},
    "杀人植物": {"en": ["killer plants", "triffid"], "ja": ["人喰い植物"], "ko": ["식인 식물"]},
}

_GENRE_ZH_TO_EN = dict(GENRES)
_EN_TO_GENRE_ZH = {v: k for k, v in GENRES.items()}

# 生物 → 隐含类型：用户只点生物不选类型时，按该类型过滤以消除模糊噪音
# （搜「巨型鲨鱼」默认就是找鲨鱼恐怖片，而不是 Megamind 这类标题沾边的）
IMPLIED_GENRE = {
    "外星生物": "sci-fi", "人工智能": "sci-fi", "巨兽": "sci-fi", "龙": "fantasy",
}  # 其余生物默认 horror

# ---- 描述式查询（「背景在荒山，主角叫拿破仑的恐怖片」）的解析词典 ----
# 场景词：中文 -> 英文检索词（喂给语义源做全文/简介匹配）
SETTING_WORDS = {
    "荒山": "wilderness mountains", "深山": "deep mountains", "山中": "mountain",
    "雪山": "snowy mountain", "孤岛": "deserted island", "荒岛": "deserted island",
    "森林": "forest", "树林": "woods", "沙漠": "desert", "荒漠": "desert",
    "海上": "at sea", "太空": "outer space", "宇宙": "outer space",
    "木屋": "cabin in the woods", "小屋": "cabin", "地下室": "basement",
    "医院": "hospital", "精神病院": "asylum", "学校": "school", "小镇": "small town",
    "公寓": "apartment", "酒店": "hotel", "监狱": "prison", "灯塔": "lighthouse",
    "洞穴": "cave", "海底": "underwater", "极地": "antarctic", "农场": "farm",
}
# 剧情词：中文 -> 英文
PLOT_WORDS = {
    "杀人": "murder", "连环杀手": "serial killer", "失踪": "missing",
    "诅咒": "cursed", "附身": "possession", "驱魔": "exorcism", "复仇": "revenge",
    "逃生": "survival", "实验": "experiment", "病毒": "virus", "仪式": "ritual",
    "祭祀": "cult sacrifice", "邪教": "cult", "直播": "livestream", "录像": "found footage",
    "纪录片": "found footage", "目击": "witness", "追踪": "stalker",
}

# 实体抽取：「主角叫拿破仑」「主人公名为X」「一个叫X的人」
_ENTITY_RE = re.compile(
    r"(?:主角|主人公|男主|女主|主角名字|名字)?(?:叫|名为)\s*"
    r"([\u4e00-\u9fff]{2,4}|[A-Za-z][a-zA-Z]{1,15})"
)
_ENTITY_STOP = {"的", "是", "和", "与", "这部", "什么", "一部", "一个", "电影", "恐怖"}


def extract_entities(text: str) -> list[str]:
    out = []
    for m in _ENTITY_RE.finditer(text):
        name = m.group(1).strip()
        for tail in ("的", "是", "和", "与"):
            if name.endswith(tail):
                name = name[: -len(tail)]
        if len(name) >= 2 and name not in _ENTITY_STOP:
            out.append(name)
    return list(dict.fromkeys(out))[:3]


def extract_settings(text: str) -> list[str]:
    out = []
    for zh, en in SETTING_WORDS.items():
        if zh in text and en not in out:
            out.append(en)
    return out[:2]


def extract_plots(text: str) -> list[str]:
    out = []
    for zh, en in PLOT_WORDS.items():
        if zh in text and en not in out:
            out.append(en)
    return out[:2]

# Yandex 多语言检索时的语境词（每语言拼在主词后）
MOVIE_WORDS = {
    "en": "best horror movies",
    "ja": "おすすめ 映画",
    "ko": "영화 추천",
    "zh": "电影 推荐",
}

_DECADE_RE = re.compile(r"\b((?:19|20)?\d0)\s*(?:年代|'s|s)\b", re.I)
_FREE_WORDS = ("免费", "free")


def _decade_to_years(tok: str) -> tuple[int, int]:
    n = int(tok)
    if len(tok) == 2:  # 两位写法：90年代 → 1990s（>30 视为 19xx，否则 20xx）
        n = 1900 + n if n > 30 else 2000 + n
    return n, n + 9


@dataclass
class ParsedQuery:
    raw: str
    creatures: list[str] = field(default_factory=list)          # 规范中文分类名
    search_terms: list[str] = field(default_factory=list)       # 英文检索词（发给各源）
    terms_by_lang: dict = field(default_factory=dict)           # {"zh":[..],"en":[..],"ja":[..],"ko":[..]}
    entities: list[str] = field(default_factory=list)           # 人名等实体（中文原文）
    entities_en: list[str] = field(default_factory=list)        # 实体英文名（翻译后由聚合层填充）
    setting_terms: list[str] = field(default_factory=list)      # 场景英文词（wilderness mountains...）
    descriptive: bool = False                                   # 描述式查询（语义检索通道接管）
    genre_zh: str | None = None
    genre_en: str | None = None
    implied_genre_en: str | None = None   # 生物隐含类型（用户未显式选类型时生效）
    year_from: int | None = None
    year_to: int | None = None
    free_only: bool = False

    def cache_key(self, country: str, free_only: bool) -> str:
        import json
        return json.dumps({
            "raw": self.raw, "creatures": self.creatures, "terms": self.search_terms,
            "terms_by_lang": self.terms_by_lang,
            "genre": self.genre_en, "yf": self.year_from, "yt": self.year_to,
            "country": country, "free": free_only,
        }, ensure_ascii=False, sort_keys=True)


def _match_creatures(text: str) -> list[str]:
    low = text.lower()
    hits = []
    for zh, langs in CREATURES.items():
        found = zh in low
        if not found:
            for terms in langs.values():
                if any(re.search(rf"\b{re.escape(t)}\b", low) for t in terms):
                    found = True
                    break
        if found:
            hits.append(zh)
    return hits


def _match_genre(text: str) -> str | None:
    low = text.lower()
    for zh, en in _GENRE_ZH_TO_EN.items():
        if zh in low:
            return zh
    for en, zh in _EN_TO_GENRE_ZH.items():
        if re.search(rf"\b{re.escape(en)}\b", low):
            return zh
    return None


def parse_query(q: str, genre: str | None = None, creatures: list[str] | None = None) -> ParsedQuery:
    """解析查询。用户显式选择的 chips（genre/creatures）优先于文本自动识别。"""
    raw = (q or "").strip()
    low = raw.lower()

    picked = [c for c in (creatures or []) if c in CREATURES]
    detected = _match_creatures(low)
    seen: list[str] = []
    for c in picked + detected:
        if c not in seen:
            seen.append(c)

    genre_zh = None
    if genre in GENRES:
        genre_zh = genre
    else:
        genre_zh = _match_genre(low)

    year_from = year_to = None
    if (m := _DECADE_RE.search(low)):
        year_from, year_to = _decade_to_years(m.group(1))

    free_only = any(w in low for w in _FREE_WORDS)

    # 多语言词表：生物分类自带 en/ja/ko，zh 用原文
    terms_by_lang: dict[str, list[str]] = {"zh": [], "en": [], "ja": [], "ko": []}
    for c in seen:
        langs = CREATURES[c]
        terms_by_lang["en"] += langs["en"]
        terms_by_lang["ja"] += langs["ja"][:1]
        terms_by_lang["ko"] += langs["ko"][:1]
        terms_by_lang["zh"].append(c)
    for k in terms_by_lang:
        terms_by_lang[k] = list(dict.fromkeys(terms_by_lang[k]))

    # 描述式查询：抽到实体（主角叫X）时进入语义模式，实体+场景词做检索词
    entities = [] if seen else extract_entities(raw)
    setting_terms = [] if seen else extract_settings(raw)
    descriptive = bool(entities)

    if descriptive:
        plot_terms = extract_plots(raw)
        terms_by_lang["zh"] = [raw.strip()[:40]] if raw.strip() else []
        terms_by_lang["en"] = setting_terms + plot_terms
        # search_terms 先放中文实体，聚合层翻译成英文后替换为 entities_en
        search_terms = list(entities) + setting_terms[:1]
        return ParsedQuery(
            raw=raw, creatures=seen, search_terms=search_terms,
            terms_by_lang=terms_by_lang, entities=entities,
            setting_terms=setting_terms, descriptive=True,
            genre_zh=genre_zh, genre_en=GENRES.get(genre_zh) if genre_zh else None,
            implied_genre_en=None,
            year_from=year_from, year_to=year_to, free_only=free_only,
        )

    # 英文主检索词（JustWatch/TMDB/IMDb 用），去掉与类型重复的词
    terms: list[str] = list(terms_by_lang["en"])
    leftover = low
    for c in seen:
        leftover = leftover.replace(c.lower(), " ")
        for t in CREATURES[c]["en"]:
            leftover = re.sub(rf"\b{re.escape(t)}\b", " ", leftover)
    if genre_zh:
        leftover = leftover.replace(genre_zh.lower(), " ").replace(GENRES[genre_zh], " ")
    for junk in ("电影", "片", "推荐", "movie", "film", "horror", "sci-fi"):
        leftover = leftover.replace(junk, " ")
    free_text = re.sub(r"\s+", " ", leftover).strip()
    if len(free_text) >= 2 and free_text not in terms:
        terms.append(free_text)
        terms_by_lang["zh"].append(free_text)

    if not terms:
        terms = ["monster", "creature"]
        terms_by_lang["en"] = ["monster"]

    return ParsedQuery(
        raw=raw, creatures=seen, search_terms=terms, terms_by_lang=terms_by_lang,
        genre_zh=genre_zh, genre_en=GENRES.get(genre_zh) if genre_zh else None,
        implied_genre_en=IMPLIED_GENRE.get(seen[0], "horror") if seen and not genre_zh else None,
        year_from=year_from, year_to=year_to, free_only=free_only,
    )
