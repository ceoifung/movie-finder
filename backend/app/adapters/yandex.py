"""Yandex 适配器（多语言发现通道）。

思路：中文查询 → 依托本体库自动得到 中/英/日/韩 检索词（自由文本走翻译），
用各语言在 Yandex 上搜片单/影评页，从结果标题与摘要中抽取电影名候选，
再回 JustWatch 逐个解析成带观看地址的完整条目。

双模式：
- 官方模式：设置 YANDEX_API_KEY + YANDEX_XML_USER（Yandex Search API，稳定无验证码）
- 爬虫模式：直接抓 yandex.com/search/ 页面（数据中心 IP 会触发 SmartCaptcha，
  检测到即报错降级，住宅 IP / 代理环境可用）
"""
from __future__ import annotations

import asyncio
import os
import re
import time
import urllib.parse
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

from bs4 import BeautifulSoup

from ..models import Movie
from ..taxonomy import MOVIE_WORDS, ParsedQuery
from ..translate import translate
from .base import AdapterError, SearchAdapter

SCRAPE_URL = "https://yandex.com/search/"
XML_URL = "https://yandex.ru/search/xml"

_executor = ThreadPoolExecutor(max_workers=2)

# 从搜索结果文本中抽取电影名候选的模式
CJK_PATTERNS = [r"《([^《》]{1,40})》", r"「([^「」]{1,40})」", r"『([^『』]{1,40})』"]
LATIN_PATTERNS = [
    r'"([^"]{2,60})"',
    r"\b([A-Z][A-Za-z0-9'’&:!?.\-]*(?:\s+[A-Za-z0-9'’&:!?.\-]+){1,9}\s*\((?:19|20)\d{2}\))\b",
]
STOP_SUBSTR = [
    "豆瓣", "片单", "排行", "推荐", "合集", "维基", "百科", "影单", "必看", "评分", "预告",
    "wiki", "best", "top ", "list", "rank", "movies", "movie", "film", "horror", "imdb",
    "rotten", "watch", "trailer", "scene", "순위", "추천", "영화", "예고", "명작",
    "おすすめ", "映画", "ランキング", "ジャンル", "レビュー",
]


def extract_titles(texts: list[str]) -> list[str]:
    candidates: list[str] = []
    for text in texts:
        for pat in CJK_PATTERNS + LATIN_PATTERNS:
            candidates += re.findall(pat, text)
    out, seen = [], set()
    for cand in candidates:
        c = cand.strip().rstrip(".,!?…～~ ").strip()
        low = c.lower()
        if not (1 <= len(c) <= 60) or c in seen:
            continue
        if not re.search(r"[a-zA-Z\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]", c):
            continue
        if any(s in low for s in STOP_SUBSTR):
            continue
        seen.add(c)
        out.append(c)
        if len(out) >= 12:
            break
    return out


class YandexAdapter(SearchAdapter):
    name = "yandex"
    kind = "scrape"
    host = "yandex.com"
    timeout_s = 30.0  # 多语言多轮请求，给更长预算

    def __init__(self, resolver=None):
        super().__init__()
        self._resolver = resolver  # JustWatchAdapter.resolve_title

    def _official(self) -> bool:
        return bool(os.environ.get("YANDEX_API_KEY"))

    async def _search_one(self, query: str) -> list[tuple[str, str]]:
        """返回 [(title, snippet), ...]。"""
        if self._official():
            params = {
                "user": os.environ.get("YANDEX_XML_USER", ""),
                "key": os.environ["YANDEX_API_KEY"],
                "query": query, "l10n": "en", "filter": "strict",
                "groupby": "attr=().mode=flat.groups=10",
            }
            r = await self._get(XML_URL, params=params)
            if r.status_code != 200:
                raise AdapterError(f"yandex api HTTP {r.status_code}")
            root = ET.fromstring(r.text)
            out = []
            for doc in root.iter("doc"):
                t = "".join(doc.findtext("title", default="", ).split()) or ""
                t = re.sub(r"<[^>]+>", "", t)
                passages = [re.sub(r"<[^>]+>", "", p.text or "") for p in doc.iter("passage")]
                out.append((t, " ".join(passages)))
            return out

        # 爬虫模式
        r = await self._get(SCRAPE_URL, params={"text": query, "lr": 87})
        if "showcaptcha" in str(r.url) or "SmartCaptcha" in r.text[:6000] or r.status_code == 403:
            raise AdapterError("yandex captcha / blocked")
        if r.status_code != 200:
            raise AdapterError(f"yandex HTTP {r.status_code}")
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(_executor, self._parse_html, r.text)

    @staticmethod
    def _parse_html(html: str) -> list[tuple[str, str]]:
        soup = BeautifulSoup(html, "html.parser")
        out = []
        for item in soup.select("li.serp-item, li.OrganicItem"):
            title_el = item.select_one("h2 a, a.OrganicTitle-Link, .OrganicTitle-LinkText")
            snip_el = item.select_one(".OrganicTextContentSpan, .Organic-ContentWrapper, .TextContainer")
            title = title_el.get_text(" ", strip=True) if title_el else ""
            snippet = snip_el.get_text(" ", strip=True) if snip_el else ""
            if title or snippet:
                out.append((title, snippet))
        if not out:  # 选择器漂移时的兜底：抓所有 h2
            for h in soup.select("h2"):
                out.append((h.get_text(" ", strip=True), ""))
        return out[:15]

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        # 1) 构造各语言查询：本体词优先，无生物词时翻译自由文本
        queries: list[tuple[str, str]] = []  # (lang, query)
        for lang in ("en", "ja", "ko", "zh"):
            term = (pq.terms_by_lang.get(lang) or [None])[0]
            if term:
                queries.append((lang, f"{term} {MOVIE_WORDS[lang]}"))
        if not queries and pq.raw:
            queries.append(("zh", f"{pq.raw} {MOVIE_WORDS['zh']}"))
            for tgt in ("en", "ja", "ko"):
                t = await translate(pq.raw, tgt)
                if t:
                    queries.append((tgt, f"{t} {MOVIE_WORDS[tgt]}"))

        t0 = time.time()
        # 2) 多语言并发搜索（官方模式可并发；爬虫模式节流防验证码）
        results: list[tuple[str, str]] = []
        if self._official():
            got = await asyncio.gather(
                *[self._search_one(q) for _, q in queries[:4]], return_exceptions=True
            )
            for g in got:
                if isinstance(g, list):
                    results += g
            if not results:
                self.health.record_fail("yandex api empty")
                raise AdapterError("yandex api empty")
        else:
            for _, q in queries[:4]:
                results += await self._search_one(q)  # 失败即抛错降级

        # 3) 抽取电影名候选
        texts = [t for title, snip in results for t in (title, snip) if t]
        candidates = extract_titles(texts)
        if not candidates:
            self.health.record_fail(f"no titles from {len(results)} pages")
            raise AdapterError("yandex no titles extracted")

        # 4) 回链解析：候选标题 → JustWatch 完整条目（含观看地址）
        movies: list[Movie] = []
        if self._resolver:
            sem = asyncio.Semaphore(5)

            async def resolve(cand: str):
                async with sem:
                    ms = await self._resolver(cand, country, pq)
                    return ms[0] if ms else None

            got = await asyncio.gather(*[resolve(c) for c in candidates[:8]])
            for m in got:
                if m and m.title:
                    m.sources = ["yandex"]
                    movies.append(m)

        self.health.record_ok((time.time() - t0) * 1000)
        if not movies:
            # 搜到了页面但没解析出电影——不算失败，返回空让聚合层决定
            return []
        return movies
