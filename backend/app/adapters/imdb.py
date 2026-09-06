"""IMDb 适配器（爬虫线）。

爬 IMDb 高级搜索页（关键词 × 类型 × 年代），SSR HTML，bs4 解析。
注意：IMDb 对数据中心 IP 有反爬挑战（返回极小的挑战页），本适配器
检测到挑战页会主动报错并优雅降级——在住宅 IP / 配置代理的环境下工作正常。
可用环境变量 HTTP_PROXY 走代理。
"""
from __future__ import annotations

import re
import time
from urllib.parse import quote_plus

from bs4 import BeautifulSoup

from ..models import Movie
from ..taxonomy import ParsedQuery
from .base import AdapterError, SearchAdapter

BASE = "https://www.imdb.com/search/title/"


class ImdbAdapter(SearchAdapter):
    name = "imdb"
    kind = "scrape"
    host = "www.imdb.com"

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        params = ["title_type=feature,tv_movie", "sort=user_rating,desc", "numVotes=2000"]
        if pq.search_terms:
            params.append("keywords=" + quote_plus(",".join(pq.search_terms[:2])))
        if pq.genre_en:
            params.append("genres=" + quote_plus(pq.genre_en))
        if pq.year_from:
            params.append(f"release_date={pq.year_from}-01-01,{(pq.year_to or pq.year_from)}-12-31")
        url = BASE + "?" + "&".join(params)

        t0 = time.time()
        r = await self._get(url)
        if r.status_code != 200 or len(r.text) < 30_000:
            # 反爬挑战页通常只有 ~2KB
            self.health.record_fail(f"blocked or challenge page (HTTP {r.status_code}, {len(r.text)}B)")
            raise AdapterError("imdb anti-bot challenge")

        soup = BeautifulSoup(r.text, "html.parser")
        movies: list[Movie] = []
        for li in soup.select("li.ipc-metadata-list-summary-item")[:20]:
            h = li.select_one("h3.ipc-title__text")
            if not h:
                continue
            # 形如 "1. Night of the Living Dead (1968)"，或无年份
            text = re.sub(r"^\d+\.\s*", "", h.get_text(strip=True))
            m = re.match(r"(.+?)\s*\((\d{4})\)\s*$", text)
            title, year = (m.group(1), int(m.group(2))) if m else (text, None)
            link = li.select_one("a[href*='/title/tt']")
            imdb_id = ""
            if link and (mt := re.search(r"/title/(tt\d+)", link.get("href", ""))):
                imdb_id = mt.group(1)
            movies.append(Movie(
                title=title, year=year, imdb_id=imdb_id,
                genres=[pq.genre_en] if pq.genre_en else [],
                creatures=list(pq.creatures),
                sources=["imdb"],
                links={"IMDb": f"https://www.imdb.com/title/{imdb_id}"} if imdb_id else {},
            ))
        if not movies:
            self.health.record_fail("no results parsed")
            raise AdapterError("imdb parse failed")
        self.health.record_ok((time.time() - t0) * 1000)
        return movies
