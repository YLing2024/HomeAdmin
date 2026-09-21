import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_model.dart';

// 构建时必须带 --dart-define 注入真实地址，否则将回退到占位域、连不上后端：
//   flutter build apk --release --dart-define=API_BASE=... --dart-define=AUTH_BASE=...

/// 管理后台 API 基址（nginx 入口，Bearer token 由 auth_request 探针校验）
const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'https://api.example.com',
);

/// 认证中心 API 基址（登录校验 TOTP 动态码并签发会话 token）
const String kAuthBase = String.fromEnvironment(
  'AUTH_BASE',
  defaultValue: 'https://auth.example.com',
);

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

/// 原始 HTTP 调用结果：调试页展示「最近一次请求的状态码与响应体」用。
///
/// 与 [ApiException] 不同，这类调用**不抛异常**：无论 2xx 还是 4xx/5xx 都原样
/// 返回，方便把真实状态码与响应体摆到调试界面上排查。
class ApiCallResult {
  const ApiCallResult({required this.status, required this.body});

  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;

  /// 解析响应体 JSON（非对象或解析失败返回 null）。
  Map<String, dynamic>? get json {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 创建通知返回的 id（`201 { id, ts }`）；无则 null。
  int? get id {
    final v = json?['id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
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

  /// 读取本地持久化的 token（供前台服务 isolate 读取，复用同一存储键，
  /// 不另写一套鉴权；登录态变化仍由 saveToken / logout 维护）。
  static Future<String> readPersistedToken() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_tokenKey) ?? '';
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

  /// 把服务端返回的相对路径（图片 / 预览链接）拼成绝对地址；
  /// 已是 http(s)、data 等带 scheme 的地址原样返回。
  static String absoluteUrl(String path) {
    final p = path.trim();
    if (p.isEmpty) return p;
    final uri = Uri.tryParse(p);
    if (uri != null && uri.hasScheme) return p;
    return p.startsWith('/') ? '$kApiBase$p' : '$kApiBase/$p';
  }

  /* ============ 文件区（对齐 Web Files.jsx / admin-server 文件路由） ============ */

  /// GET /api/admin/files?path= -> { path, parent, entries: [{name, type, size, mtime}] }
  /// path 为相对文件区根目录的路径，根目录为 ''（越界由后端拦截）。
  /// _uri 的 queryParameters 走 Uri.encodeQueryComponent，`lost+found` 等名称编码正确。
  static Future<Map<String, dynamic>> fileList(String path) async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/files', {'path': path}),
      headers: _headers(),
    );
    return _decode(res);
  }

