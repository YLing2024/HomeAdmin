# atrium-app

个人网站管理后台的 Android 客户端（Flutter），`atrium-console` 的移动端对应物。

## 它能做什么

抽屉导航九个页面，顺序与 Web 端一致：

- **系统**：CPU / 内存 / 磁盘 / 网络的实时读数与历史趋势，趋势按秒 / 分钟 / 小时 / 天四档切换。
- **版本**：软件版本列表，进入页面时加载一次。
- **博客**：文章与合集双视图管理，Markdown 编辑与预览、插图、草稿自动保存。
- **管理**：登录设备会话、接口令牌（明文仅生成时展示一次）、重置验证器。
- **终端**：内嵌 ttyd 的 WebView，多标签；站点登录之外再验一次终端口令，票据只存内存。
- **文件**：目录浏览、上传（带进度）、重命名、删除、下载与限时临时链接。
- **通知**：通知中心；前台常驻服务配合系统本地通知，收到新通知即提醒。
- **调试**：接口调用与最近一次请求的状态码、响应体。
- **Hermes**：内嵌控制台，地址构建期注入。

另有命令面板（快速切页、重置验证器、退出登录）；深浅色跟随系统、可手动切换，
主题与 Web 端同一套 Swiss 调色板。

## 快速开始

```bash
flutter pub get
flutter run    # 连真机或模拟器；私有地址需构建期注入，见下
```

## 配置

私有地址一律构建期注入（`String.fromEnvironment`），源码内只有 `example.com` 占位域：

| 名称 | 默认值 | 说明 |
|---|---|---|
| `API_BASE` | `https://api.example.com` | 管理后台接口基址 |
| `AUTH_BASE` | `https://auth.example.com` | 认证中心基址（sso 模式） |
| `HERMES_URL` | `https://hermes.example.com` | 侧栏 Hermes 页的内嵌地址 |
| `OAUTH_CLIENT_ID` | `home-admin` | OAuth2 公开客户端 id，一般无需覆盖 |

未注入时 App 连的是占位域，无法工作。

## 构建与产物

```bash
flutter build apk --release \
  --dart-define=API_BASE=https://api.example.com \
  --dart-define=AUTH_BASE=https://auth.example.com \
  --dart-define=HERMES_URL=https://hermes.example.com
```

产物：`build/app/outputs/flutter-apk/app-release.apk`。自签名分发，不走应用商店。

构建机内存紧张时 Gradle daemon 易 OOM，构建结束可 `pkill -f "[G]radleDaemon"` 回收常驻内存。

## 开发自检

```bash
flutter pub get
flutter analyze
flutter test
```

## 认证与安全

登录方式跟随服务端 `AUTH_MODE`，App 不需要额外开关；启动时探测 `GET /api/admin/auth-mode`，
**探测失败一律按 sso**。

- **builtin（默认）**：六位动态码登录 `POST /api/admin/login`，令牌 12 小时有效、无 refresh，
  过期即回登录页；登出走 `POST /api/admin/logout`。首次登录若返回 `totp_setup_required`，
  引导到 `GET /api/admin/totp/setup` 绑定验证器。
- **sso**：标准 OAuth2 PKCE（公开客户端、无 client_secret，S256）。用系统浏览器打开认证中心
  `/authorize`，App 内起一个只监听 `127.0.0.1:53682` 的临时 server 收回调并校验 `state`。
  端口固定是因为 redirect_uri 必须与客户端注册值精确匹配，不支持自定义 scheme。

令牌存系统安全存储（Android Keystore），`shared_preferences` 只放主题等非敏感 UI 状态。
业务请求统一带 `Authorization: Bearer`；401 时用 `refresh_token` 静默续期并原样重试一次，
失败才回登录页。认证中心的 refresh_token 一次性，只允许主 isolate 续期；前台服务 isolate
遇 401 只上报，由主 isolate 续期后重启服务。

启动路径上 `runApp` 之前不 await 任何 IO：安全存储、令牌、主题、通知服务全部在 `runApp`
之后异步初始化，每步独立 try/catch 与超时，失败只降级。安全存储不可用时本次会话走内存态，
界面明确提示「本次登录不会持久保存」。

## 许可证

MIT
