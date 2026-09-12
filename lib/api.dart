import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 管理后台 API 基址（nginx 入口，Bearer token 由 auth_request 探针校验）
const String kApiBase = 'https://zhangyunling.cn';

/// 认证中心 API 基址（登录校验 TOTP 动态码并签发会话 token）
const String kAuthBase = 'https://auth.zhangyunling.cn';

class ApiException implements Exception {
  final String message;
  final int? code;
  final String? errorCode;
  final int? retryAfter;

  ApiException(this.message, {this.code, this.errorCode, this.retryAfter});

  bool get isAuth => code == 401;

  @override
  String toString() => message;
}

/// REST API 封装：认证中心 token 登录 / 系统监控 / 上传下载 / TOTP 重置 / 博客管理
class Api {
  Api._();

  static const _tokenKey = 'auth_token';
  static String _token = '';

  static String get token => _token;

  static void setToken(String value) => _token = value;

  /// 启动时从本地恢复 token
  static Future<void> restoreToken() async {
    final sp = await SharedPreferences.getInstance();
    _token = sp.getString(_tokenKey) ?? '';
  }

  /// 清除 token 并持久化移除
  static Future<void> logout() async {
    _token = '';
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_tokenKey);
  }

  /// 持久化保存 token
  static Future<void> saveToken(String value) async {
    _token = value;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_tokenKey, value);
  }

  static Uri _uri(String base, String path, [Map<String, String>? query]) =>
      Uri.parse('$base$path').replace(queryParameters: query);

  static Map<String, String> _headers({bool json = true}) => {
    if (json) 'Content-Type': 'application/json',
    if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
  };

  /// 鉴权失效回调（401），由 main 注册为全局登出
  static Future<void> Function()? onAuthRequired;

  static void _notifyAuthRequired() {
    final cb = onAuthRequired;
    if (cb != null) unawaited(cb());
  }

  /* ============ 登录（认证中心） ============ */

  /// POST /api/login {code, deviceName} -> {token, expiresIn}
  /// 失败可能返回错误码：invalid_code / rate_limited(带 retryAfter) / totp_setup_required
  static Future<String> login(String code) async {
    final res = await http.post(
      _uri(kAuthBase, '/api/login'),
      headers: _headers(),
      body: jsonEncode({'code': code, 'deviceName': _deviceName()}),
    );
    final data = _decode(res);
    final t = data['token'];
    if (t is! String || t.isEmpty) {
      throw ApiException('登录失败：未返回 token');
    }
    return t;
  }

  /// POST /api/totp/setup -> { secret, otpauthUri }
  /// 认证中心首次 TOTP 绑定（仅未配置时可用；已配置返回 409）
  static Future<Map<String, dynamic>> totpSetup() async {
    final res = await http.post(
      _uri(kAuthBase, '/api/totp/setup'),
      headers: _headers(),
    );
    return _decode(res);
  }

  /// 设备名推导（对齐 Web deviceName()：应用名 · 系统，供设备会话管理展示）
  static String _deviceName() {
    try {
      final sys = Platform.operatingSystem;
      String label;
      switch (sys) {
        case 'android':
          label = 'Android';
        case 'ios':
          label = 'iOS';
        case 'windows':
          label = 'Windows';
        case 'macos':
          label = 'macOS';
        case 'linux':
          label = 'Linux';
        default:
          label = sys;
      }
      return 'HomeAdmin · $label';
    } catch (_) {
      return 'HomeAdmin';
    }
  }

  /* ============ 系统监控 ============ */

  /// GET /api/admin/system
  static Future<Map<String, dynamic>> system() async {
    final res = await http.get(_uri(kApiBase, '/api/admin/system'), headers: _headers());
    return _decode(res);
  }

  /// GET /api/admin/system/history -> 采样点数组（服务端直接返回 JSON 数组）
  static Future<List<dynamic>> systemHistory() async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/system/history'),
      headers: _headers(),
    );
    return _decodeList(res);
  }

  /// GET /api/admin/services -> { services, processes }
  static Future<Map<String, dynamic>> services() async {
    final res = await http.get(_uri(kApiBase, '/api/admin/services'), headers: _headers());
    return _decode(res);
  }

  /// GET /api/admin/versions -> { list }
  static Future<List<dynamic>> versions() async {
    final res = await http.get(_uri(kApiBase, '/api/admin/versions'), headers: _headers());
    final data = _decode(res);
    final list = data['list'];
    return list is List ? list : [];
  }

  /* ============ 历史会话浏览（只读） ============ */

  /// GET /api/admin/history -> { sessions: [{ id, title, time, message_count }] }
  static Future<Map<String, dynamic>> historySessions() async {
    final res = await http.get(_uri(kApiBase, '/api/admin/history'), headers: _headers());
    return _decode(res);
  }

  /// GET /api/admin/history/{id} -> { session: { id, title }, messages: [{ role, content, ts }] }
  static Future<Map<String, dynamic>> historyMessages(String id) async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/history/${Uri.encodeComponent(id)}'),
      headers: _headers(),
    );
    return _decode(res);
  }

  /* ============ 设备会话管理（认证中心转发） ============ */

  /// GET /api/admin/sessions -> { sessions: [{ id, deviceName, ip, isLocal,
  ///   location, userAgent, createdAt, lastSeenAt, expiresAt(秒), isCurrent }] }
  static Future<List<Map<String, dynamic>>> sessions() async {
    final res = await http.get(_uri(kApiBase, '/api/admin/sessions'), headers: _headers());
    final data = _decode(res);
    final list = data['sessions'];
    return (list is List)
        ? list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : [];
  }

  /// PUT /api/admin/sessions/{id}/name { deviceName }
  static Future<void> sessionRename(String id, String deviceName) async {
    final res = await http.put(
      _uri(kApiBase, '/api/admin/sessions/${Uri.encodeComponent(id)}/name'),
      headers: _headers(),
      body: jsonEncode({'deviceName': deviceName}),
    );
    _decode(res);
  }

  /// DELETE /api/admin/sessions/{id}
  static Future<void> sessionDelete(String id) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/admin/sessions/${Uri.encodeComponent(id)}'),
      headers: _headers(),
    );
    _decode(res);
  }

  /* ============ 接口令牌管理（与登录设备隔离） ============ */

  /// GET /api/admin/api-tokens -> { tokens: [{ id, name, note, createdAt,
  ///   expiresAt, lastUsedAt }] }（绝不含 token 明文）
  static Future<List<Map<String, dynamic>>> apiTokens() async {
    final res = await http.get(_uri(kApiBase, '/api/admin/api-tokens'), headers: _headers());
    final data = _decode(res);
    final list = data['tokens'];
    return (list is List)
        ? list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : [];
  }

  /// POST /api/admin/api-tokens { name, note, expiresInDays } -> { id, token, meta }
  /// token 明文仅此一次返回
  static Future<Map<String, dynamic>> apiTokenCreate({
    required String name,
    String note = '',
    required int expiresInDays,
  }) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/api-tokens'),
      headers: _headers(),
      body: jsonEncode({'name': name, 'note': note, 'expiresInDays': expiresInDays}),
    );
    return _decode(res);
  }

  /// PATCH /api/admin/api-tokens/{id}，可选 { name, note, expiresInDays }
  static Future<void> apiTokenUpdate(String id, Map<String, dynamic> patch) async {
    final res = await http.patch(
      _uri(kApiBase, '/api/admin/api-tokens/${Uri.encodeComponent(id)}'),
      headers: _headers(),
      body: jsonEncode(patch),
    );
    _decode(res);
  }

  /// DELETE /api/admin/api-tokens/{id}（吊销，立即失效）
  static Future<void> apiTokenDelete(String id) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/admin/api-tokens/${Uri.encodeComponent(id)}'),
      headers: _headers(),
    );
    _decode(res);
  }

  /* ============ 服务器终端（ttyd + tmux，对齐 Web Terminal.jsx） ============ */

  /// POST /api/admin/term/unlock { password } -> { ticket, expiresIn }
  /// 注意：口令错误时服务端返回 401，这里不能走 _decode 的「登录过期」回调，
  /// 否则输错口令会被全局登出；429 时 ApiException.retryAfter 为锁定剩余秒数。
  static Future<Map<String, dynamic>> termUnlock(String password) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/term/unlock'),
      headers: _headers(),
      body: jsonEncode({'password': password}),
    );
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      data = (decoded is Map) ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      data = {};
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        (data['error'] as String?) ?? 'HTTP ${res.statusCode}',
        code: res.statusCode,
        retryAfter: data['retryAfter'] is num
            ? (data['retryAfter'] as num).toInt()
            : null,
      );
    }
    return data;
  }

  /// GET /api/admin/term/sessions -> { sessions: [{ name, attached, activity }] }
  static Future<List<Map<String, dynamic>>> termSessions() async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/term/sessions'),
      headers: _headers(),
    );
    final data = _decode(res);
    final list = data['sessions'];
    return (list is List)
        ? list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : [];
  }

  /// DELETE /api/admin/term/sessions/{name}（关闭单个会话，关标签时调用）
  static Future<void> termCloseSession(String name) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/admin/term/sessions/${Uri.encodeComponent(name)}'),
      headers: _headers(),
    );
    _decode(res);
  }

  /// POST /api/admin/term/sessions/close { names }（批量关闭，锁定/离开时调用）
  static Future<void> termCloseSessions(List<String> names) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/term/sessions/close'),
      headers: _headers(),
      body: jsonEncode({'names': names}),
    );
    _decode(res);
  }

  /// 终端 WebView 地址：token 供探针鉴权；两个 arg 按 ttyd --url-arg 顺序
  /// 传给服务端 wrapper（$1=会话名，$2=票据）
  static String termUrl(String name, String ticket) =>
      Uri.parse('$kApiBase/term/').replace(queryParameters: {
        'token': _token,
        'arg': [name, ticket],
      }).toString();

  /* ============ 上传 / 下载 ============ */

  /// POST /api/admin/upload（multipart 字段名 file）-> {path}
  static Future<String> upload(File file, String filename) async {
    final req = http.MultipartRequest('POST', _uri(kApiBase, '/api/admin/upload'));
    req.headers['Authorization'] = 'Bearer $_token';
    req.files.add(
      await http.MultipartFile.fromPath('file', file.path, filename: filename),
    );
    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final res = await http.Response.fromStream(streamed);
    final data = _decode(res);
    final p = data['path'];
    if (p is! String || p.isEmpty) {
      throw ApiException('上传失败：未返回路径');
    }
    return p;
  }

  /// GET /api/admin/download?path= -> 文件字节
  static Future<Uint8List> download(String path) async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/download', {'path': path}),
      headers: _headers(),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      if (res.statusCode == 401) _notifyAuthRequired();
      throw ApiException(_errorOf(res), code: res.statusCode);
    }
    return res.bodyBytes;
  }

  /// 图片/附件的直接下载 URL（带 token 查询参数，供 Image.network 使用）
  static String downloadUrl(String path) =>
      _uri(kApiBase, '/api/admin/download', {'path': path, 'token': _token}).toString();

  /* ============ TOTP 重置（admin-server 代理到认证中心） ============ */

  /// POST /api/admin/totp/reset -> { secret, otpauthUri, expiresIn }
  static Future<Map<String, dynamic>> totpReset() async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/totp/reset'),
      headers: _headers(),
    );
    return _decode(res);
  }

  /// POST /api/admin/totp/confirm { code }
  static Future<void> totpResetConfirm(String code) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/totp/confirm'),
      headers: _headers(),
      body: jsonEncode({'code': code}),
    );
    _decode(res);
  }

  /* ============ 博客管理 ============ */

  /// GET /api/blog/admin/posts -> { list }
  static Future<List<dynamic>> blogPosts() async {
    final res = await http.get(
      _uri(kApiBase, '/api/blog/admin/posts'),
      headers: _headers(),
    );
    final data = _decode(res);
    final list = data['list'];
    return list is List ? list : [];
  }

  /// POST /api/blog/admin/posts
  static Future<Map<String, dynamic>> blogCreatePost(Map<String, dynamic> body) async {
    final res = await http.post(
      _uri(kApiBase, '/api/blog/admin/posts'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _decode(res);
  }

  /// PUT /api/blog/admin/posts/{id}
  static Future<Map<String, dynamic>> blogUpdatePost(int id, Map<String, dynamic> body) async {
    final res = await http.put(
      _uri(kApiBase, '/api/blog/admin/posts/$id'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _decode(res);
  }

  /// DELETE /api/blog/admin/posts/{id}
  static Future<void> blogDeletePost(int id) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/blog/admin/posts/$id'),
      headers: _headers(),
    );
    _decode(res);
  }

  /// GET /api/blog/admin/collections -> { list }
  static Future<List<dynamic>> blogCollections() async {
    final res = await http.get(
      _uri(kApiBase, '/api/blog/admin/collections'),
      headers: _headers(),
    );
    final data = _decode(res);
    final list = data['list'];
    return list is List ? list : [];
  }

  /// POST /api/blog/admin/collections
  static Future<Map<String, dynamic>> blogCreateCollection(Map<String, dynamic> body) async {
    final res = await http.post(
      _uri(kApiBase, '/api/blog/admin/collections'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _decode(res);
  }

  /// PUT /api/blog/admin/collections/{id}
  static Future<Map<String, dynamic>> blogUpdateCollection(
    int id,
    Map<String, dynamic> body,
  ) async {
    final res = await http.put(
      _uri(kApiBase, '/api/blog/admin/collections/$id'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _decode(res);
  }

  /// DELETE /api/blog/admin/collections/{id}
  static Future<void> blogDeleteCollection(int id) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/blog/admin/collections/$id'),
      headers: _headers(),
    );
    _decode(res);
  }

  /// POST /api/blog/admin/upload（multipart 字段名 image）-> { url }
  static Future<String> blogUploadImage(File file, String filename) async {
    final req = http.MultipartRequest(
      'POST',
      _uri(kApiBase, '/api/blog/admin/upload'),
    );
    req.headers['Authorization'] = 'Bearer $_token';
    req.files.add(
      await http.MultipartFile.fromPath('image', file.path, filename: filename),
    );
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final res = await http.Response.fromStream(streamed);
    final data = _decode(res);
    final url = data['url'];
    if (url is! String || url.isEmpty) {
      throw ApiException('图片上传失败：未返回 URL');
    }
    return url;
  }

  /* ============ SSE 实时流 ============ */

  /// 建立 /api/admin/system/stream 长连接。服务端每 ~1s 推一条
  /// `event: snapshot / data: {system, services, history}`。
  /// 返回句柄，调用 cancel() 即断开（对齐 Web：Tab 激活才连、切走断开）。
  static SystemStreamHandle systemStream({
    required void Function(Map<String, dynamic> snapshot) onSnapshot,
    void Function(String? error)? onError,
    void Function()? onDone,
  }) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..badCertificateCallback = (cert, host, port) => false;
    final request = client.getUrl(_uri(kApiBase, '/api/admin/system/stream'));
    final handle = SystemStreamHandle._(client);
    handle._run(request, onSnapshot, onError, onDone);
    return handle;
  }

  static String _errorOfStatus(int code) {
    if (code == 401) {
      _notifyAuthRequired();
      return '未登录或登录已过期';
    }
    return 'SSE HTTP $code';
  }

  /// 解析单条 SSE 帧（event:/data: 行），非 snapshot 返回 null
  static Map<String, dynamic>? _parseSseFrame(String frame) {
    String? event;
    String? data;
    for (final line in frame.split('\n')) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data = line.substring(5).trim();
      }
    }
    if (event != 'snapshot' || data == null) return null;
    try {
      final decoded = jsonDecode(data);
      return (decoded is Map) ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /* ============ 通用 ============ */

  /// 解析数组响应（服务端直接返回 JSON 数组，如 system/history）
  static List<dynamic> _decodeList(http.Response res) {
    if (res.statusCode == 401) {
      _notifyAuthRequired();
      throw ApiException('未登录或登录已过期', code: 401);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(_errorOf(res), code: res.statusCode);
    }
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode == 401) {
      _notifyAuthRequired();
      throw ApiException('未登录或登录已过期', code: 401);
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      data = (decoded is Map) ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      data = {};
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final message = (data['error'] as String?) ??
          (data['message'] as String?) ??
          'HTTP ${res.statusCode}';
      throw ApiException(
        message,
        code: res.statusCode,
        errorCode: data['code'] as String?,
        retryAfter: data['retryAfter'] is num
            ? (data['retryAfter'] as num).toInt()
            : null,
      );
    }
    return data;
  }

  static String _errorOf(http.Response res) {
    if (res.statusCode == 401) return '未登录或登录已过期';
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map) {
        return (decoded['error'] as String?) ??
            (decoded['message'] as String?) ??
            'HTTP ${res.statusCode}';
      }
    } catch (_) {}
    return 'HTTP ${res.statusCode}';
  }
}

