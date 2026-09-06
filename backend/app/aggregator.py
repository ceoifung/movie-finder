"""聚合层：并发扇出 → 归一化 → 多源去重合并 → 排序 → 缓存。"""
from __future__ import annotations

import asyncio
import re
import time
import unicodedata

from .adapters import ENRICH_ADAPTERS, SEARCH_ADAPTERS
from .models import Movie
from .taxonomy import ParsedQuery
from .translate import translate
from .weblinks import enrich_web_links

CACHE_TTL = 6 * 3600
CACHE_MAX = 500
ADAPTER_TIMEOUT = 9.0

_cache: dict[str, tuple[float, dict]] = {}

OFFER_ORDER = {"free": 0, "sub": 1, "rent": 2, "buy": 3, "other": 4}


def norm_title(t: str) -> str:
    t = unicodedata.normalize("NFKD", (t or "").lower())
    t = re.sub(r"[^\w]+", " ", t)
    t = re.sub(r"^(the|a|an|le|la|les|el|los)\s+", "", t.strip())
    return " ".join(t.split())


def _has_cjk(s: str) -> bool:
    return any("\u4e00" <= ch <= "\u9fff" for ch in (s or ""))


def _year_compatible(a: Movie, b: Movie) -> bool:
    if not a.year or not b.year:
        return True
    return abs(a.year - b.year) <= 1


def _dedup(seq: list[str]) -> list[str]:
    seen, out = set(), []
    for x in seq:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


def _absorb(base: Movie, m: Movie) -> None:
    """把 m 的信息合并进 base。"""
    # 标题：优先中文标题（TMDB zh-CN 结果），英文留作 original_title
    if _has_cjk(m.title) and not _has_cjk(base.title):
        if not base.original_title and base.title:
            base.original_title = base.title
        base.title = m.title
    if not base.title and m.title:
        base.title = m.title
    for f in ("original_title", "poster", "overview", "imdb_id", "tmdb_id"):
        if not getattr(base, f):
            setattr(base, f, getattr(m, f))
    if not base.year and m.year:
        base.year = m.year
    for k, v in (m.ratings or {}).items():
        if v is not None and base.ratings.get(k) is None:
            base.ratings[k] = v
    base.imdb_votes = max(base.imdb_votes or 0, m.imdb_votes or 0)
    base.genres = _dedup(base.genres + m.genres)
    base.creatures = _dedup(base.creatures + m.creatures)
    base.sources = _dedup(base.sources + m.sources)
    for k, v in (m.links or {}).items():
        if v:
            base.links[k] = v
    seen = {o.dedup_key() for o in base.offers}
    for o in m.offers:
        if o.dedup_key() not in seen:
            base.offers.append(o)
            seen.add(o.dedup_key())
    base.offers.sort(key=lambda o: (OFFER_ORDER.get(o.kind, 9), o.platform))


def merge_movies(lists: list[list[Movie]]) -> list[Movie]:
    by_key: dict[str, Movie] = {}
    by_title: dict[str, list[Movie]] = {}
    out: list[Movie] = []
    for movies in lists:
        for m in movies:
            if not (m.title or m.original_title):
                continue
            target = None
            for k in m.strong_keys():
                if k in by_key:
                    target = by_key[k]
                    break
            if target is None:
                nt = norm_title(m.title) or norm_title(m.original_title)
                for cand in by_title.get(nt, []):
                    if _year_compatible(cand, m):
                        target = cand
                        break
            if target is None:
                out.append(m)
                nt = norm_title(m.title) or norm_title(m.original_title)
                if nt:
                    by_title.setdefault(nt, []).append(m)
                for k in m.strong_keys():
                    by_key[k] = m
            else:
                _absorb(target, m)
                for k in m.strong_keys():
                    by_key[k] = target
    return out


def compute_score(m: Movie) -> float:
    """多源命中数为主，评分与免费可看加权。"""
    s = 2.5 * len(m.sources)
    r = m.ratings or {}
    s += (r.get("imdb") or 0) * 1.2
    s += (r.get("tmdb") or 0) * 0.4
    s += min(3.0, (m.imdb_votes or 0) / 100_000)
    if m.has_free():
        s += 2.0
    elif any(o.kind == "sub" for o in m.offers):
        s += 0.5
    if m.year:
        s += max(0.0, min(6.5, (m.year - 1960) / 10))
    return round(s, 3)


