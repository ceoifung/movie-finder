"""片名 → 在线播放网页链接罗列（多搜索引擎 + 反降级策略）。

对聚合排序后的头部影片，用「片名 在线播放」到搜索引擎检索，把命中的网页
（豆瓣/bilibili/爱奇艺/百科等）以可点击链接列在结果卡片里。

反爬/反降级设计（2026-09 实测结论）：
- cn.bing 对「中文片名+在线观看意图」效果最好，但对高频请求会软封禁
  （返回单字词典垃圾或空结果）→ 单线程 + 1.5s 间隔 + 连续失败熔断 15 分钟；
- 结果必须通过相关性校验（标题含片名），词典垃圾页直接判失败换关键词/引擎；
- 关键词降级：「在线播放」失败后用「电影」重试（后者更不易触发过滤）；
- 引擎降级链：bing_cn → bing_global → ddg（海外部署可用）；
- 片名→链接缓存 7 天（带版本号，升级逻辑即失效旧缓存）。
"""
from __future__ import annotations

import asyncio
import re
import time
from urllib.parse import quote_plus

import httpx
from bs4 import BeautifulSoup

from .models import Movie, WebLink

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

_client = httpx.AsyncClient(
    timeout=httpx.Timeout(6.0, connect=4.0), follow_redirects=True,
    headers={"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"},
)

_engine_fails: dict[str, int] = {}
_engine_disabled: dict[str, float] = {}
_FAIL_LIMIT = 2
_COOLDOWN = 900.0

_host_last: dict[str, float] = {}
_MIN_INTERVAL = 1.5  # 同一引擎两次请求的最小间隔（秒）

_CACHE_VER = "v3"
_link_cache: dict[str, tuple[float, list]] = {}
_CACHE_TTL = 7 * 24 * 3600

_JUNK_DOMAINS = ("bing.com", "microsoft.com", "duckduckgo.com", "go.microsoft",
                 "support.microsoft", "login.live", "cn.bing")


def _engine_ok(name: str) -> bool:
    return _engine_disabled.get(name, 0) < time.time()


def _record(name: str, ok: bool) -> None:
    if ok:
        _engine_fails[name] = 0
        return
    _engine_fails[name] = _engine_fails.get(name, 0) + 1
    if _engine_fails[name] >= _FAIL_LIMIT:
        _engine_disabled[name] = time.time() + _COOLDOWN


async def _throttle(host: str) -> None:
    now = time.time()
    wait = _MIN_INTERVAL - (now - _host_last.get(host, 0.0))
    if wait > 0:
        await asyncio.sleep(wait)
    _host_last[host] = time.time()


def _decode_bing_url(url: str) -> str:
    """还原 bing /ck/a 跳转壳里的真实 URL（u=a1<Base64> 参数）。失败返回原链接。"""
    if "/ck/" not in url:
        return url
    import base64
    from urllib.parse import urlparse, parse_qs, unquote
    try:
        qs = parse_qs(urlparse(url).query)
        u = (qs.get("u") or [""])[0]
        if u.startswith("a1"):
            u = u[2:]
        pad = "=" * (-len(u) % 4)
        return base64.urlsafe_b64decode(u + pad).decode("utf-8", errors="ignore")
    except Exception:
        return url


async def _search_bing(query: str, host: str, ensearch: bool = False) -> list[WebLink]:
    await _throttle(host)
    params = {"q": query}
    if ensearch:
        params["ensearch"] = "1"
    r = await _client.get(f"https://{host}/search", params=params)
    if r.status_code != 200:
        raise RuntimeError(f"bing {host} HTTP {r.status_code}")
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _parse_bing, r.text)