  /// POST /api/admin/files/mkdir { path, name }
  static Future<void> fileMkdir(String dir, String name) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/files/mkdir'),
      headers: _headers(),
      body: jsonEncode({'path': dir, 'name': name}),
    );
    _decode(res);
  }

  /// POST /api/admin/files/rename { path, name }
  static Future<void> fileRename(String path, String name) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/files/rename'),
      headers: _headers(),
      body: jsonEncode({'path': path, 'name': name}),
    );
    _decode(res);
  }

  /// DELETE /api/admin/files?path=（目录递归删除）
  static Future<void> fileDelete(String path) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/admin/files', {'path': path}),
      headers: _headers(),
    );
    _decode(res);
  }

  /// 文件下载 URL（token 走查询参数，供 url_launcher 打开；<a>/浏览器无法带自定义头）
  static String fileDownloadUrl(String path) => _uri(
        kApiBase,
        '/api/admin/files/download',
        {'path': path, 'token': _token},
      ).toString();

  /// POST /api/admin/files/upload?path=（multipart 字段名 file，上限 500MB）
  /// onProgress 回调已发送字节数（HTTP 段），落盘耗时可配合 99% 文案；
  /// abortTrigger 完成即中断上传（取消按钮）；重名后端自动加 -2。
  static Future<Map<String, dynamic>> fileUpload(
    File file,
    String filename,
    String dir, {
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final req = _ProgressMultipartRequest(
      'POST',
      _uri(kApiBase, '/api/admin/files/upload', {'path': dir}),
      onProgress: onProgress,
    );
    req.headers['Authorization'] = 'Bearer $_token';
    req.abortTrigger = abortTrigger;
    req.files.add(
      await http.MultipartFile.fromPath('file', file.path, filename: filename),
    );
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    return _decode(res);
  }

  /* ============ 文件区 · 临时链接（限时分享，对齐 Web FileShare.jsx） ============ */
  // 语义对齐后端 /api/admin/files/shares：expiresAt === 0 为永久有效哨兵；
  // 分享链接一律使用后端返回的 url 字段，不拼域名。

  /// GET /api/admin/files/shares -> { shares: [...] }
  /// 列表接口正常返回 { shares }，这里兼容裸数组（双保险）。
  static Future<List<Map<String, dynamic>>> fileShares() async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/files/shares'),
      headers: _headers(),
    );
    return _decodeListOr(res, 'shares')
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// POST /api/admin/files/shares { path, ttlHours? | expiresAt?, note? } -> 记录（含 url）
  /// ttlHours 与 expiresAt 二选一：expiresAt 为绝对 epoch 毫秒（0 = 永久），
  /// 都不给时后端默认 24 小时。
  static Future<Map<String, dynamic>> fileShareCreate({
    required String path,
    int? ttlHours,
    int? expiresAt,
    String? note,
  }) async {
    final body = <String, dynamic>{'path': path};
    if (expiresAt != null) {
      body['expiresAt'] = expiresAt;
    } else if (ttlHours != null) {
      body['ttlHours'] = ttlHours;
    }
    final n = note?.trim() ?? '';
    if (n.isNotEmpty) body['note'] = n;
    final res = await http.post(
      _uri(kApiBase, '/api/admin/files/shares'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _shareRecord(_decode(res));
  }

  /// PATCH /api/admin/files/shares/{id} { expiresAt?, note?, revoked? } -> 记录
  /// expiresAt: 0 转永久；>0 改为该绝对到期时刻；revoked: true 撤销（不可逆）。
  static Future<Map<String, dynamic>> fileShareUpdate(
    String id, {
    int? expiresAt,
    String? note,
    bool? revoked,
  }) async {
    final body = <String, dynamic>{};
    if (expiresAt != null) body['expiresAt'] = expiresAt;
    if (note != null) body['note'] = note;
    if (revoked != null) body['revoked'] = revoked;
    final res = await http.patch(
      _uri(kApiBase, '/api/admin/files/shares/${Uri.encodeComponent(id)}'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _shareRecord(_decode(res));
  }

  /// DELETE /api/admin/files/shares/{id}（仅删记录，不动磁盘文件）
  static Future<void> fileShareDelete(String id) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/admin/files/shares/${Uri.encodeComponent(id)}'),
      headers: _headers(),
    );
    _decode(res);
  }

  /// 后端直接返回记录；兼容被包一层 share 的写法（双保险）。
  static Map<String, dynamic> _shareRecord(Map<String, dynamic> data) {
    final rec = data['share'];
    return rec is Map ? Map<String, dynamic>.from(rec) : data;
  }

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

  /// GET /api/blog/admin/posts/{id}/preview-link -> { published, url }
  /// 已发布回公开地址；草稿附短时效预览令牌（url 为服务端返回的相对路径）。
  static Future<Map<String, dynamic>> blogPostPreviewLink(int id) async {
    final res = await http.get(
      _uri(kApiBase, '/api/blog/admin/posts/$id/preview-link'),
      headers: _headers(),
    );
    return _decode(res);
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

  /* ============ 通知中心 ============ */

  /// GET /api/admin/notifications?limit=&before=&unread=1&level=&source=&type=
  /// → { items: [{id, ts, level, source, type, title, body, link, readAt}], unread, total }
  /// ts / readAt 为 epoch 秒；before 传列表最后一条的 id（按 id 倒序翻页）。
  /// type 为通知类别（服务端定义），与 unread / level / source 可叠加。
  static Future<Map<String, dynamic>> notifications({
    int limit = 50,
    int? before,
    bool unreadOnly = false,
    String? level,
    String? source,
    String? type,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (before != null) query['before'] = '$before';
    if (unreadOnly) query['unread'] = '1';
    if (level != null && level.isNotEmpty) query['level'] = level;
    if (source != null && source.isNotEmpty) query['source'] = source;
    if (type != null && type.isNotEmpty) query['type'] = type;
    final res = await http.get(
      _uri(kApiBase, '/api/admin/notifications', query),
      headers: _headers(),
    );
    return _decode(res);
  }

  /// GET /api/admin/notifications/types
  /// → { types: [{ key, label, description, defaultLevel, sort, enabled, count, unread }] }
  ///
  /// 类别由服务端定义，客户端**不内置任何清单**；服务端新增类别无需发版。
  static Future<List<NotificationType>> notificationTypes() async {
    final res = await http.get(
      _uri(kApiBase, '/api/admin/notifications/types'),
      headers: _headers(),
    );
    final data = _decode(res);
    final raw = data['types'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => NotificationType.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// POST /api/admin/notifications/{id}/read -> { ok: true }
  static Future<void> notificationRead(int id) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/notifications/$id/read'),
      headers: _headers(),
    );
    _decode(res);
  }

  /// POST /api/admin/notifications/read-all -> { ok: true, count: N }
  static Future<int> notificationReadAll() async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/notifications/read-all'),
      headers: _headers(),
    );
    final data = _decode(res);
    final count = data['count'];
    return count is num ? count.toInt() : 0;
  }

  /// DELETE /api/admin/notifications/{id} -> { ok: true }
  static Future<void> notificationDelete(int id) async {
    final res = await http.delete(
      _uri(kApiBase, '/api/admin/notifications/$id'),
      headers: _headers(),
    );
    _decode(res);
  }

  /// POST /api/admin/notifications
  ///   { level, source, title, body?, link?, dedupKey? } -> 201 { id, ts }
  ///
  /// 调试页发测试通知用。为展示「最近一次调用的状态码与响应体」，这里不抛异常，
  /// 原样返回 [ApiCallResult]；401 仍触发全局登出（与其它请求一致）。
  static Future<ApiCallResult> createNotification(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      _uri(kApiBase, '/api/admin/notifications'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 401) _notifyAuthRequired();
    return ApiCallResult(
      status: res.statusCode,
      body: utf8.decode(res.bodyBytes),
    );
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

  /// 解析「对象包裹的数组字段」或「裸数组」两种响应（分享列表双保险）
  static List<dynamic> _decodeListOr(http.Response res, String key) {
    if (res.statusCode == 401) {
      _notifyAuthRequired();
      throw ApiException('未登录或登录已过期', code: 401);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(_errorOf(res), code: res.statusCode);
    }
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is List) return decoded;
      if (decoded is Map && decoded[key] is List) return decoded[key] as List;
    } catch (_) {}
    return const [];
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

/// 带上传进度的 multipart 请求：finalize 时统计已发送字节，
/// 并支持通过 [abortTrigger] 中断（http Client 支持 Abortable）。
class _ProgressMultipartRequest extends http.MultipartRequest with http.Abortable {
  _ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  final void Function(int sent, int total)? onProgress;

  @override
  Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    final onP = onProgress;
    final base = super.finalize();
    if (onP == null) return base;
    return http.ByteStream(
      base.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            sent += data.length;
            onP(sent, total);
            sink.add(data);
          },
        ),
      ),
    );
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
