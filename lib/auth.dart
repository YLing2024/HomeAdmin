// 标准 OAuth2.1 / OIDC PKCE 登录（公开客户端，无 client_secret）。
//
// 流程（RFC 7636）：
//   1. 生成 code_verifier / code_challenge(S256) / state；
//   2. 系统浏览器打开认证中心 /authorize；
//   3. App 内起一个只监听 127.0.0.1:53682 的临时 HTTP server 收 ?code=&state=，
//      校验 state 一致后回一个「可以关闭此页」的页面并关掉 server；
//   4. 用 code + code_verifier 调 /token（不带 secret）换 access/refresh/id token；
//   5. token 存系统安全存储（Android Keystore / iOS Keychain）。
//
// 之后的 API 调用统一在 lib/api.dart 带 `Authorization: Bearer`，401 时调用
// [Auth.refresh] 静默续期并重试一次；登出走 [Auth.logout]（先清存储，再 best-effort 调 /revoke）。
//
// 并发纪律：认证中心的 refresh_token 是**一次性**的（重放会作废整条链），
// 因此全 App 只允许主 isolate 调 [refresh]；前台服务 isolate 遇到 401 只上报，
// 由主 isolate 续期后重启服务（见 lib/main.dart 与 lib/notification_service.dart）。
//
// 双模式：服务端 `AUTH_MODE=builtin` 时走 [loginWithCode]（6 位动态码，token 12h、
// 无 refresh），`sso` 时走 [login]（PKCE + refresh）。模式由 lib/auth_mode.dart
// 探测，探测失败一律按 sso（绝不改动现有 PKCE 行为）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'pkce.dart';

/// 公开客户端 id（非机密信息，仍按约定用 --dart-define 注入，默认值即注册值）。
const String kOAuthClientId = String.fromEnvironment(
  'OAUTH_CLIENT_ID',
  defaultValue: 'home-admin',
);

/// 认证中心基址。构建时必须 `--dart-define=AUTH_BASE=https://auth.<域名>`，
/// 否则回退到占位域、登录不可用。
const String kAuthBase = String.fromEnvironment(
  'AUTH_BASE',
  defaultValue: 'https://auth.example.com',
);

/// 回环回调端口：认证中心只允许 https 或 localhost，不支持自定义 scheme；
/// 且 redirect_uri 精确匹配注册值（不许通配），故端口必须固定。
const int kLoopbackPort = 53682;

/// 注册到认证中心的回调地址，必须与客户端注册值完全一致。
const String kRedirectUri = 'http://127.0.0.1:$kLoopbackPort/callback';

/// 请求的 scope：必须含 `openid`。
const String kOAuthScope = 'openid profile';

/// 网络请求超时（换令牌 / 续期）。
const Duration _kHttpTimeout = Duration(seconds: 20);

/// 吊销请求超时（best-effort，短一点，别拖住登出）。
const Duration _kRevokeTimeout = Duration(seconds: 5);

/// PKCE 登录等待回调的总超时。
const Duration _kLoginTimeout = Duration(minutes: 5);

/// 安全存储读写超时：超过即视为不可用。
///
/// 某些设备上 KeyStore 异常会让 method channel 永久不返回（表现为启动挂住、
/// 连 `shared_prefs` 都不落盘），所以读写都必须有上限，超时按「不可用」降级。
const Duration kStorageTimeout = Duration(seconds: 5);

/// builtin 令牌有效期：服务端 12 小时有效、无 refresh，本地按签发时间 + 该时长
/// 提前判定过期（过期即回动态码登录页）。
const Duration kBuiltinTokenTtl = Duration(hours: 12);

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// builtin（自带动态码）登录失败。[statusCode] / [errorCode] / [retryAfter]
/// 对应服务端契约：401 验证码错误、403 `totp_setup_required`（需先绑定验证器）、
/// 429 失败过多（[retryAfter] 为剩余秒数）。
class BuiltinLoginException implements Exception {
  const BuiltinLoginException(
    this.message, {
    this.statusCode,
    this.errorCode,
    this.retryAfter,
  });