def _parse_bing(html: str) -> list[WebLink]:
    soup = BeautifulSoup(html, "html.parser")
    out, seen_domain = [], set()
    for a in soup.select("li.b_algo h2 a"):
        url = _decode_bing_url(a.get("href") or "")
        title = a.get_text(" ", strip=True)
        if not url.startswith("http") or not title:
            continue
        m = re.match(r"https?://([^/]+)", url)
        domain = (m.group(1) if m else "").lower()
        if not domain or domain in seen_domain or any(j in domain for j in _JUNK_DOMAINS):
            continue
        seen_domain.add(domain)
        out.append(WebLink(title=title[:60], url=url))
        if len(out) >= 5:
            break
    if not out:
        raise RuntimeError("bing no organic results")
    return out


async def _search_yandex(query: str) -> list[WebLink]:
    """Yandex 网页检索。配了 YANDEX_API_KEY 走官方 XML API（稳定），
    否则抓网页版（数据中心 IP 会触发 SmartCaptcha → 抛错降级）。"""
    import os
    import xml.etree.ElementTree as ET
    key = os.environ.get("YANDEX_API_KEY")
    if key:
        await _throttle("yandex")
        r = await _client.get("https://yandex.ru/search/xml", params={
            "user": os.environ.get("YANDEX_XML_USER", ""), "key": key,
            "query": query, "l10n": "en", "filter": "strict",
            "groupby": "attr=().mode=flat.groups=10",
        })
        if r.status_code != 200:
            raise RuntimeError(f"yandex api HTTP {r.status_code}")
        out, seen = [], set()
        root = ET.fromstring(r.text)
        for doc in root.iter("doc"):
            url = doc.findtext("url", default="") or ""
            title = re.sub(r"<[^>]+>", "", doc.findtext("title", default="") or "").strip()
            if not url.startswith("http"):
                continue
            m = re.match(r"https?://([^/]+)", url)
            domain = (m.group(1) if m else "").lower()
            if not domain or domain in seen:
                continue
            seen.add(domain)
            out.append(WebLink(title=title[:60], url=url))
            if len(out) >= 5:
                break
        if not out:
            raise RuntimeError("yandex api no results")
        return out

    await _throttle("yandex.com")
    r = await _client.get("https://yandex.com/search/", params={"text": query, "lr": 87})
    if "showcaptcha" in str(r.url) or "SmartCaptcha" in r.text[:6000] or r.status_code == 403:
        raise RuntimeError("yandex captcha/blocked")
    if r.status_code != 200:
        raise RuntimeError(f"yandex HTTP {r.status_code}")
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _parse_yandex, r.text)


def _parse_yandex(html: str) -> list[WebLink]:
    soup = BeautifulSoup(html, "html.parser")
    out, seen_domain = [], set()
    for item in soup.select("li.serp-item, li.OrganicItem"):
        a = item.select_one("h2 a, a.OrganicTitle-Link")
        if not a:
            continue
        url = a.get("href") or ""
        title = a.get_text(" ", strip=True)
        if not url.startswith("http") or not title:
            continue
        m = re.match(r"https?://([^/]+)", url)
        domain = (m.group(1) if m else "").lower()
        if not domain or domain in seen_domain or any(j in domain for j in _JUNK_DOMAINS):
            continue
        seen_domain.add(domain)
        out.append(WebLink(title=title[:60], url=url))
        if len(out) >= 5:
            break
    if not out:
        raise RuntimeError("yandex no organic results")
    return out


async def _search_ddg(query: str) -> list[WebLink]:
    from urllib.parse import unquote, urlparse, parse_qs
    await _throttle("duckduckgo.com")
    r = await _client.get("https://html.duckduckgo.com/html/", params={"q": query})
    if r.status_code != 200:
        raise RuntimeError(f"ddg HTTP {r.status_code}")
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _parse_ddg, r.text, unquote, urlparse, parse_qs)


