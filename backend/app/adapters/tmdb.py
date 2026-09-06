"""TMDB 适配器（官方 API 线）。

需要 TMDB_API_KEY（https://www.themoviedb.org/settings/api 免费申请）。
用 keyword 搜索 + discover 组合实现「类型 × 生物关键词」结构化检索，
返回中文标题与简介（language=zh-CN）。无 key 或网络不通时自动禁用。
"""
from __future__ import annotations

import os
import time

from ..models import Movie
from ..taxonomy import ParsedQuery, TMDB_GENRE_IDS
from .base import AdapterError, SearchAdapter

API = "https://api.themoviedb.org/3"
IMG = "https://image.tmdb.org/t/p/w500"


class TmdbAdapter(SearchAdapter):
    name = "tmdb"
    kind = "official"
    key_env = "TMDB_API_KEY"
    host = "api.themoviedb.org"

    def __init__(self) -> None:
        super().__init__()
        self._genre_names: dict[int, str] | None = None

    async def _api(self, path: str, key: str, **params) -> dict:
        params["api_key"] = key
        r = await self._get(f"{API}{path}", params=params)
        if r.status_code == 401:
            raise AdapterError("invalid API key")
        if r.status_code != 200:
            raise AdapterError(f"HTTP {r.status_code} on {path}")
        return r.json()

    async def _genre_map(self, key: str) -> dict[int, str]:
        if self._genre_names is None:
            try:
                data = await self._api("/genre/movie/list", key, language="zh-CN")
                self._genre_names = {g["id"]: g["name"] for g in data.get("genres", [])}
            except Exception:
                self._genre_names = {}
        return self._genre_names

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        key = os.environ["TMDB_API_KEY"]
        t0 = time.time()
        try:
            # 1) 生物词 → keyword id（TMDB 关键词体系：zombie/undead 各自独立）
            kw_ids: list[str] = []
            for term in pq.search_terms[:3]:
                data = await self._api("/search/keyword", key, query=term)
                kw_ids += [str(k["id"]) for k in data.get("results", [])[:2]]
            # 2) discover：类型 + 关键词(OR) + 年代
            params: dict = {
                "sort_by": "popularity.desc", "language": "zh-CN",
                "include_adult": "false",
            }
            if pq.genre_en and TMDB_GENRE_IDS.get(pq.genre_en):
                params["with_genres"] = str(TMDB_GENRE_IDS[pq.genre_en])
            if kw_ids:
                params["with_keywords"] = "|".join(dict.fromkeys(kw_ids))  # | = OR
            if pq.year_from:
                params["primary_release_date.gte"] = f"{pq.year_from}-01-01"
                params["primary_release_date.lte"] = f"{pq.year_to or pq.year_from}-12-31"
            data = await self._api("/discover/movie", key, **params)
            genre_map = await self._genre_map(key)

            movies = []
            for item in data.get("results", [])[:24]:
                year = None
                if item.get("release_date"):
                    year = int(item["release_date"][:4])
                movies.append(Movie(
                    title=item.get("title") or item.get("original_title") or "",
                    original_title=item.get("original_title") or "",
                    year=year,
                    poster=f"{IMG}{item['poster_path']}" if item.get("poster_path") else "",
                    overview=item.get("overview") or "",
                    tmdb_id=str(item.get("id") or ""),
                    ratings={"tmdb": round(item.get("vote_average") or 0, 1)},
                    genres=[genre_map.get(gid, "") for gid in item.get("genre_ids", [])],
                    creatures=list(pq.creatures),
                    sources=["tmdb"],
                    links={"TMDB": f"https://www.themoviedb.org/movie/{item.get('id')}"},
                ))
            self.health.record_ok((time.time() - t0) * 1000)
            return movies
        except AdapterError as e:
            self.health.record_fail(str(e))
            raise
        except Exception as e:
            self.health.record_fail(repr(e)[:120])
            raise AdapterError(repr(e)[:120])
