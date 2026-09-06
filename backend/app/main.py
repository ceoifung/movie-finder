"""CreatureFinder 怪物电影聚合检索 — FastAPI 入口。"""
from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import aggregator, taxonomy
from .adapters import ALL_ADAPTERS

app = FastAPI(title="CreatureFinder", version="0.1.0")

STATIC_DIR = Path(__file__).parent / "static"

# 「所有国家」= 美区索引发现 + 英/日区补充观看渠道合并；具体国家则单一区域查询
COUNTRIES = [
    ("ALL", "所有国家"),
    ("US", "美国"), ("GB", "英国"), ("CA", "加拿大"), ("AU", "澳大利亚"),
    ("DE", "德国"), ("FR", "法国"), ("JP", "日本"), ("KR", "韩国"),
    ("HK", "香港"), ("TW", "台湾"), ("SG", "新加坡"), ("BR", "巴西"),
    ("MX", "墨西哥"), ("IN", "印度"), ("ES", "西班牙"), ("IT", "意大利"),
    ("NL", "荷兰"), ("SE", "瑞典"),
]


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/taxonomy")
async def get_taxonomy():
    return {"genres": taxonomy.GENRES, "creatures": taxonomy.CREATURES, "countries": COUNTRIES}


@app.get("/api/search")
async def search(
    q: str = "",
    genre: Optional[str] = None,
    creature: list[str] = Query(default=[]),
    country: str = "ALL",
    free: bool = False,
    limit: int = Query(default=24, le=60),
):
    pq = taxonomy.parse_query(q, genre, creature)
    if not pq.raw and not pq.creatures and not pq.genre_zh:
        return {"error": "empty query", "results": [], "sources": []}
    return await aggregator.search(pq, country, free_only=free, limit=limit)


@app.get("/api/status")
async def status():
    return {
        a.name: {"kind": a.kind, "enabled": a.enabled(), **a.health.to_dict()}
        for a in ALL_ADAPTERS
    }


@app.on_event("shutdown")
async def shutdown():
    for a in ALL_ADAPTERS:
        await a.aclose()


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
