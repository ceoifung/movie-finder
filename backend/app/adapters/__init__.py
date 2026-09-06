"""适配器注册表：新增数据源 = 写一个类 + 加进这两张表。"""
from __future__ import annotations

from .archive import ArchiveAdapter
from .base import SearchAdapter
from .imdb import ImdbAdapter
from .justwatch import JustWatchAdapter
from .letterboxd import LetterboxdAdapter
from .omdb import OmdbAdapter
from .rottentomatoes import RottenTomatoesAdapter
from .tmdb import TmdbAdapter
from .whatismymovie import WhatIsMyMovieAdapter
from .yandex import YandexAdapter

# 搜索适配器：并发扇出
_justwatch = JustWatchAdapter()   # 核心：搜索 + 观看地址（免费/订阅/租/买 + 深度链接）

SEARCH_ADAPTERS: list[SearchAdapter] = [
    _justwatch,
    TmdbAdapter(),        # 官方 API（需 TMDB_API_KEY）
    WhatIsMyMovieAdapter(resolver=_justwatch.resolve_title),  # 语义搜索（描述式查询，网页免key）
    YandexAdapter(resolver=_justwatch.resolve_title),  # 多语言发现通道（en/ja/ko/zh）
    ImdbAdapter(),        # 爬虫：高级关键词搜索
    LetterboxdAdapter(),  # 爬虫：社区生物标签
    RottenTomatoesAdapter(),  # 爬虫：评分
    ArchiveAdapter(),     # 公共领域免费老片
]

# 增强适配器：合并后补评分
ENRICH_ADAPTERS = [OmdbAdapter()]  # 需 OMDB_API_KEY

ALL_ADAPTERS = SEARCH_ADAPTERS + ENRICH_ADAPTERS
