# home-admin

云铃管理后台的 Android 客户端（Flutter）。与 `admin-web` 对应，页面：系统监控、版本、博客、管理、
终端（ttyd WebView）、文件、通知、调试、Hermes 控制台。

## 鉴权：OAuth2 PKCE（公开客户端，无 client_secret）

App 是原生客户端，与系统浏览器的 cookie store 不共享，因此不走网关的网页会话 cookie，统一走
标准 OAuth2.1 / OIDC PKCE：

1. App 生成 `code_verifier` / `code_challenge`(S256) / `state`；
2. 用系统浏览器打开认证中心 `/authorize`；
3. App 内起一个只监听 `127.0.0.1:53682` 的临时 HTTP server 收 `?code=&state=`，
   校验 `state` 一致后换令牌并关掉 server；
4. `access_token` / `refresh_token` / `id_token` 存**系统安全存储**
   （Android Keystore / iOS Keychain）；
5. 每个 API 请求带 `Authorization: Bearer`；401 时用 `refresh_token` 静默续期并重试一次，
   续期失败才回登录页；登出先清安全存储再调 `/revoke`。

**为什么不能用自定义 scheme**：认证中心只接受 `https` 或 `localhost` 的 `redirect_uri`，
自定义 scheme（如 `homeadmin://callback`）不被接受。

**为什么固定 53682 端口**：`redirect_uri` 必须与客户端注册值精确匹配（不许通配），
所以回调固定为 `http://127.0.0.1:53682/callback`。

## 启动流程：首帧优先

`main()` 里 `runApp` 之前只做同步调用（`WidgetsFlutterBinding.ensureInitialized()` 与回调赋值），
安全存储 / 令牌续期 / 主题偏好 / 通知服务初始化全部移到 `runApp` 之后，由 `lib/startup.dart`
异步编排：

- 每一步独立 `try/catch` 且有超时（安全存储读写 5 秒），失败只降级，绝不白屏、绝不崩。
- 加载期间先渲染与登录页同底色的轻量占位，登录态就绪后再切换到登录页或主页。
- 安全存储不可用时本次会话走内存态：登录与接口调用正常，但界面会明确提示
  「本次登录不会持久保存」，不会静默假装成功。
- 通知服务初始化失败被隔离，不影响主界面与登录。

## 构建

私有基础设施地址在编译期注入，仓库内只有 `example.com` 占位域。构建必须带三个 `--dart-define`，
否则 App 会连到占位地址：

```bash
flutter build apk --release \
  --dart-define=API_BASE=<admin 域名，含 https://> \
  --dart-define=AUTH_BASE=<认证中心域名，含 https://> \
  --dart-define=HERMES_URL=<Hermes 控制台域名，含 https://>
```

产物位于 `build/app/outputs/flutter-apk/app-release.apk`。`client_id` 默认 `home-admin`，
可用 `--dart-define=OAUTH_CLIENT_ID=...` 覆盖。本地调试：`flutter run` 后追加相同参数。

## 开发自检

```bash
flutter pub get
flutter analyze
flutter test
```
