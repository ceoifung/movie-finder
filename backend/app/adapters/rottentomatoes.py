"""烂番茄适配器（爬虫线）。

尝试其前端私有搜索接口 /api/private/search/pagesearch。被拦时降级。
"""
from __future__ import annotations

import time

from ..models import Movie
from ..taxonomy import ParsedQuery
from .base import AdapterError, SearchAdapter

API = "https://www.rottentomatoes.com/api/private/search/pagesearch"


class RottenTomatoesAdapter(SearchAdapter):
    name = "rottentomatoes"
    kind = "scrape"
    host = "www.rottentomatoes.com"

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        q = " ".join(pq.search_terms[:2] + ([pq.genre_en] if pq.genre_en else []))
        t0 = time.time()
        r = await self._get(API, params={"q": q, "offset": 0, "limit": 20, "type": "movies"})
        if r.status_code != 200:
            self.health.record_fail(f"HTTP {r.status_code}")
            raise AdapterError(f"rotten tomatoes HTTP {r.status_code}")
        data = r.json()
        groups = data.get("groups") or []
        movies: list[Movie] = []
        for g in groups:
            if "movie" not in (g.get("type") or g.get("groupName") or "").lower():
                continue
            for it in (g.get("searchCmsItems") or g.get("movies") or [])[:20]:
                title = it.get("name") or ""
                year = it.get("startYear") or it.get("productionYear")
                url = it.get("url") or ""
                if not title:
                    continue
                movies.append(Movie(
                    title=title,
                    year=int(year) if str(year or "").isdigit() else None,
                    creatures=list(pq.creatures),
                    sources=["rottentomatoes"],
                    links={"Rotten Tomatoes": url} if url else {},
                ))
        if not movies:
            self.health.record_fail("no results parsed")
            raise AdapterError("rotten tomatoes parse failed")
        self.health.record_ok((time.time() - t0) * 1000)
        return movies
