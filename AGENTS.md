# AGENTS.md — home-admin（Flutter 管理后台 App）

> AI 编码代理进入本仓库先读本文件。README.md 是 Flutter 模板原文，内容过时；以本文件为准。

## 这个项目是什么

个人网站管理后台的 **Android 客户端**（Flutter / Dart），是 `admin-web` 的移动端对应物：

| 页面 | 文件 | 说明 |
|---|---|---|
| 登录 | `login_page.dart` | TOTP 动态码登录（走认证中心） |
| 主页 | `home_page.dart` | 入口导航 |
| 聊天 | `chat_page.dart` | 与 Hermes 网关对话（流式） |
| 浏览 | `browse_page.dart` / `blog_page.dart` | 历史会话、博客 |
| 系统 | `system_page.dart` / `version_page.dart` | 系统监控、版本 |
| 管理 | `manage_page.dart` / `reset_totp_page.dart` | 服务与 TOTP 重置 |
| 终端 | `terminal_page.dart` | ttyd 内嵌 WebView，多标签 + 口令二次验证（对齐 Web 端 `Terminal.jsx`） |
| 通用 | `command_palette.dart` | 命令面板 |

## 技术栈

- Flutter（Dart SDK `>=3.9.0 <4.0.0`），Material
- 依赖：`http`、`shared_preferences`（token 持久化）、`webview_flutter`（终端 Tab）、`image_picker`、`file_picker`、`path_provider`、`flutter_markdown`、`markdown`、`qr_flutter`、`url_launcher`
- lint：`flutter_lints`
- 测试：`test/media_parsers_test.dart`（纯函数单测）

## 目录结构

```
lib/
├── main.dart              # 入口 + 主题装配
├── api.dart               # REST 封装（token 存取、统一请求、401 登出）
├── theme.dart             # 主题（与主页 v2 Swiss 调色板对齐）
├── login_page.dart        # TOTP 登录页 + 全局 forceLogout()
├── home_page.dart / chat_page.dart / browse_page.dart
├── system_page.dart / version_page.dart / manage_page.dart / reset_totp_page.dart
├── command_palette.dart
└── media_tags.dart / file_refs.dart / image_refs.dart   # 消息引用解析（与 admin-web 同语义）
test/media_parsers_test.dart
android/                   # 标准 Flutter Android 工程
```

## 命令

```bash
flutter pub get
flutter analyze
flutter test
flutter run                       # 连真机/模拟器
flutter build apk --release       # 产物 build/app/outputs/flutter-apk/app-release.apk
```

## 构建（服务器 1.9G 内存，必读）

在这台 VPS 上构建 APK **必须**先处理这两个坑，否则会白等一轮（每轮约 25 分钟）：

1. **Gradle daemon OOM**（`Gradle build daemon disappeared unexpectedly`）：
   模板默认 `android/gradle.properties` 是 `org.gradle.jvmargs=-Xmx8G ...`，内存被 cgroup 限制时会 OOM-kill。
   → 改成 `-Xmx1024m -XX:MaxMetaspaceSize=512m`，然后 `pkill -9 -f GradleDaemon` 让新限制生效。
2. **构建完必须杀 daemon**：Gradle daemon 默认空闲存活 ~3h、常驻 ~600MB。服务器上构建结束就 `pkill -f GradleDaemon`（或 `./gradlew --stop`），否则内存/swap 会被吃掉。
   长期方案：`org.gradle.daemon.idletimeout=60000` 或 `org.gradle.daemon=false`。
3. 插件 `compileSdk` 不匹配时，不要去改 `android/build.gradle.kts` 的 `subprojects {}`（会被插件自身的 build.gradle 覆盖）——可靠做法是**锁定已验证的插件版本**。

详细的已验证修复见 Hermes skill `coding-agent-acceptance/references/flutter-android-builds-on-small-vps.md`。

## 设计系统

与 `homepage` / `admin-web` 同一套 Swiss 调色板（暖纸白 / 墨黑 / 琥珀），深浅色跟随系统，直角、发丝线分隔。改 `theme.dart` 时对照 `homepage/src/index.css` 的令牌，保持两端一致。

文案：唯美克制，**禁 emoji / 鸡汤 / 网络热词**。

## ⚠️ 已知违规（待修）

`lib/api.dart` 顶部**硬编码了私有基础设施地址**：

```dart
const String kApiBase  = 'https://zhangyunling.cn';
const String kAuthBase = 'https://auth.zhangyunling.cn';
```

这违反了本项目「私有地址必须环境注入、不得入库」的规范（前端项目一律走 `import.meta.env.VITE_*` 模式）。Dart 侧的正确做法是用 `--dart-define=API_BASE=...` + `String.fromEnvironment(...)`，默认值回退占位（如 `https://api.example.com`），并在 README 说明构建命令。

**这是公开仓库**，改动本文件前先确认用户是否同意一并修掉；不要在新代码里继续加硬编码地址。

## 已知坑

- **终端 Tab 与 Web 端必须行为一致**（`terminal_page.dart` ↔ `admin-web/src/components/Terminal.jsx`）：会话名 + 12h 票据按 `--url-arg` 顺序传给 wrapper（第 1 个 = 会话名、第 2 个 = 票据）；存活点 6s 轮询且**只在 Tab 激活时轮询**；票据只在内存保存（App 重启即失效）；关标签结束对应会话，锁定则批量结束。改一边就要同步另一边。
- 与后端协议对齐 `admin-web`：`@file:` / `@image:` / MEDIA 标签的解析语义必须两边一致（改了 `media_tags.dart` 要同步 `admin-web/src/mediaTags.js`）。
- token 存 `shared_preferences`，401 时走 `forceLogout()`（幂等，可重复触发）。
- `README.md` 是 `flutter create` 生成的模板原文，不要当作项目说明。
- 仓库里没有 iOS 工程，目标平台只有 Android。

## 项目记忆（PROJECT_MEMORY.md）

`PROJECT_MEMORY.md` 用于保存可演进的项目记忆；`AGENTS.md` 保持为稳定的硬规则。处理非简单任务，或任务涉及既有业务判断、与 Web 端（admin-web）的行为对齐、API 参数、历史 bug、产品/UI 习惯时，先按关键词查阅 `PROJECT_MEMORY.md`。

- Agent 可以**自迭代** `PROJECT_MEMORY.md`：当前任务中确认了可复用、长期有效的项目经验后，应追加或更新对应条目。
- 每条记忆必须写明日期、适用范围和可追溯证据（源码路径/行号、Web / Android 两端实现对照、提交或验证结果）；可能过期的结论须标明复核条件。
- 不记录临时猜测、单次偶发现象、未经验证的产品判断、敏感信息或与项目无关的个人偏好。
- `PROJECT_MEMORY.md` 与 `AGENTS.md` 冲突时，以 `AGENTS.md` 为准；只有经明确确认的、长期稳定且必须遵守的规则，才能由用户决定升级到 `AGENTS.md`。
- 本文件已在 `.gitignore` 中忽略：**只存本机，不提交、不推送**。
