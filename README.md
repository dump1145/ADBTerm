# ADBTerm（v1）

iOS 上的最小 ADB 客户端：手动输入 IP 和端口，建立明文 ADB 连接，提供 shell 终端。

## 打 ipa
1. 把本目录推到你自己的 GitHub 仓库（main 分支）。
2. 打开仓库 Actions → "Build IPA" → Run workflow（推送 main 也会自动触发）。
3. 跑完后在该次运行页面底部下载 `ADBTerm-ipa`，解压得到 `ADBTerm.ipa`（未签名）。
4. 用 Sideloadly 或 AltStore 登录你的 Apple ID，签名并装到 iPhone。

工程由 XcodeGen 根据 `project.yml` 在云端生成 `.xcodeproj`，无需在本地保留。

## 使用前提（v1 的限制）
- 只支持明文 ADB，即 5555 这类 `adb tcpip` 端口。Android 11+ 的“无线调试”端口要求 TLS，v1 连接时会提示。
- 需要先用电脑对手机执行一次 `adb tcpip 5555`（手机重启后失效）。
- 首次连接：iOS 会请求“本地网络”权限，手机会弹出“允许 USB 调试”，选“始终允许”。
- 手机和 iPhone 要在同一个局域网。

## 后续（v2）
- STLS 升级 + TLS 客户端证书，支持无线调试端口
- SPAKE2 配对码配对、Bonjour 发现
- 文件传输（sync）、安装 APK
