"""Letterboxd 适配器（爬虫线）。

爬标签浏览页 /films/tags/{生物词}/（社区人工标注的生物标签，质量很高，
很多 JustWatch/TMDB 检索不到的邪典片这里有）。Cloudflare 防护较严，
被拦时报错降级；住宅 IP 或代理环境下可用。
"""
from __future__ import annotations

import re
import time

from bs4 import BeautifulSoup

from ..models import Movie
from ..taxonomy import ParsedQuery
from .base import AdapterError, SearchAdapter

BASE = "https://letterboxd.com"


class LetterboxdAdapter(SearchAdapter):
    name = "letterboxd"
    kind = "scrape"
    host = "letterboxd.com"

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        term = pq.search_terms[0] if pq.search_terms else "monster"
        url = f"{BASE}/films/tags/{re.sub(r'[^a-z0-9-]+', '-', term.lower())}/"
        t0 = time.time()
        r = await self._get(url)
        if r.status_code == 403:
            self.health.record_fail("cloudflare 403")
            raise AdapterError("letterboxd blocked (403)")
        if r.status_code != 200 or len(r.text) < 10_000:
            self.health.record_fail(f"HTTP {r.status_code}")
            raise AdapterError(f"letterboxd HTTP {r.status_code}")

        soup = BeautifulSoup(r.text, "html.parser")
        movies: list[Movie] = []
        seen: set[str] = set()
        for img in soup.select("img.film-poster, div.film-poster img"):
            title = (img.get("alt") or "").strip()
            if not title or title.lower() in seen:
                continue
            seen.add(title.lower())
            movies.append(Movie(
                title=title,
                creatures=list(pq.creatures),
                sources=["letterboxd"],
                links={"Letterboxd": f"{BASE}/search/films/{title.replace(' ', '+')}/"},
            ))
            if len(movies) >= 20:
                break
        if not movies:
            self.health.record_fail("no results parsed")
            raise AdapterError("letterboxd parse failed")
        self.health.record_ok((time.time() - t0) * 1000)
        return movies