def _parse_ddg(html, unquote, urlparse, parse_qs) -> list[WebLink]:
    soup = BeautifulSoup(html, "html.parser")
    out, seen_domain = [], set()
    for a in soup.select("a.result__a"):
        href = a.get("href") or ""
        if "uddg=" in href:
            url = unquote(parse_qs(urlparse(href).query).get("uddg", [""])[0])
        else:
            url = href
        title = a.get_text(" ", strip=True)
        if not url.startswith("http") or any(j in url for j in _JUNK_DOMAINS):
            continue
        m = re.match(r"https?://([^/]+)", url)
        domain = (m.group(1) if m else "").lower()
        if not domain or domain in seen_domain:
            continue
        seen_domain.add(domain)
        out.append(WebLink(title=title[:60], url=url))
        if len(out) >= 5:
            break
    if not out:
        raise RuntimeError("ddg no results")
    return out


# 引擎优先级（用户指定）：Yandex、DuckDuckGo 为主，Bing 作为替代。
# (名称, 查询语言顺序, 检索函数)；引擎故障自动熔断降级到下一个。
_ENGINES = [
    ("yandex", ("zh", "en"), _search_yandex),
    ("ddg", ("zh", "en"), _search_ddg),
    ("bing_cn", ("zh",), lambda q: _search_bing(q, "cn.bing.com")),
    ("bing_ensearch", ("en",), lambda q: _search_bing(q, "cn.bing.com", ensearch=True)),
    ("bing_global", ("en",), lambda q: _search_bing(q, "www.bing.com")),
]


def _has_cjk(s: str) -> bool:
    return any("\u4e00" <= ch <= "\u9fff" for ch in (s or ""))


def _relevant(links: list[WebLink], zh_name: str, en_name: str) -> list[WebLink]:
    """相关性校验：标题含中文名（或其前缀，兼容系列片名简写）或英文名长词，
    过滤被降级时的词典垃圾页。"""
    _STOP = {"the", "movie", "film", "watch", "online", "series", "list", "video"}

    def ok(l: WebLink) -> bool:
        t = re.sub(r"\s+", "", l.title)
        if zh_name and (zh_name in t or (len(zh_name) >= 4 and zh_name[:3] in t)):
            return True
        low = l.title.lower()
        words = [w for w in re.split(r"\W+", en_name.lower()) if len(w) >= 3 and w not in _STOP]
        # 优先用长词（"shark" 而不是 "big"），短常见词易误判
        strong = [w for w in words if len(w) >= 5] or words
        return any(w in low for w in strong) if strong else True

    hits = [l for l in links if ok(l)]
    return hits if hits else []


async def search_web_links(movie: Movie) -> list[WebLink]:
    """单部影片的在线播放链接。关键词降级：在线播放 → 电影 / watch online → film。"""
    zh_name = movie.title if _has_cjk(movie.title) else (movie.original_title or movie.title)
    en_name = movie.original_title or movie.title
    queries = {
        "zh": [f"{zh_name} 在线播放", f"{zh_name} 电影"],
        "en": [f"{en_name} watch online", f"{en_name} film"],
    }
    ck = f"{_CACHE_VER}|{zh_name}|{movie.year}"
    now = time.time()
    if ck in _link_cache and _link_cache[ck][0] > now:
        return _link_cache[ck][1]

    for name_, langs, fn in _ENGINES:
        if not _engine_ok(name_):
            continue
        # 每引擎最多 2 次尝试：主关键词（在线播放）→ 备用关键词（电影），
        # 控制最坏情况下的总延迟
        attempts = []
        for lang in langs:
            attempts += queries[lang]
        for q in attempts[:2]:
            try:
                links = _relevant(await fn(q), zh_name, en_name)
                if not links:
                    raise RuntimeError("irrelevant results (degraded?)")
                _record(name_, True)
                _link_cache[ck] = (now + _CACHE_TTL, links)
                return links
            except Exception:
                continue
        _record(name_, False)
    return []


async def enrich_web_links(movies: list[Movie], limit: int = 6) -> None:
    """为头部影片填充 web_links。并发 2 + 引擎级节流，平衡速度与反爬。"""
    sem = asyncio.Semaphore(2)

    async def one(m: Movie) -> None:
        async with sem:
            try:
                m.web_links = await search_web_links(m)
            except Exception:
                m.web_links = []

    await asyncio.gather(*[one(m) for m in movies[:limit]])
