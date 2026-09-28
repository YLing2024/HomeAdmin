# AGENTS.md — home-admin（Flutter 管理后台 App）

> AI 编码代理进入本仓库先读本文件。README.md 是 Flutter 模板原文，内容过时；以本文件为准。

## 这个项目是什么

个人网站管理后台的 **Android 客户端**（Flutter / Dart），是 `admin-web` 的移动端对应物：

| 页面 | 文件 | 说明 |
|---|---|---|
| 登录 | `login_page.dart` | 系统浏览器走标准 OAuth2 PKCE 登录（回环回调），不再输入 TOTP |
| 主页 | `home_page.dart` | 入口导航 |
| 聊天 | `chat_page.dart` | 与 Hermes 网关对话（流式） |
| 浏览 | `browse_page.dart` / `blog_page.dart` | 历史会话、博客 |
| 系统 | `system_page.dart` / `version_page.dart` | 系统监控、版本 |
| 管理 | `manage_page.dart` / `reset_totp_page.dart` | 服务与 TOTP 重置 |
| 终端 | `terminal_page.dart` | ttyd 内嵌 WebView，多标签 + 口令二次验证（对齐 Web 端 `Terminal.jsx`） |
| 通用 | `command_palette.dart` | 命令面板 |

## 技术栈

- Flutter（Dart SDK `>=3.9.0 <4.0.0`），Material
- 依赖：`http`、`flutter_secure_storage`（OAuth2 令牌存系统安全存储）、`crypto`（PKCE 的 S256）、`webview_flutter`（终端 / Hermes Tab）、`image_picker`、`file_picker`、`path_provider`、`flutter_markdown`、`markdown`、`qr_flutter`、`url_launcher`、`shared_preferences`（仅存主题/草稿/终端标签等非敏感 UI 状态，**不再存 token**）
- lint：`flutter_lints`
- 测试：`flutter test`（PKCE 纯逻辑、媒体解析、通知模型/页面、Hermes 抽屉等）

## 目录结构

```
lib/
├── main.dart              # 入口（加载安全存储令牌）+ 主题装配
├── api.dart               # REST 封装（统一 Bearer、401 refresh 重试、全局登出回调）
├── auth.dart              # OAuth2 PKCE 登录/续期/登出 + 系统安全存储
├── pkce.dart              # PKCE 纯逻辑（verifier/challenge/state，可单测）
├── theme.dart             # 主题（与主页 v2 Swiss 调色板对齐）
├── login_page.dart        # PKCE 登录入口页 + 全局 forceLogout()
├── home_page.dart / chat_page.dart / browse_page.dart
├── system_page.dart / version_page.dart / manage_page.dart / reset_totp_page.dart
├── command_palette.dart
└── media_tags.dart / file_refs.dart / image_refs.dart   # 消息引用解析（与 admin-web 同语义）
test/pkce_test.dart        # PKCE 纯函数单测（含 RFC 7636 测试向量）
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
   `android/gradle.properties` 现为 `org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=512m`（8 vCPU / 7.9G 内存的服务器，2026-09-17 实测构建通过）。
   早期 1.9G 内存的机器上曾是 `-Xmx1024m -XX:MaxMetaspaceSize=512m`；换机后按内存上调。内存被 cgroup 限制时会被 OOM-kill，必要时再下调。
2. **构建完必须杀 daemon**：Gradle daemon 默认空闲存活 ~3h、常驻 ~600MB。服务器上构建结束就 `pkill -f "[G]radleDaemon"`（方括号防自匹配）（或 `./gradlew --stop`），否则内存/swap 会被吃掉。
   长期方案：`org.gradle.daemon.idletimeout=60000` 或 `org.gradle.daemon=false`。
3. 插件 `compileSdk` 不匹配时，不要去改 `android/build.gradle.kts` 的 `subprojects {}`（会被插件自身的 build.gradle 覆盖）——可靠做法是**锁定已验证的插件版本**。

详细的已验证修复见 Hermes skill `coding-agent-acceptance/references/flutter-android-builds-on-small-vps.md`。

## 设计系统

与 `homepage` / `admin-web` 同一套 Swiss 调色板（暖纸白 / 墨黑 / 琥珀），深浅色跟随系统，直角、发丝线分隔。改 `theme.dart` 时对照 `homepage/src/index.css` 的令牌，保持两端一致。

文案：唯美克制，**禁 emoji / 鸡汤 / 网络热词**。

## 鉴权：标准 OAuth2 PKCE（2026-09-28 起）

App 是**原生客户端**，与系统浏览器的 cookie store 不共享，所以不能走网关的网页会话 cookie；
统一改走标准 OAuth2.1 / OIDC PKCE（公开客户端，**无 client_secret**）：

- 登录：`lib/auth.dart` 生成 `code_verifier`/`code_challenge(S256)`/`state`（`lib/pkce.dart`）→
  `url_launcher` 打开系统浏览器 `/authorize` → App 内起一个**只监听 `127.0.0.1:53682`** 的临时
  HTTP server 收 `?code=&state=`，**校验 state** 后换令牌并关掉 server。
- 令牌：`access_token`（约 1h）/ `refresh_token`（约 30d）/ `id_token` 存 **系统安全存储**
  （`flutter_secure_storage`：Android Keystore / iOS Keychain），源码与 `shared_preferences` 均**不落 token**。
- 每个业务请求：`lib/api.dart` 统一加 `Authorization: Bearer <access_token>`；401 时用
  `grant_type=refresh_token` 静默续期并**原样重试一次**，续期失败才 `forceLogout()`（不回退旧 `/api/admin/login`）。
- 登出：先清安全存储，再 best-effort 调 `/revoke`（body 带 `token` + `client_id`）。
- **刷新纪律**：认证中心的 refresh_token 一次性（重放会作废整条链），所以**只允许主 isolate 续期**；
  前台服务 isolate 遇 401 只上报，由 `main.dart` 的主 isolate 续期后重启服务。

**为什么不能用自定义 scheme**：认证中心只接受 `https` 或 `localhost` 的 redirect_uri，自定义 scheme
（`homeadmin://callback`）未注册也不被接受。

