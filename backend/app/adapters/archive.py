"""Internet Archive 适配器（爬虫线 · 公共领域免费片）。

版权过期的老恐怖片宝库（如 1968 前的不少经典），官方 JSON API，
返回的详情页本身就是合法免费播放地址。作为「没会员也能看」的正版补充。
"""
from __future__ import annotations

import time

from ..models import Movie, Offer
from ..taxonomy import ParsedQuery
from .base import AdapterError, SearchAdapter

API = "https://archive.org/advancedsearch.php"


class ArchiveAdapter(SearchAdapter):
    name = "archive"
    kind = "scrape"
    host = "archive.org"

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        term = (pq.search_terms[:1] or ["monster"])[0]
        params = {
            "q": f'title:("{term}") AND mediatype:(movies)',
            "fl[]": ["identifier", "title", "year"],
            "rows": "12", "page": "1", "output": "json",
        }
        t0 = time.time()
        r = await self._get(API, params=params)
        if r.status_code != 200:
            self.health.record_fail(f"HTTP {r.status_code}")
            raise AdapterError(f"archive HTTP {r.status_code}")
        docs = (r.json().get("response") or {}).get("docs") or []
        movies = []
        for d in docs:
            ident = d.get("identifier", "")
            url = f"https://archive.org/details/{ident}"
            year = d.get("year")
            year = int(str(year)[:4]) if str(year or "")[:4].isdigit() else None
            movies.append(Movie(
                title=str(d.get("title") or "").split(" / ")[0],
                year=year,
                creatures=list(pq.creatures),
                sources=["archive"],
                links={"Internet Archive": url},
                offers=[Offer(platform="Internet Archive", kind="free", url=url)],
            ))
        if not movies:
            self.health.record_fail("no results")
            raise AdapterError("archive no results")
        self.health.record_ok((time.time() - t0) * 1000)
        return movies
