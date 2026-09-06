# CreatureFinder APP（纯 Flutter 客户端版）

「怪物电影聚合检索」安卓 APP：**所有检索引擎都在手机本地运行，不需要任何服务器**。
类型 × 生物标签 × 中/英/日/韩四语言检索，结果卡片附观看渠道（免费优先）和
搜索引擎抓取的在线播放网页链接（可点击），中文译名优先显示。

## 架构（纯客户端）

```
lib/main.dart            UI：搜索/标签/筛选/结果卡片/设置（可选 key）
lib/engine/
  ├─ taxonomy.dart       生物本体库（26类×四语言+同义词+场景/实体/年代解析）
  ├─ aggregator.dart     并发扇出→归一化→去重合并→排序→缓存
  ├─ justwatch.dart      核心：GraphQL 检索+中文译名+繁转简+观看渠道+多地区合并
  ├─ wimm.dart           WhatIsMyMovie 语义通道（描述式查询，网页免key）
  ├─ scrapers.dart       IMDb / Letterboxd / Internet Archive / TMDB(可选key)
  ├─ weblinks.dart       在线播放链接：Yandex→DDG→Bing 引擎链+相关性校验
  ├─ translate.dart      MyMemory 免费翻译 + t2s.dart 繁简表(4057字)
  └─ http.dart           共享客户端+主机节流+信号量（防反爬/防悬挂）
backend/                 原服务端版（保留作参考，APP 已不需要它）
```

## 构建

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn   # 国内镜像
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
flutter test                     # 8 个单测（本体/繁简/合并去重）
dart run tool/smoke_test.dart    # 真实网络冒烟（可选）
flutter build apk --release      # 产物: build/app/outputs/flutter-apk/app-release.apk
```

或直接推送仓库，GitHub Actions 自动构建（打 tag 自动发 Release 附 APK）。

## 说明

- 无 key 可用；设置里可选填 TMDB key（中文片名更全）、Yandex key（免验证码），
  key 只存手机本地；
- 沙盒/数据中心 IP 下 IMDb/Letterboxd/Yandex 会被反爬（引擎自动降级），
  手机住宅网络下这些源可直接工作；
- release APK 为 debug 签名（可直接安装），上架需换正式 keystore；
- 实测：搜「巨型鲨鱼」返回 24 条（巨齿鲨 34 个观看渠道/大白鲨 12 个），
  首次搜索较慢（多源串行节流），相同查询走缓存秒回。