**为什么回调端口固定 53682**：redirect_uri 必须与客户端注册值**精确匹配**（不许通配），所以
`redirect_uri` 与本地监听端口都写死为 `http://127.0.0.1:53682/callback`。

## ✅ 私有地址一律编译期注入

`lib/api.dart`（API_BASE）、`lib/auth.dart`（AUTH_BASE / OAUTH_CLIENT_ID）、
`lib/hermes_page.dart`（HERMES_URL）里的私有地址均改为编译期注入，仓库内只有占位域：

```dart
const String kApiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://api.example.com');
const String kAuthBase = String.fromEnvironment('AUTH_BASE', defaultValue: 'https://auth.example.com');
const String kOAuthClientId = String.fromEnvironment('OAUTH_CLIENT_ID', defaultValue: 'home-admin');
```

**构建必须带三个 `--dart-define`**，否则会回退到占位域、连不上后端 / 打不开认证中心：

```bash
flutter build apk --release \
  --dart-define=API_BASE=<admin 域名，含 https://> \
  --dart-define=AUTH_BASE=<认证中心域名，含 https://> \
  --dart-define=HERMES_URL=<Hermes 控制台域名，含 https://>
```

`OAUTH_CLIENT_ID` 默认已是注册值 `home-admin`，一般无需覆盖。

规则不变：私有地址必须环境注入、不得入库；不要在新代码里继续加硬编码地址。

## 已知坑