/// SSE 长连接句柄：cancel() 断开流并释放连接
class SystemStreamHandle {
  SystemStreamHandle._(this._client);

  final HttpClient _client;
  HttpClientRequest? _request;
  bool _cancelled = false;
  bool _done = false;

  Future<void> _run(
    Future<HttpClientRequest> request,
    void Function(Map<String, dynamic> snapshot) onSnapshot,
    void Function(String? error)? onError,
    void Function()? onDone,
  ) async {
    try {
      final req = await request;
      if (_cancelled) {
        req.abort();
        return;
      }
      _request = req;
      req.headers.set('Authorization', 'Bearer ${Api.token}');
      final res = await req.close();
      if (res.statusCode != 200) {
        if (!_cancelled) onError?.call(Api._errorOfStatus(res.statusCode));
        if (!_cancelled) onDone?.call();
        _done = true;
        _client.close(force: true);
        return;
      }
      // 按 \n\n 分帧解析 SSE
      final transformer = _SseTransformer();
      final subscription = res
          .transform(utf8.decoder)
          .transform(transformer)
          .listen(
            (frame) {
              if (_cancelled) return;
              final snapshot = Api._parseSseFrame(frame);
              if (snapshot != null) onSnapshot(snapshot);
            },
            onError: (Object e) {
              if (_cancelled) return;
              onError?.call(e.toString());
            },
            onDone: () {
              if (_cancelled) return;
              onDone?.call();
            },
            cancelOnError: true,
          );
      await subscription.asFuture<void>().catchError((_) {});
    } catch (e) {
      if (!_cancelled) {
        onError?.call(e.toString());
        onDone?.call();
      }
    } finally {
      _done = true;
      _client.close(force: true);
    }
  }

  /// 主动断开连接
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _request?.abort();
    _client.close(force: true);
  }

  bool get isDone => _done;
}

/// 将字节流按 SSE 帧（\n\n 分隔）切分
class _SseTransformer extends StreamTransformerBase<String, String> {
  @override
  Stream<String> bind(Stream<String> stream) async* {
    var buf = '';
    await for (final chunk in stream) {
      buf += chunk;
      int idx;
      while ((idx = buf.indexOf('\n\n')) != -1) {
        final frame = buf.substring(0, idx);
        buf = buf.substring(idx + 2);
        if (frame.trim().isNotEmpty) yield frame;
      }
    }
  }
}
