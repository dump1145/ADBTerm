# ADBTerm（v7：投屏远控增强版）

iOS 上的 ADB 客户端：手动输入 IP 和端口，建立明文 ADB 连接，提供 shell 终端、应用 / 文件管理、logcat、屏幕镜像，以及一组仿照「甲壳虫ADB助手」扩展的系统实用工具。

v6 在 v5（屏幕镜像 + 触控）的基础上，参照甲壳虫ADB助手（com.didjdk.adbhelper, v1.2.9）的功能，补齐了以下能力：

- **显示设置**：读取 / 修改分辨率（`wm size`）、DPI（`wm density`），一键恢复默认。
- **动画速度**：窗口动画 / 切换动画 / 动画时长三档缩放，提供 0× / 0.5× / 1× / 1.5× / 2× 预设与自定义值。
- **墓碑模式**：开启 / 关闭 `cached_apps_freezer`，冻结后台应用。
- **屏幕控制与录制**：熄屏（KEYCODE_SLEEP）/ 点亮（KEYCODE_WAKEUP）、`screenrecord` 定时录屏并导出分享。
- **高级重启**：正常 / Recovery / Bootloader / Fastboot。
- **快捷命令**：自定义命令的增删改与执行，持久化保存；终端历史可点击回填。
- **权限管理**：查看并授予 / 撤销应用的运行时权限（dumpsys / pm grant）。
- **更丰富的设备信息**：新增局域网 IP、充电状态、已运行时长、序列号、设备代号等。

所有新能力均复用现有 ADB shell / sync 通道实现，**不需要设备 root**；但部分操作（墓碑模式写入 settings、静默重启、系统应用冻结等）能否成功取决于设备的系统策略与 shell 权限。

## 打 ipa
1. 把本目录推到你自己的 GitHub 仓库（main 分支）。
2. 打开仓库 Actions → "Build IPA" → Run workflow（推送 main 也会自动触发）。
3. 跑完后在该次运行页面底部下载 `ADBTerm-ipa`，解压得到 `ADBTerm.ipa`（未签名）。
4. 用 Sideloadly 或 AltStore 登录你的 Apple ID，签名并装到 iPhone。

工程由 XcodeGen 根据 `project.yml` 在云端生成 `.xcodeproj`，无需在本地保留。

## 使用前提（沿用 v1 的连接限制）
- 只支持明文 ADB，即 5555 这类 `adb tcpip` 端口。Android 11+ 的“无线调试”端口要求 TLS，连接时会提示。
- 需要先用电脑对手机执行一次 `adb tcpip 5555`（手机重启后失效）。
- 首次连接：iOS 会请求“本地网络”权限，手机会弹出“允许 USB 调试”，选“始终允许”。
- 手机和 iPhone 要在同一个局域网。

## 功能分页
| 页签 | 内容 |
| --- | --- |
| 终端 | shell 终端、命令历史、快捷命令下拉 |
| Logcat | 实时日志，开始 / 停止 / 清空 |
| 工具 | 设备信息、屏幕开关、屏幕录制、分辨率 / DPI、动画速度、墓碑模式、高级重启、截图、安装 APK |
| 应用 | 启动 / 强停 / 清除 / 冻结 / 卸载 / 导出 APK / 权限管理 |
| 文件 | 目录浏览、拉取 / 上传、删除、新建文件夹 |
| 镜像 | scrcpy 4.0 屏幕镜像 + 触控、虚拟导航键 |
| 命令 | 自定义快捷命令增删改 / 执行、历史记录回填 |

## 屏幕镜像 / 投屏远控（v7 重点增强）
仿照甲壳虫的投屏远控（其内置 scrcpy server 1.18 的 `ControlMessage` / `KeyComposition` / `ClipboardManager` 能力），在 scrcpy 4.0 协议上补齐了控制维度：

- **实时画面 + 触摸控制**：等比缩放居中映射，支持多点触控，坐标与视频流尺寸严格对齐。
- **键盘文本输入**：镜像页点“键盘”打开输入面板，把文字注入手机当前焦点输入框（`INJECT_TEXT`，单次 ≤300 字节，按 UTF-8 字符边界截断），并可“发送回车”。
- **更全的按键控制**：返回 / 主页 / 多任务 / 电源 / 菜单，以及静音、音量 ±、搜索、删除（`INJECT_KEYCODE`）。
- **旋转屏幕**：`ROTATE_DEVICE` 一键旋转。
- **全屏沉浸**：隐藏控制条只留画面，右上角退出。
- **画质切换**：流畅 / 标准 / 高清，运行中可点“重启”生效。
- **尺寸兜底**：若服务端未下发 session 包，改用 SPS/PPS 解出的分辨率做触摸映射，保证“能控”不落空。

实现位置：`Sources/Mirror.swift`（视频解析、H.264 渲染、控制消息编码）与 `Sources/MirrorView.swift`（镜像界面与键盘面板）。
- 基于 scrcpy 4.0 的服务端（Apache-2.0）。编译时 GitHub Actions 会从官方发布页下载 `scrcpy-server-v4.0`，打包进 App。
- 版本必须匹配：服务端版本固定为 4.0，如需升级，要同时改 `Mirror.swift` 里的版本号和工作流里的下载地址。
- 未做（受限或风险较高）：鼠标滚轮消息（`INJECT_SCROLL`）、剪贴板双向同步（需配对确认交互）。可继续迭代。

## 屏幕录制说明
- 使用设备端 `screenrecord`（Android 4.4+）录制到 `/data/local/tmp`，结束后通过 ADB sync 拉取到 iPhone 并可通过系统分享面板保存。
- 部分定制系统可能裁剪了 `screenrecord`，若提示失败请改用“镜像”页录制。

## v6 新增 / 修改的源码文件
- `Sources/SystemTools.swift`（新）：显示 / 动画 / 墓碑 / 重启 / 录屏 / 权限的 ADBClient 扩展与数据模型。
- `Sources/CommandStore.swift`（新）：快捷命令与历史的持久化存储。
- `Sources/CommandsView.swift`（新）：快捷命令管理页。
- `Sources/PermissionsView.swift`（新）：权限管理页。
- `Sources/ToolsView.swift`（改）：工具页重排为信息 / 屏幕 / 显示 / 动画 / 系统多卡片。
- `Sources/AppsView.swift`（改）：应用操作新增“权限管理”。
- `Sources/ADBFeatures.swift`（改）：设备信息字段扩展。
- `Sources/ContentView.swift`（改）：新增“命令”页签并接入 CommandStore。
- `Sources/Mirror.swift`（改，v7）：新增 `injectText` / `rotate` / `backOrScreenOn` 控制消息，触摸压力修正，SPS 尺寸兜底。
- `Sources/MirrorView.swift`（改，v7）：镜像页新增键盘输入面板、更多按键、旋转、全屏沉浸、画质重启。

## 后续（未实现）
- STLS + TLS 客户端证书，支持 Android 11+ 无线调试端口
- SPAKE2 配对码配对、Bonjour 发现
