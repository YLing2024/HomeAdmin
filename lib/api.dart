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

  /// POST /api/login {code} -> {token, expiresIn}
  /// 失败可能返回错误码：invalid_code / rate_limited(带 retryAfter) / totp_setup_required
  static Future<String> login(String code) async {
    final res = await http.post(
      _uri(kAuthBase, '/api/login'),
      headers: _headers(),
      body: jsonEncode({'code': code}),
    );
    final data = _decode(res);
    final t = data['token'];
    if (t is! String || t.isEmpty) {
      throw ApiException('登录失败：未返回 token');
    }
    return t;
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
