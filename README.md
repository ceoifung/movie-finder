# CreatureFinder APP（Flutter）

「怪物电影聚合检索」移动端：类型 × 生物标签 × 多语言检索，结果卡片附
观看渠道（免费优先）和搜索引擎抓取的在线播放网页链接（可点击）。

## 构建

```bash
# 国内镜像
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
flutter build apk --release     # 产物: build/app/outputs/flutter-apk/app-release.apk
```

要求：Flutter 3.x + Android SDK 35 + JDK 17。

## 使用

1. 先启动后端（movie-finder 项目）：
   `.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8300`
2. 手机与后端同一网络，APP 右上角「设置」填后端地址：
   - 真机（局域网）：`http://<电脑内网IP>:8300`
   - Android 模拟器：`http://10.0.2.2:8300`（默认值）
3. 「测试连接」通过后保存，即可搜索。

## 说明

- release APK 使用 debug 签名（可直接安装），上架商店需换成正式签名 keystore；
- 后端地址持久化在本地（shared_preferences）；
- Android 9+ 不允许明文 HTTP？本项目 targetSDK 已配置允许 HTTP（仅开发用途），
  正式部署后端请上 HTTPS 并移除 `android:usesCleartextTraffic`。