async def _translate_entities(pq: ParsedQuery) -> None:
    """描述式查询：把中文实体名（拿破仑→napoleon）翻译成英文检索词。"""
    if not pq.descriptive or not pq.entities:
        return
    translated = []
    for e in pq.entities:
        t = await translate(e, "en")
        translated.append(t.lower().strip() if t else e)
    pq.entities_en = translated
    # JustWatch 只喂实体词（单实体词检索效果最好）；场景词由语义通道（WIMM/Yandex）消化
    pq.search_terms = translated
    pq.terms_by_lang["en"] = translated


async def search(pq: ParsedQuery, country: str, free_only: bool, limit: int) -> dict:
    await _translate_entities(pq)
    ck = pq.cache_key(country, free_only)
    now = time.time()
    if ck in _cache and _cache[ck][0] > now:
        data = dict(_cache[ck][1])
        data["cached"] = True
        return data

    active = [a for a in SEARCH_ADAPTERS if a.available()]
    # 「所有国家」：JustWatch 内部做多区合并，其余源统一用美区
    effective_country = "US" if country == "ALL" else country
    t0 = time.time()

    async def _run(adapter):
        c_arg = country if adapter.name == "justwatch" else effective_country
        try:
            return adapter, await asyncio.wait_for(
                adapter.search(pq, c_arg), getattr(adapter, "timeout_s", ADAPTER_TIMEOUT)
            ), None
        except asyncio.TimeoutError:
            return adapter, None, "timeout"
        except Exception as e:
            return adapter, None, str(e)[:120]

    outcomes = await asyncio.gather(*[_run(a) for a in active])

    lists, sources_status = [], []
    for adapter, movies, err in outcomes:
        skipped = bool(err and err.startswith("skip:"))
        if err and err != "timeout" and not skipped and adapter.health.last_error is None:
            adapter.health.record_fail(err)
        entry = {
            "kind": adapter.kind,
            "enabled": adapter.enabled(),
            **adapter.health.to_dict(),
        }
        if movies:
            entry["results"] = len(movies)
            lists.append(movies)
        else:
            entry["results"] = 0
            if skipped:
                entry["skipped"] = True
            else:
                entry["error"] = adapter.health.last_error or err
        sources_status.append({adapter.name: entry})

    merged = merge_movies(lists)
    for m in merged:
        m.score = compute_score(m)
    merged.sort(key=lambda m: m.score, reverse=True)
    if free_only:
        merged = [m for m in merged if m.has_free()]
    merged = merged[:limit]

    # 网页链接富集：片名 → Bing/DDG 检索出的在线播放/相关网站（豆瓣/bilibili/百科等）
    try:
        await asyncio.wait_for(enrich_web_links(merged), 28)
    except Exception:
        pass

    # 增强阶段（OMDb 补评分等），失败不影响主结果
    for enricher in ENRICH_ADAPTERS:
        if enricher.available():
            try:
                merged = await asyncio.wait_for(enricher.enrich(merged), ADAPTER_TIMEOUT)
                merged.sort(key=lambda m: m.score, reverse=True)
            except Exception:
                pass

    took_ms = int((time.time() - t0) * 1000)
    result = {
        "query": {
            "raw": pq.raw,
            "descriptive": pq.descriptive,
            "entities": pq.entities,
            "entities_en": pq.entities_en,
            "creatures": pq.creatures,
            "search_terms": pq.search_terms,
            "terms_by_lang": pq.terms_by_lang,
            "genre": pq.genre_zh,
            "year_from": pq.year_from,
            "year_to": pq.year_to,
        },
        "results": [m.model_dump() for m in merged],
        "sources": sources_status,
        "took_ms": took_ms,
        "cached": False,
    }

    # 简单 LRU：超容丢最旧
    if len(_cache) >= CACHE_MAX:
        for k in sorted(_cache, key=lambda k: _cache[k][0])[: CACHE_MAX // 4]:
            _cache.pop(k, None)
    _cache[ck] = (now + CACHE_TTL, result)
    return result