- **终端 Tab 与 Web 端必须行为一致**（`terminal_page.dart` ↔ `admin-web/src/components/Terminal.jsx`）：会话名 + 12h 票据按 `--url-arg` 顺序传给 wrapper（第 1 个 = 会话名、第 2 个 = 票据）；存活点 6s 轮询且**只在 Tab 激活时轮询**；票据只在内存保存（App 重启即失效）；关标签结束对应会话，锁定则批量结束。改一边就要同步另一边。
- 与后端协议对齐 `admin-web`：`@file:` / `@image:` / MEDIA 标签的解析语义必须两边一致（改了 `media_tags.dart` 要同步 `admin-web/src/mediaTags.js`）。
- token 存**系统安全存储**（`flutter_secure_storage`），401 且续期失败时走 `forceLogout()`（幂等，可重复触发）；`shared_preferences` 只放主题/草稿/终端标签等非敏感 UI 状态。
- 终端 WebView 首帧用 `Api.webviewHeaders()` 带 `Authorization: Bearer`（不再把 token 拼进 URL）；`ttyd` 子资源同源加载。
- 文件下载走系统浏览器（网关会话 cookie 鉴权，URL 不带 token）；App 内带 Bearer 取字节用 `Api.download()`。
- `README.md` 已改写为项目说明（构建 + PKCE 流程），不再是 `flutter create` 模板原文。
- 仓库里没有 iOS 工程，目标平台只有 Android。

## 项目记忆（PROJECT_MEMORY.md）

**分工**：`AGENTS.md` 记**规则**（稳定、必须遵守）；`PROJECT_MEMORY.md` 记**记忆**（可演进、随事实更新）。
两者冲突时以 `AGENTS.md` 为准；只有经用户明确确认、且长期稳定的规则，才由用户决定升级进 `AGENTS.md`。
`PROJECT_MEMORY.md` 已被 `.gitignore` 拦截：**只存本机，不提交、不推送**。

### 什么时候写

- 读完代码 / 查完日志后，**确认了可复用、长期有效**的结论：API 契约与参数语义、数据模型与单位、踩坑的根因、
  产品与 UI 习惯、历史 bug 的判据（"见到 X 现象就查 Y"）。
- **任务收尾时必须回写**：本次确认了什么、推翻了什么、遗留了什么（写清复核条件）。
- **不要写**：临时猜测、单次偶发现象、未经验证的产品判断、敏感信息（密钥 / token / 口令 / 私有地址）、
  与项目无关的个人偏好、以及从代码一眼可见的常识。

### 每条记忆的字段（缺一不可）

```md
### YYYY-MM-DD · 主题（一句话）
- **结论**：一句话说清（可执行、可判断真假）。
- **适用范围**：哪个模块 / 接口 / 页面；**不适用**的情况也要写。
- **证据**：`路径:行号` / commit / 实测输出摘要（附可复现命令）。
- **复核条件**：什么情况下这条会失效（如"升级 Flutter 大版本后重测"）。
- **最后复核**：YYYY-MM-DD
```

### 迭代规则

1. **先查后写**：任务开始时按关键词（模块名 / 接口名 / 报错文本 / 表名）检索本文件；命中就按结论行事，
   并**把该条的「最后复核」更新为今天**（同一次任务只更新一次，不要刷日期）。
2. **更新优先于新增**：主题已有条目 → 就地改写（结论变了要写"曾认为 X，实测为 Y"），**不要追加重复条目**。
3. **失效即删**：结论被推翻、或复核条件已命中（代码已改 / 版本已升）→ 直接删掉或改写，不留"已废弃"堆积。
4. **合并同类**：同一模块超过 3 条相关记忆 → 合并成一节，只保留最新结论 + 关键证据。

### 容量与清理（硬约束）

- 文件上限 **200 行 / 12 KB**（以 `wc -c` 为准）。超限时按以下优先级淘汰：
  ① 已被代码或配置取代的（先删）→ ② 「最后复核」最久远的 → ③ 证据最弱的（只有结论、没有出处）。
- 单条记忆 **≤ 15 行**；细节过长就把细节留在代码注释 / `references/` 里，本文件只留结论与指针。
- **每次写入后顺手清理一次**（行数、体积、重复项、失效项），保证文件始终处于上限内。
- 清理若删掉仍有价值的内容，必须在提交说明或对话里说明，**不要静默丢弃**。

### 写法

- 读者是**下一个接手的 AI 编码代理**，不是人：用最短的句子、最强的证据，先写结论再写理由。
- 结论要能被证伪：写"接口 X 的 `:id` 是数据库数字 id（`WHERE id = ?`）"，不要写"注意 id 类型"。
- 需要跨文件的长篇背景（架构选型、迁移过程）放 `references/` 或项目文档，这里只留一行指针。