  final String message;
  final int? statusCode;
  final String? errorCode;
  final int? retryAfter;

  /// 服务端要求先绑定验证器（首次使用）。
  bool get setupRequired =>
      statusCode == 403 && errorCode == 'totp_setup_required';

  @override
  String toString() => message;
}

/// 一份令牌集（access / refresh / id + 过期时刻）。
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.builtin = false,
  });

  final String accessToken;
  final String? refreshToken;
  final String? idToken;

  /// access_token 的绝对过期时刻（expires_in 换算；未知为 null）。
  final DateTime? expiresAt;

  /// 是否 builtin（自带动态码）令牌：12h 有效、无 refresh_token。
  final bool builtin;

  /// 是否已过期（留 60s 提前量，避免边界上刚发出就过期）。
  bool get isExpired {
    final e = expiresAt;
    if (e == null) return false;
    return DateTime.now().isAfter(e.subtract(const Duration(seconds: 60)));
  }
}

/// 令牌与登录态的唯一入口。
class Auth {
  Auth._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static const String _kAccess = 'oauth.access_token';
  static const String _kRefresh = 'oauth.refresh_token';
  static const String _kId = 'oauth.id_token';
  static const String _kExpiry = 'oauth.expires_at';

  // builtin（自带动态码）令牌独立 key：与 oauth 并存也不会互相串味。
  static const String _kBuiltinAccess = 'builtin.access_token';
  static const String _kBuiltinIssuedAt = 'builtin.issued_at';

  static AuthTokens? _tokens;
  static Future<bool>? _refreshing;

  /// 安全存储是否可用（读取/写入超时或抛错即置 false）。
  ///
  /// 不可用时仍保留**内存态**：本次会话可以正常登录与调用 API，只是**不会
  /// 持久保存**，UI 据此明确告知用户，不静默假装成功。
  static final ValueNotifier<bool> storageAvailable = ValueNotifier<bool>(true);

  static void _markStorageUnavailable(Object e) {
    if (storageAvailable.value) {
      debugPrint('安全存储不可用，本次会话改用内存态（不持久保存）: $e');
    }
    storageAvailable.value = false;
  }

  /// 当前 access_token（内存缓存，空串表示无）。
  static String get accessToken => _tokens?.accessToken ?? '';

  /// 是否持有可用登录态：有 access，或有 refresh 可续期。
  ///
  /// builtin 无 refresh：令牌过期即视为无登录态（回动态码页）；sso 语义不变。
  static bool get hasSession {
    final t = _tokens;
    if (t == null) return false;
    if (t.builtin) return t.accessToken.isNotEmpty && !t.isExpired;
    return t.accessToken.isNotEmpty || (t.refreshToken?.isNotEmpty ?? false);
  }

  /// 当前是否 builtin（自带动态码）登录态。
  static bool get isBuiltinSession => _tokens?.builtin ?? false;

  /// 启动时从系统安全存储恢复令牌（前台服务 isolate 也会各自调用一次）。
  static Future<void> init() async {
    _tokens = await _read();
  }

  /// 若 access 已过期但有 refresh，则静默续期；返回是否持有可用 access。
  ///
  /// 主 isolate 启动时调用，避免「refresh 还在但 access 过期」被当成未登录。
  /// builtin 无 refresh：过期即返回 false（由调用方登出回动态码页）。
  static Future<bool> ensureValidAccessToken() async {
    final t = _tokens;
    if (t != null && t.accessToken.isNotEmpty && !t.isExpired) return true;
    if (t != null && t.builtin) return false;
    if (t != null && (t.refreshToken?.isNotEmpty ?? false)) {
      return refresh();
    }
    return t != null && t.accessToken.isNotEmpty;
  }

