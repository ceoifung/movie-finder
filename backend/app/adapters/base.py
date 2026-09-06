"""适配器基类：统一的 HTTP 客户端、健康度跟踪与熔断。

每个数据源一个适配器；官方 API 适配器在缺少 key 时自动禁用，
爬虫适配器在连续失败后熔断 10 分钟，恢复后自动重试。
"""
from __future__ import annotations

import time

import httpx

from ..models import Movie
from ..taxonomy import ParsedQuery

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8",
}

# 爬虫礼仪：对同一主机的最小请求间隔（秒）——既是礼貌也是生存策略
_MIN_INTERVAL: dict[str, float] = {}
_last_request: dict[str, float] = {}


class AdapterError(Exception):
    pass


class Health:
    def __init__(self) -> None:
        self.ok_count = 0
        self.fail_count = 0
        self.fail_streak = 0
        self.last_error: str | None = None
        self.last_latency_ms: float | None = None
        self.disabled_until: float = 0.0

    def record_ok(self, latency_ms: float) -> None:
        self.ok_count += 1
        self.fail_streak = 0
        self.last_error = None
        self.last_latency_ms = latency_ms

    def record_fail(self, error: str) -> None:
        self.fail_count += 1
        self.fail_streak += 1
        self.last_error = error
        if self.fail_streak >= 3:
            self.disabled_until = time.time() + 600  # 熔断 10 分钟

    def status(self) -> str:
        if time.time() < self.disabled_until:
            return "circuit-open"
        if self.fail_streak > 0:
            return "degraded"
        if self.ok_count > 0:
            return "ok"
        return "idle"

    def to_dict(self) -> dict:
        return {
            "ok": self.ok_count, "fail": self.fail_count,
            "status": self.status(), "last_error": self.last_error,
            "last_latency_ms": self.last_latency_ms,
        }


class SearchAdapter:
    name: str = "base"
    kind: str = "scrape"            # official / scrape
    key_env: str | None = None      # 需要的环境变量（官方 API）
    host: str = ""

    def __init__(self) -> None:
        self.health = Health()
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(12.0),
            headers=BROWSER_HEADERS,
            follow_redirects=True,
        )

    def enabled(self) -> bool:
        if self.key_env:
            import os
            return bool(os.environ.get(self.key_env))
        return True

    def available(self) -> bool:
        return self.enabled() and self.health.status() != "circuit-open"

    async def _get(self, url: str, **kw) -> httpx.Response:
        await self._throttle()
        r = await self._client.get(url, **kw)
        return r

    async def _throttle(self) -> None:
        now = time.time()
        last = _last_request.get(self.host, 0)
        wait = _MIN_INTERVAL.get(self.host, 1.0) - (now - last)
        if wait > 0:
            import asyncio
            await asyncio.sleep(wait)
        _last_request[self.host] = time.time()

    async def search(self, pq: ParsedQuery, country: str) -> list[Movie]:
        raise NotImplementedError

    async def aclose(self) -> None:
        await self._client.aclose()


class EnrichAdapter(SearchAdapter):
    """增强型适配器：不产出搜索结果，只为合并后的结果补充评分等信息。"""
    async def enrich(self, movies: list[Movie]) -> list[Movie]:
        return movies
