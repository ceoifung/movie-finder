"""WhatIsMyMovie (Valossa AI) 适配器（语义搜索通道）。

专治描述式查询：「背景在荒山中，主角叫拿破仑的恐怖电影」这类自然语言
交给它的 AI 语义引擎（整句翻译成英文后发送），返回按剧情相关度排序的片名。

双模式：
- 网页爬取（默认，免 key）：GET /results?text={英文描述}，结果卡片为 SSR，
  panel-title 格式 "Title (Year)"，过滤 "More like this" 导航项；
- 官方 API：设 WIMM_API_KEY 后走 apiguide 的 JSON 接口。
"""
from __future__ import annotations

import asyncio
import os
import re
import time
from urllib.parse import quote

from bs4 import BeautifulSoup

from ..models import Movie
from ..taxonomy import ParsedQuery
from ..translate import translate
from .base import AdapterError, SearchAdapter

WEB_URL = "https://whatismymovie.com/results?text={q}"

_TITLE_YEAR_RE = re.compile(r"^(.{2,80}?)\s*[\(（](\d{4})[\)）]\s*$")


class WhatIsMyMovieAdapter(SearchAdapter):
    name = "whatismymovie"
    kind = "scrape"
    host = "whatismymovie.com"
    timeout_s = 30.0

    def __init__(self, resolver=None):
        super().__init__()
        self._resolver = resolver  # JustWatchAdapter.resolve_title

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        # 语义通道只对描述式查询生效（生物标签类查询其他源覆盖得更好）
        if not pq.descriptive and not pq.raw:
            raise AdapterError("skip: only for descriptive queries")

        # 描述翻译成英文（Valossa 引擎英文效果最好）
        text = pq.raw.strip()
        if re.search(r"[\u4e00-\u9fff]", text):
            t = await translate(text, "en")
            if t:
                text = t

        t0 = time.time()
        titles: list[tuple[str, int | None]] = []
        key = os.environ.get("WIMM_API_KEY")
        if key:
            base = os.environ.get("WIMM_API_URL", "https://whatismymovie.com/api/v1/search")
            r = await self._get(base, params={"api_key": key, "text": text})
            if r.status_code != 200:
                raise AdapterError(f"wimm api HTTP {r.status_code}")
            data = r.json()
            for it in (data.get("results") or data.get("movies") or [])[:20]:
                y = it.get("year")
                titles.append((it.get("title") or "", int(y) if str(y or "").isdigit() else None))
        else:
            r = await self._get(WEB_URL.format(q=quote(text)))
            if r.status_code != 200:
                raise AdapterError(f"wimm HTTP {r.status_code}")
            loop = asyncio.get_event_loop()
            titles = await loop.run_in_executor(None, self._parse_html, r.text)

        titles = [(t, y) for t, y in titles if t and "more like this" not in t.lower()]
        if not titles:
            self.health.record_fail(f"no titles parsed ({len(titles)})")
            raise AdapterError("wimm no results")

        # 回链解析：语义命中的片名 -> JustWatch 完整条目（海报+评分+观看地址）
        movies: list[Movie] = []
        if self._resolver:
            sem = asyncio.Semaphore(5)

            async def resolve(title: str, year: int | None):
                async with sem:
                    ms = await self._resolver(title, country, pq)
                    for m in ms:
                        if year and m.year and abs(m.year - year) > 1:
                            continue
                        return m
                    return None

            got = await asyncio.gather(*[resolve(t, y) for t, y in titles[:10]])
            for m in got:
                if m and m.title:
                    m.sources = ["whatismymovie"]
                    movies.append(m)

        self.health.record_ok((time.time() - t0) * 1000)
        return movies

    @staticmethod
    def _parse_html(html: str) -> list[tuple[str, int | None]]:
        soup = BeautifulSoup(html, "html.parser")
        out, seen = [], set()
        for el in soup.select(".panel-title"):
            text = el.get_text(" ", strip=True)
            if not text or text.lower() in seen:
                continue
            seen.add(text.lower())
            if (m := _TITLE_YEAR_RE.match(text)):
                out.append((m.group(1).strip(), int(m.group(2))))
            elif 2 <= len(text) <= 80 and "more like" not in text.lower():
                out.append((text, None))
        return out[:20]
