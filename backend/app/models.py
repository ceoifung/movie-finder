"""统一电影数据模型：所有适配器的输出都归一化成 Movie，供聚合层去重合并。"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field


class Offer(BaseModel):
    """观看地址（仅正版渠道）。"""
    platform: str                 # 平台名，如 Netflix / Tubi
    kind: str                     # free / sub / rent / buy / other
    url: str = ""                 # 平台深度链接
    price: str = ""               # "3.99 USD" 等

    def dedup_key(self) -> tuple:
        return (self.platform.lower(), self.kind, self.url)


class WebLink(BaseModel):
    """片名相关的网页链接（来自 Bing/DuckDuckGo 检索）。"""
    title: str
    url: str


class Movie(BaseModel):
    title: str
    original_title: str = ""
    year: Optional[int] = None
    poster: str = ""
    overview: str = ""
    imdb_id: str = ""
    tmdb_id: str = ""
    ratings: dict = Field(default_factory=dict)   # {"imdb": 7.9, "tmdb": 8.0, "metascore": 87}
    imdb_votes: int = 0
    genres: list[str] = Field(default_factory=list)
    creatures: list[str] = Field(default_factory=list)   # 命中的生物分类（中文规范名）
    sources: list[str] = Field(default_factory=list)     # ["justwatch", "tmdb", ...]
    links: dict = Field(default_factory=dict)            # {"TMDB": url, "JustWatch": url}
    offers: list[Offer] = Field(default_factory=list)
    web_links: list[WebLink] = Field(default_factory=list)  # 片名检索到的网页链接
    score: float = 0.0

    def strong_keys(self) -> list[str]:
        keys = []
        if self.imdb_id:
            keys.append(f"imdb:{self.imdb_id}")
        if self.tmdb_id:
            keys.append(f"tmdb:{self.tmdb_id}")
        return keys

    def has_free(self) -> bool:
        return any(o.kind == "free" for o in self.offers)


# 排序权重：免费 > 订阅 > 租 > 买
OFFER_KIND_ORDER = {"free": 0, "sub": 1, "rent": 2, "buy": 3, "other": 4}
OFFER_KIND_ZH = {
    "free": "免费", "sub": "订阅", "rent": "租", "buy": "买", "other": "其他",
}
