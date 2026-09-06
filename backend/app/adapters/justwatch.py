"""JustWatch 适配器（爬虫线 · 核心）。

直接调用其网页端 GraphQL 接口，一次查询同时拿到：
搜索结果 + 海报 + IMDb 评分 + TMDB/IMDb ID + 类型 + 各平台观看地址（含深度链接）。

多语言：searchQuery 原生支持中/日/韩检索词（ゾンビ→活死人之夜），因此对
本体库的 en/ja/ko 主词各发一次查询，本地合并去重，提升母语片名召回率。

接口逆向说明（2026-09 验证有效）：
- 端点禁用 introspection，字段通过 GraphQL 校验错误提示逐个探测；
- 未使用的变量会直接返回 422，查询里的每个变量都必须出现；
- translation(language: "en") 是字符串标量，字面量必须带引号小写；
- searchQuery 多词拼接会稀释结果（模糊全文匹配），只传主词，类型用 genres 短码过滤；
- genre 短码：hrr=恐怖 scf=科幻 trl=惊悚/悬疑 fnt=奇幻 cmy=喜剧 act=动作/冒险 ani=动画 rly=爱情 drm=剧情；
- releaseYear 是 IntFilter，字段名 min/max（服务端年代过滤）；
- offers 的 platform 枚举用 IOS 可返回全部平台报价；
- posterUrl 返回相对路径，{profile} 占位符需替换为尺寸（s332）并加 images 前缀。
"""
from __future__ import annotations

import asyncio
import re
import time

from opencc import OpenCC

from ..models import Movie, Offer
from ..taxonomy import ParsedQuery
from .base import AdapterError, SearchAdapter

try:
    _t2s = OpenCC("t2s")
    _to_simplified = _t2s.convert
except Exception:  # opencc 不可用时保留原文
    _to_simplified = lambda s: s

GQL_URL = "https://apis.justwatch.com/graphql"
IMG_PREFIX = "https://images.justwatch.com"

HEADERS = {
    "Content-Type": "application/json",
    "Origin": "https://www.justwatch.com",
    "Referer": "https://www.justwatch.com/",
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    ),
}

QUERY = """query($f: TitleFilter, $c: Country!, $l: Language!, $p: Platform!, $n: Int!) {
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
}"""

MONETIZATION_KIND = {
    "FREE": "free", "ADS": "free",       # 免费广告支撑平台（Tubi/Pluto 等）——没会员也能看
    "FLATRATE": "sub",                    # 订阅制（Netflix 等）
    "RENT": "rent", "BUY": "buy",
    "CINEMA": "other", "DOWNLOAD": "buy", "DVD": "other",
}

JW_GENRE_CODES = {
    "horror": "hrr", "thriller": "trl", "sci-fi": "scf", "fantasy": "fnt",
    "comedy": "cmy", "action": "act", "animation": "ani", "adventure": "act",
    "mystery": "trl", "disaster": None,
}


def _norm_key(t: str) -> str:
    import re as _re
    return _re.sub(r"[\W_]+", "", (t or "").lower())


def _year_from_path(path: str) -> int | None:
    m = re.search(r"-(\d{4})$", (path or "").rstrip("/"))
    return int(m.group(1)) if m else None


def ext_year(content: dict, full_path: str) -> int | None:
    y = content.get("originalReleaseYear")
    if isinstance(y, int) and y > 1880:
        return y
    return _year_from_path(full_path)


