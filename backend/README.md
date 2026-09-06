# CreatureFinder 怪物电影聚合检索

按「类型 × 生物」检索电影的多源聚合引擎：一次搜索并发查询官方 API 与爬虫源，
归一化去重合并后返回统一结果，每部影片附**正版观看地址**（免费源优先）。

## 快速开始

```bash
cd movie-finder
python3 -m venv --without-pip .venv
python3 -m pip --python .venv/bin/python install -r requirements.txt
# 可选：配置官方 API key（见 .env.example），不配也能跑（爬虫源工作）
set -a; source .env; set +a   # 或 export TMDB_API_KEY=...
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8300
```

打开 http://127.0.0.1:8300

## 架构

```
查询（文本 + 生物标签 + 类型 + 年代 + 地区）
  └─ taxonomy.py    生物本体库：中/英/日/韩四语言词表 + 查询解析
  └─ translate.py   自由文本翻译（MyMemory 免费 API，带缓存）
  └─ aggregator.py  并发扇出 → 归一化 → 去重合并 → 排序 → 缓存(6h) → 增强
       ├─ adapters/justwatch.py   爬虫·核心：多语言(en/ja/ko)搜索+海报+评分+观看地址(深度链接)
       ├─ adapters/yandex.py      多语言发现通道：四语言Yandex检索→片单页抽电影名→回链JustWatch解析
       ├─ adapters/tmdb.py        官方API：类型×关键词 discover，中文标题
       ├─ adapters/omdb.py        官方API：合并后补 IMDb/Metascore 评分
       ├─ adapters/whatismymovie.py 官方API：自然语言找片（Beta key）
       ├─ adapters/imdb.py        爬虫：高级关键词搜索
       ├─ adapters/letterboxd.py  爬虫：社区生物标签
       ├─ adapters/rottentomatoes.py 爬虫：私有搜索接口
       └─ adapters/archive.py     公共领域免费老片（合法免费播放地址）
```

### 多语言检索原理

中文查询「丧尸」进入本体库后自动展开为四语言检索词（丧尸 / zombie / ゾンビ / 좀비）：
JustWatch 通道用 en/ja/ko 三个主词各查一次合并（母语片名召回更高，实测
ゾンビ 能命中《活死人之夜》原版条目）；Yandex 通道用四语言各搜片单/影评页，
从《》「」『』及引号/标题模式中抽取电影名，再逐个回 JustWatch 解析成
带观看地址的完整条目。自由文本（无生物词时）经翻译服务转成目标语言。

### 在线播放链接罗列（片名 → 搜索引擎）

聚合出片名后，自动用「中文片名 + 在线播放」到搜索引擎检索，把结果网页
（豆瓣 / bilibili / 腾讯视频 / 爱奇艺 / 百度百科 / IMDb 等）以可点击超链接
罗列在每张结果卡片里。引擎优先级：**Yandex → DuckDuckGo → Bing（替代）**，
支持 YANDEX_API_KEY 官方接口模式。

反降级策略（数据中心 IP 场景实测）：请求节流（1.5s/引擎）、结果相关性校验
（标题必须含片名，过滤被软封禁时返回的词典垃圾页）、关键词降级
（在线播放→电影）、引擎连续失败熔断 15 分钟、片名链接缓存 7 天。

### 描述式查询（「背景在荒山，主角叫拿破仑的恐怖片」）

解析器识别「主角叫X」类实体和场景/剧情词典（荒山→wilderness mountains、
木屋→cabin、录像→found footage 等），进入语义模式：

- 实体名翻译后走 JustWatch 单词全文检索（`napoleon`+恐怖类型过滤）；
- 整句翻译成英文交给 WhatIsMyMovie（Valossa AI）做剧情语义检索（网页免 key，
  结果卡片 SSR 可爬），命中的片名再回 JustWatch 补海报/评分/观看地址；
- 普通关键词查询不受影响（WIMM 通道自动跳过，不触发熔断）。

### 适配器状态矩阵

| 适配器 | 接入方式 | 沙盒实测 | 说明 |
|---|---|---|---|
| justwatch | GraphQL 爬虫 | ✅ 可用 | en/ja/ko 多语言检索，观看地址含免费(ADS/FREE)/订阅/租/买，深度链接 |
| yandex | 官方API/网页爬虫双模式 | ⚠️ 沙盒IP触发验证码 | 配 `YANDEX_API_KEY` 走官方（1000次/月免费），或住宅IP爬网页 |
| tmdb | 官方 API | 需 key + 网络放行 | `TMDB_API_KEY`，缺省自动禁用 |
| omdb | 官方 API | 需 key | `OMDB_API_KEY`，仅增强评分 |
| whatismymovie | Beta API | 需申请 | `WIMM_API_KEY` |
| imdb | HTML 爬虫 | ⚠️ 数据中心IP被反爬 | 住宅IP或设 `HTTP_PROXY` 即可 |
| letterboxd | HTML 爬虫 | ⚠️ Cloudflare 403 | 同上 |
| rottentomatoes | 私有接口 | ⚠️ 视环境 | 同上 |
| archive | 官方 JSON API | ⚠️ 沙盒网络不通 | 部署环境可用 |

任何适配器失败都不影响主结果——熔断 10 分钟后自动重试。`/api/status` 可看各源健康度。

## 合规

仅聚合**正版**渠道信息：免费平台（Tubi/Pluto 等）、订阅、租/买深度链接（JustWatch 数据）、
公共领域影片（Internet Archive）。不聚合、不索引任何盗版资源。
