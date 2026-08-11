import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 后端 API 地址
const String kApiBase = 'https://zhangyunling.cn';

class ApiException implements Exception {
  final String message;
  final int? code;
  ApiException(this.message, {this.code});

  bool get isAuth => code == 401;

  @override
  String toString() => message;
}

/// REST API 封装：登录 / 系统信息 / 上传 / 下载 / 修改密码
class Api {
  Api._();

  static const _tokenKey = 'admin_token';
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

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$kApiBase$path').replace(queryParameters: query);

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

  /// POST /api/admin/login {password} -> {token}
  static Future<String> login(String password) async {
    final res = await http.post(
      _uri('/api/admin/login'),
      headers: _headers(),
      body: jsonEncode({'password': password}),
    );
    final data = _decode(res);
    final t = data['token'];
    if (t is! String || t.isEmpty) {
      throw ApiException('登录失败：未返回 token');
    }
    return t;
  }

  /// GET /api/admin/system（Bearer）-> 系统信息
  static Future<Map<String, dynamic>> system() async {
    final res = await http.get(_uri('/api/admin/system'), headers: _headers());
    return _decode(res);
  }

  /// POST /api/admin/upload（multipart 字段名 file）-> {path}
  static Future<String> upload(File file, String filename) async {
    final req = http.MultipartRequest('POST', _uri('/api/admin/upload'));
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
      _uri('/api/admin/download', {'path': path}),
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
      _uri('/api/admin/download', {'path': path, 'token': _token}).toString();

  /// POST /api/admin/password {old_password, new_password}
  static Future<void> changePassword(
    String oldPassword,
    String newPassword,
  ) async {
    final res = await http.post(
      _uri('/api/admin/password'),
      headers: _headers(),
      body: jsonEncode({
        'old_password': oldPassword,
        'new_password': newPassword,
      }),
    );
    _decode(res);
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
      throw ApiException(
        (data['error'] as String?) ?? 'HTTP ${res.statusCode}',
        code: res.statusCode,
      );
    }
    return data;
  }

  static String _errorOf(http.Response res) {
    if (res.statusCode == 401) return '未登录或登录已过期';
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map) {
        return (decoded['error'] as String?) ?? 'HTTP ${res.statusCode}';
      }
    } catch (_) {}
    return 'HTTP ${res.statusCode}';
  }
}