class JustWatchAdapter(SearchAdapter):
    name = "justwatch"
    kind = "scrape"
    host = "apis.justwatch.com"

    async def _fetch(self, title_filter: dict, country: str, n: int = 24, record: bool = True) -> list[dict]:
        # language=zh：content.title 直接返回中文译名（无译名自动回退原名），
        # originalTitle 保留英文原名，搜索索引与显示语言无关（英文/日文检索词照常用）
        variables = {"f": title_filter, "c": country, "l": "zh", "p": "IOS", "n": n}
        t0 = time.time()
        try:
            r = await self._client.post(
                GQL_URL, json={"query": QUERY, "variables": variables}, headers=HEADERS
            )
            if r.status_code != 200:
                raise AdapterError(f"HTTP {r.status_code}")
            data = r.json()
            if data.get("errors") and not (data.get("data") or {}).get("popularTitles"):
                raise AdapterError(str(data["errors"][0].get("message", ""))[:120])
            edges = ((data.get("data") or {}).get("popularTitles") or {}).get("edges") or []
            if record:
                self.health.record_ok((time.time() - t0) * 1000)
            return [e["node"] for e in edges if e.get("node")]
        except AdapterError as e:
            if record:
                self.health.record_fail(str(e))
            raise
        except Exception as e:
            if record:
                self.health.record_fail(repr(e)[:120])
            raise AdapterError(repr(e)[:120])

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        # 「所有国家」：美区做发现索引（目录最全），英/日区补查观看渠道后合并
        multi_region = country == "ALL"
        base_country = "US" if multi_region else country
        search_terms = []
        for lang in ("en", "ja", "ko"):
            term = (pq.terms_by_lang.get(lang) or [None])[0]
            if term and term not in search_terms:
                search_terms.append(term)
        if not search_terms:
            search_terms = [pq.search_terms[0] if pq.search_terms else "monster"]

        # 类型：用户显式选择 > 生物隐含类型（消除无类型词时的模糊噪音）
        eff_genre = pq.genre_en or pq.implied_genre_en
        base_filter: dict = {}
        if eff_genre and JW_GENRE_CODES.get(eff_genre):
            base_filter["genres"] = [JW_GENRE_CODES[eff_genre]]
        if pq.year_from:
            base_filter["releaseYear"] = {"min": pq.year_from, "max": pq.year_to or pq.year_from + 9}

        # 主语言（en）全量；非主语言限量补充（去重后每语言最多 8 条新片）
        movies: list[Movie] = []
        seen_keys: set = set()

        def _keys(m: Movie):
            ks = {k for k in m.strong_keys()}
            return ks

        for i, term in enumerate(search_terms[:3]):
            tf = {"searchQuery": term, **base_filter}
            try:
                nodes = await self._fetch(tf, base_country, n=16 if i == 0 else 12,
                                          record=(i == 0))
            except AdapterError:
                if i == 0:
                    raise
                continue
            added = 0
            for node in nodes:
                m = self._to_movie(node, pq)
                ks = _keys(m)
                if ks & seen_keys:
                    continue
                seen_keys |= ks
                movies.append(m)
                added += 1
                if i > 0 and added >= 8:
                    break

        if pq.year_from:  # 双保险：本地再过滤一次（无年份的保留）
            movies = [
                m for m in movies
                if m.year is None or pq.year_from <= m.year <= (pq.year_to or pq.year_from + 9)
            ]
        if multi_region and movies:
            await self._merge_extra_regions(movies, search_terms[0], base_filter)
        return movies

    async def _merge_extra_regions(self, movies: list[Movie], main_term: str, base_filter: dict) -> None:
        """「所有国家」模式：英/日区补查观看渠道，合并进已命中的影片（平台名带地区标记）。"""
        index: dict[str, Movie] = {}
        for m in movies:
            for k in m.strong_keys():
                index.setdefault(k, m)
            index.setdefault(f"t|{_norm_key(m.title)}|{m.year}", m)

        for region in ("GB", "JP"):
            try:
                nodes = await self._fetch({"searchQuery": main_term, **base_filter},
                                          region, n=12, record=False)
            except Exception:
                continue
            for node in nodes:
                tmp = self._to_movie(node, None)
                target = None
                for k in tmp.strong_keys():
                    if k in index:
                        target = index[k]
                        break
                if target is None:
                    target = index.get(f"t|{_norm_key(tmp.title)}|{tmp.year}")
                if target is None:
                    continue
                seen = {o.dedup_key() for o in target.offers}
                for o in tmp.offers:
                    if o.dedup_key() not in seen:
                        o.platform = f"{o.platform}·{region}"
                        target.offers.append(o)
                        seen.add(o.dedup_key())
                target.offers.sort(key=lambda o: (
                    {"free": 0, "sub": 1, "rent": 2, "buy": 3, "other": 4}.get(o.kind, 9), o.platform))

    async def resolve_title(self, title: str, country: str, pq: ParsedQuery | None = None) -> list[Movie]:
        """标题 → 完整条目（含观看地址）。供 Yandex 等发现型通道回链解析用，
        失败不影响本源健康度。"""
        try:
            nodes = await self._fetch({"searchQuery": title}, country, n=3, record=False)
        except Exception:
            return []
        return [self._to_movie(n, pq) for n in nodes]

    def _to_movie(self, node: dict, pq: ParsedQuery | None) -> Movie:
        c = node.get("content") or {}
        scoring = c.get("scoring") or {}
        ext = c.get("externalIds") or {}
        genres = []
        for g in c.get("genres") or []:
            genres.append(g.get("translation") or g.get("shortName") or "")

        offers, seen = [], set()
        for o in node.get("offers") or []:
            pkg = o.get("package") or {}
            pkg_name = pkg.get("clearName") or pkg.get("shortName") or pkg.get("technicalName") or "?"
            kind = MONETIZATION_KIND.get(o.get("monetizationType") or "", "other")
            url = o.get("standardWebURL") or ""
            price = ""
            if o.get("retailPrice") is not None:
                price = f"{o.get('retailPrice')} {o.get('currency') or ''}".strip()
            off = Offer(platform=pkg_name, kind=kind, url=url, price=price)
            if not url or off.dedup_key() in seen:
                continue
            seen.add(off.dedup_key())
            offers.append(off)
        offers.sort(key=lambda o: (
            {"free": 0, "sub": 1, "rent": 2, "buy": 3, "other": 4}.get(o.kind, 9), o.platform))

        full_path = c.get("fullPath") or ""
        poster = ""
        if c.get("posterUrl"):
            poster = f"{IMG_PREFIX}{c['posterUrl']}".replace("{profile}", "s332")

        return Movie(
            title=_to_simplified(c.get("title") or ""),
            original_title=c.get("originalTitle") or "",
            year=ext_year(c, full_path),
            poster=poster,
            overview=(c.get("shortDescription") or "")[:300],
            imdb_id=ext.get("imdbId") or "",
            tmdb_id=str(ext.get("tmdbId") or ""),
            ratings={"imdb": scoring.get("imdbScore")},
            imdb_votes=int(scoring.get("imdbVotes") or 0),
            genres=[g for g in genres if g],
            creatures=list(pq.creatures) if pq else [],
            sources=["justwatch"],
            links={"JustWatch": f"https://www.justwatch.com{full_path}"} if full_path else {},
            offers=offers,
        )
