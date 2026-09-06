"""OMDb 适配器（官方 API 线 · 增强器）。

需要 OMDB_API_KEY（https://www.omdbapi.com/apikey.aspx 免费 1000 次/天）。
不参与搜索，只在合并后为带有 imdb_id 的结果补充 IMDb 评分 / Metascore / 烂番茄。
"""
from __future__ import annotations

import os
import time

from ..models import Movie
from .base import AdapterError, EnrichAdapter

API = "https://www.omdbapi.com/"


class OmdbAdapter(EnrichAdapter):
    name = "omdb"
    kind = "official"
    key_env = "OMDB_API_KEY"
    host = "www.omdbapi.com"

    async def enrich(self, movies: list[Movie]) -> list[Movie]:
        key = os.environ.get("OMDB_API_KEY")
        if not key:
            return movies
        # 只补前 12 个，省配额（结果已按分数排序）
        for m in movies[:12]:
            if not m.imdb_id or m.ratings.get("imdb"):
                continue
            try:
                t0 = time.time()
                r = await self._get(API, params={"i": m.imdb_id, "apikey": key})
                if r.status_code == 200 and r.json().get("Response") == "True":
                    d = r.json()
                    if d.get("imdbRating") and d["imdbRating"] != "N/A":
                        m.ratings["imdb"] = float(d["imdbRating"])
                    if d.get("imdbVotes") and d["imdbVotes"] != "N/A":
                        m.imdb_votes = int(d["imdbVotes"].replace(",", ""))
                    if d.get("Metascore") and d["Metascore"] != "N/A":
                        m.ratings["metascore"] = int(d["Metascore"])
                    for src in d.get("Ratings", []):
                        if src.get("Source") == "Rotten Tomatoes":
                            m.ratings["rt"] = int(str(src.get("Value", "0")).rstrip("%"))
                    self.health.record_ok((time.time() - t0) * 1000)
            except Exception as e:
                self.health.record_fail(repr(e)[:100])
        return movies