  /// 清空内存与安全存储中的令牌（安全存储失败不抛出：内存已清即已登出）。
  static Future<void> clear() async {
    _tokens = null;
    try {
      await Future.wait([
        _storage.delete(key: _kAccess),
        _storage.delete(key: _kRefresh),
        _storage.delete(key: _kId),
        _storage.delete(key: _kExpiry),
        _storage.delete(key: _kBuiltinAccess),
        _storage.delete(key: _kBuiltinIssuedAt),
      ]).timeout(kStorageTimeout);
    } catch (e) {
      _markStorageUnavailable(e);
    }
  }

  /* ============ 登录（PKCE） ============ */

  /// 走完整的 PKCE 登录：系统浏览器 → 回环回调 → 换令牌 → 存安全存储。
  /// 失败抛 [AuthException]（state 不一致 / 用户取消 / 超时 / 换令牌失败）。
  static Future<void> login() async {
    final verifier = generateCodeVerifier();
    final challenge = codeChallengeS256(verifier);
    final state = generateState();

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        kLoopbackPort,
      );
    } on SocketException catch (e) {
      throw AuthException('无法监听本地回调端口 $kLoopbackPort：${e.message}');
    }

    try {
      final authorizeUri = Uri.parse('$kAuthBase/authorize').replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': kOAuthClientId,
          'redirect_uri': kRedirectUri,
          'scope': kOAuthScope,
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
        },
      );
      final code = await _awaitCallback(server, state, authorizeUri);
      await _exchangeCode(code, verifier);
    } finally {
      await server.close(force: true);
    }
  }

  /// 在临时 server 上等待回调：校验 state → 取 code；错误写回浏览器页面。
  static Future<String> _awaitCallback(
    HttpServer server,
    String expectedState,
    Uri authorizeUri,
  ) async {
    final completer = Completer<String>();
    late StreamSubscription<HttpRequest> sub;

    sub = server.listen((req) async {
      if (req.uri.path != '/callback') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final q = req.uri.queryParameters;
      String? code;
      String? error;
      if (!verifyState(expectedState, q['state'])) {
        // state 不一致：可能是 CSRF / 授权码注入，直接拒绝
        error = 'state 校验失败，请重试';
      } else if ((q['error'] ?? '').isNotEmpty) {
        final desc = q['error_description'];
        error =
            '登录被拒绝：${q['error']}${desc == null || desc.isEmpty ? '' : '（$desc）'}';
      } else if ((q['code'] ?? '').isEmpty) {
        error = '回调缺少授权码';
      } else {
        code = q['code'];
      }
      await _writeCallbackPage(req.response, ok: error == null);
      if (!completer.isCompleted) {
        if (error != null) {
          completer.completeError(AuthException(error));
        } else {
          completer.complete(code);
        }
      }
    });

    try {
      final launched = await launchUrl(
        authorizeUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) throw const AuthException('无法打开系统浏览器，请检查默认浏览器设置');
      return await completer.future.timeout(
        _kLoginTimeout,
        onTimeout: () => throw const AuthException('登录超时，请重试'),
      );
    } finally {
      await sub.cancel();
    }
  }

  /// 用授权码换令牌（不带 client_secret）。
  static Future<void> _exchangeCode(String code, String verifier) async {
    final data = await _postForm(Uri.parse('$kAuthBase/token'), {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': kRedirectUri,
      'client_id': kOAuthClientId,
      'code_verifier': verifier,
    });
    final access = data['access_token'];
    if (access is! String || access.isEmpty) {
      throw const AuthException('换取令牌失败：未返回 access_token');
    }
    final tokens = AuthTokens(
      accessToken: access,
      refreshToken: data['refresh_token'] as String?,
      idToken: data['id_token'] as String?,
      expiresAt: _expiryOf(data['expires_in']),
    );
    await _persist(tokens);
  }

  /* ============ 登录（builtin：自带 6 位动态码） ============ */

  /// builtin 登录：`POST ${kApiBase}/api/admin/login {code}` → `200 {token}`。
  ///
  /// token 12h 有效、无 refresh；失败抛 [BuiltinLoginException]（401 验证码错误 /
  /// 403 需先绑定验证器 / 429 失败过多）。`client` / `baseUrl` 仅供测试注入。
  static Future<void> loginWithCode(
    String code, {
    http.Client? client,
    String? baseUrl,
  }) async {
    final uri = Uri.parse('${_apiBase(baseUrl)}/api/admin/login');
    http.Response res;
    try {
      final send = client?.post ?? http.post;
      res = await send(
        uri,
        headers: _jsonHeaders,
        body: jsonEncode({'code': code}),
      ).timeout(_kHttpTimeout);
    } catch (e) {
      throw BuiltinLoginException('网络异常：$e');
    }
    final data = _decodeJson(res);
    final token = data['token'];
    if (res.statusCode >= 200 &&
        res.statusCode < 300 &&
        token is String &&
        token.isNotEmpty) {
      await _persistBuiltin(token);
      return;
    }
    throw BuiltinLoginException(
      (data['error'] as String?) ?? 'HTTP ${res.statusCode}',
      statusCode: res.statusCode,
      errorCode: data['code'] as String?,
      retryAfter: _retryAfterOf(data),
    );
  }

  /// 首次绑定验证器：`GET ${kApiBase}/api/admin/totp/setup`（免鉴权，已绑定则 409）。
  /// 返回 otpauth URI（兼容 `otpauthUri` / 老版 `uri` / 只有 `secret`）。
  static Future<String> fetchTotpSetup({
    http.Client? client,
    String? baseUrl,
  }) async {
    final uri = Uri.parse('${_apiBase(baseUrl)}/api/admin/totp/setup');
    http.Response res;
    try {
      final send = client?.get ?? http.get;
      res = await send(uri, headers: _jsonHeaders).timeout(_kHttpTimeout);
    } catch (e) {
      throw BuiltinLoginException('网络异常：$e');
    }
    final data = _decodeJson(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BuiltinLoginException(
        (data['error'] as String?) ?? 'HTTP ${res.statusCode}',
        statusCode: res.statusCode,
        errorCode: data['code'] as String?,
        retryAfter: _retryAfterOf(data),
      );
    }
    final uriField =
        (data['otpauthUri'] as String?) ?? (data['uri'] as String?);
    if (uriField != null && uriField.isNotEmpty) return uriField;
    final secret = data['secret'];
    if (secret is String && secret.isNotEmpty) {
      // 老版本只回裸 secret：拼一个最小可用的 otpauth URI（账户名仅作展示）。
      return 'otpauth://totp/Admin?secret=$secret&issuer=Admin';
    }
    throw const BuiltinLoginException('服务端未返回绑定信息');
  }

  /* ============ 续期 / 登出 ============ */

  /// 用 refresh_token 静默续期（grant_type=refresh_token，仍不带 secret）。
  /// 单飞：并发 401 只触发一次续期。成功返回 true。
  static Future<bool> refresh() {
    final existing = _refreshing;
    if (existing != null) return existing;
    final f = _doRefresh().whenComplete(() => _refreshing = null);
    _refreshing = f;
    return f;
  }

  static Future<bool> _doRefresh() async {
    final current = _tokens ?? await _read();
    final rt = current?.refreshToken;
    if (rt == null || rt.isEmpty) return false;
    try {
      final res = await http
          .post(
            Uri.parse('$kAuthBase/token'),
            headers: _formHeaders,
            body: {
              'grant_type': 'refresh_token',
              'refresh_token': rt,
              'client_id': kOAuthClientId,
            },
          )
          .timeout(_kHttpTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final data = _json(res);
      final access = data['access_token'];
      if (access is! String || access.isEmpty) return false;
      final tokens = AuthTokens(
        accessToken: access,
        refreshToken: (data['refresh_token'] as String?) ?? rt,
        idToken: (data['id_token'] as String?) ?? current?.idToken,
        expiresAt: _expiryOf(data['expires_in']),
      );
      await _persist(tokens);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 登出：先清空安全存储（同步语义，立刻不可用），再 best-effort 后台调吊销接口。
  /// sso → 认证中心 `/revoke`；builtin → `POST /api/admin/logout`（幂等）。
  /// 不做任何「静默登出后还能用」的缓存。
  static Future<void> logout() async {
    final current = _tokens ?? await _read();
    await clear();
    if (current?.builtin ?? false) {
      unawaited(_builtinLogout(current!.accessToken));
    } else {
      unawaited(_revokeAll(current));
    }
  }

  /// builtin 登出（best-effort，失败不阻断登出）：带 Bearer 让服务端作废 token。
  static Future<void> _builtinLogout(
    String token, {
    http.Client? client,
    String? baseUrl,
  }) async {
    if (token.isEmpty) return;
    try {
      final uri = Uri.parse('${_apiBase(baseUrl)}/api/admin/logout');
      final send = client?.post ?? http.post;
      await send(
        uri,
        headers: {..._jsonHeaders, 'Authorization': 'Bearer $token'},
      ).timeout(_kRevokeTimeout);
    } catch (_) {
      /* 登出接口失败不阻断登出：本地令牌已清，无法再用 */
    }
  }

  static Future<void> _revokeAll(AuthTokens? tokens) async {
    final refresh = tokens?.refreshToken;
    final access = tokens?.accessToken;
    if (refresh != null && refresh.isNotEmpty) {
      await _revoke(refresh);
    }
    if (access != null && access.isNotEmpty) {
      await _revoke(access);
    }
  }

  static Future<void> _revoke(String token) async {
    try {
      await http
          .post(
            Uri.parse('$kAuthBase/revoke'),
            headers: _formHeaders,
            body: {'token': token, 'client_id': kOAuthClientId},
          )
          .timeout(_kRevokeTimeout);
    } catch (_) {
      /* 吊销失败不阻断登出：本地令牌已清，无法再用 */
    }
  }

  /* ============ 存储 ============ */

  static Future<AuthTokens?> _read() async {
    try {
      return await _readFromStorage().timeout(kStorageTimeout);
    } catch (e) {
      // 安全存储不可用（如 KeyStore 异常、超时）时按未登录处理，不抛给调用方
      _markStorageUnavailable(e);
      return null;
    }
  }

  static Future<AuthTokens?> _readFromStorage() async {
    final access = await _storage.read(key: _kAccess) ?? '';
    final refresh = await _storage.read(key: _kRefresh);
    if (access.isEmpty && (refresh == null || refresh.isEmpty)) {
      return _readBuiltinFromStorage();
    }
    final id = await _storage.read(key: _kId);
    final expRaw = await _storage.read(key: _kExpiry);
    final expMs = expRaw == null ? null : int.tryParse(expRaw);
    return AuthTokens(
      accessToken: access,
      refreshToken: refresh,
      idToken: id,
      expiresAt: expMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expMs),
    );
  }

  /// builtin 令牌：由签发时间 + [kBuiltinTokenTtl] 换算过期时刻（无 refresh）。
  static Future<AuthTokens?> _readBuiltinFromStorage() async {
    final token = await _storage.read(key: _kBuiltinAccess) ?? '';
    if (token.isEmpty) return null;
    final issuedRaw = await _storage.read(key: _kBuiltinIssuedAt);
    final issuedMs = issuedRaw == null ? null : int.tryParse(issuedRaw);
    return AuthTokens(
      accessToken: token,
      builtin: true,
      expiresAt: issuedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(issuedMs).add(kBuiltinTokenTtl),
    );
  }

  /// 先落内存，再尽力写安全存储：写入失败/超时只标记「不持久保存」，不抛出，
  /// 保证本次会话（登录、API）仍可用。
  static Future<void> _persist(AuthTokens t) async {
    _tokens = t;
    try {
      await _writeToStorage(t).timeout(kStorageTimeout);
    } catch (e) {
      _markStorageUnavailable(e);
    }
  }

  /// builtin 登录成功：记签发时间，12h 后本地判定过期（不做 refresh）。
  static Future<void> _persistBuiltin(String token) async {
    final issuedAt = DateTime.now();
    _tokens = AuthTokens(
      accessToken: token,
      builtin: true,
      expiresAt: issuedAt.add(kBuiltinTokenTtl),
    );
    try {
      await _writeBuiltinToStorage(token, issuedAt).timeout(kStorageTimeout);
    } catch (e) {
      _markStorageUnavailable(e);
    }
  }

  static Future<void> _writeToStorage(AuthTokens t) async {
    await _storage.write(key: _kAccess, value: t.accessToken);
    final exp = t.expiresAt;
    if (exp == null) {
      await _storage.delete(key: _kExpiry);
    } else {
      await _storage.write(
        key: _kExpiry,
        value: exp.millisecondsSinceEpoch.toString(),
      );
    }
    await _writeOrDelete(_kRefresh, t.refreshToken);
    await _writeOrDelete(_kId, t.idToken);
    // 切到 sso 后清掉 builtin 残留，避免下次启动读串
    await _storage.delete(key: _kBuiltinAccess);
    await _storage.delete(key: _kBuiltinIssuedAt);
  }

  static Future<void> _writeBuiltinToStorage(
    String token,
    DateTime issuedAt,
  ) async {
    await _storage.write(key: _kBuiltinAccess, value: token);
    await _storage.write(
      key: _kBuiltinIssuedAt,
      value: issuedAt.millisecondsSinceEpoch.toString(),
    );
    // 切到 builtin 后清掉 oauth 残留
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kId);
    await _storage.delete(key: _kExpiry);
  }

  static Future<void> _writeOrDelete(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  /* ============ HTTP 小工具 ============ */

  static const Map<String, String> _formHeaders = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Accept': 'application/json',
  };

  /// POST 表单，2xx 返回 JSON（失败抛 [AuthException]，带服务端 error_description）。
  static Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, String> body,
  ) async {
    http.Response res;
    try {
      res = await http
          .post(uri, headers: _formHeaders, body: body)
          .timeout(_kHttpTimeout);
    } catch (e) {
      throw AuthException('网络异常：$e');
    }
    final data = _json(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final desc =
          data['error_description'] ??
          data['error'] ??
          'HTTP ${res.statusCode}';
      throw AuthException('认证中心返回错误：$desc');
    }
    return data;
  }

  static Map<String, dynamic> _json(http.Response res) {
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  /// builtin REST 请求头（JSON）。
  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  /// 解析 JSON 对象响应（非对象 / 解析失败返回空 Map）。
  static Map<String, dynamic> _decodeJson(http.Response res) {
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  static int? _retryAfterOf(Map<String, dynamic> data) {
    final v = data['retryAfter'];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// API 基址（测试可注入 [baseUrl]），去掉结尾多余斜杠。
  static String _apiBase(String? baseUrl) {
    final b = (baseUrl ?? kApiBase).trim();
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  static DateTime? _expiryOf(dynamic expiresIn) {
    int? seconds;
    if (expiresIn is num) {
      seconds = expiresIn.toInt();
    } else if (expiresIn is String) {
      seconds = int.tryParse(expiresIn);
    }
    if (seconds == null) return null;
    return DateTime.now().add(Duration(seconds: seconds));
  }

  /// 回调页：纯静态、无外部资源，读完即可关闭。
  static Future<void> _writeCallbackPage(
    HttpResponse res, {
    required bool ok,
  }) async {
    res.statusCode = ok ? HttpStatus.ok : HttpStatus.badRequest;
    res.headers.contentType = ContentType.html;
    final title = ok ? '登录完成' : '登录失败';
    final body = ok ? '登录完成，可以关闭此页回到 App。' : '登录未完成，请回到 App 重试。';
    res.write(
      '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>$title</title></head>'
      '<body style="font-family:sans-serif;text-align:center;padding:80px 24px;color:#171512">'
      '<p style="font-size:16px">$body</p></body></html>',
    );
    await res.close();
  }
}
