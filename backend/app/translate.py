"""自由文本翻译：MyMemory 免费 API（无 key），带缓存与静默降级。

生物分类词的多语言映射由 taxonomy 静态词典承担（精确、零网络依赖），
这里只处理用户的自由文本（如「雪山杀人狂」）到目标语言的转换。
"""
from __future__ import annotations

import time

import httpx

_cache: dict[tuple, tuple[float, str]] = {}
_TTL_OK = 24 * 3600
_TTL_FAIL = 600

LANG_TARGET = {"en": "en", "ja": "ja", "ko": "ko"}


async def translate(text: str, target: str, source: str = "zh-CN") -> str:
    if not text or target not in LANG_TARGET:
        return ""
    key = (text, source, target)
    now = time.time()
    if key in _cache:
        until, val = _cache[key]
        if until > now:
            return val
    try:
        async with httpx.AsyncClient(timeout=6.0) as client:
            r = await client.get(
                "https://api.mymemory.translated.net/get",
                params={"q": text, "langpair": f"{source}|{LANG_TARGET[target]}"},
            )
            out = ((r.json().get("responseData") or {}).get("translatedText")) or ""
            if out and "MYMEMORY WARNING" not in out.upper():
                _cache[key] = (now + _TTL_OK, out)
                return out
    except Exception:
        pass
    _cache[key] = (now + _TTL_FAIL, "")
    return ""
