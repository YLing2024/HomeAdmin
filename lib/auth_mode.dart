// 服务端认证模式探测：`admin-server` 的 `AUTH_MODE=builtin|sso`（默认 builtin）。
//
// 契约：`GET ${kApiBase}/api/admin/auth-mode`（免鉴权）返回
// `{"authMode":"builtin"|"sso"}`。
//
// **兜底铁律**：探测失败 / 非 200 / 结构不符一律按 **sso**。绝不能因为一次探测
// 失败就把用户自己的（sso）部署切成动态码登录页。结果在进程内缓存一次，
// 登录页与 [Auth] 复用，不在每次请求里重复探测。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';

/// 服务端认证模式。
enum AuthMode {
  /// 服务端自带口令：6 位动态验证码登录（`POST /api/admin/login`）。
  builtin,

  /// 认证中心 OAuth2 PKCE（现状不变）。
  sso,
}

/// 认证模式探测（进程内单次）。
class AuthModeProbe {
  AuthModeProbe._();

  /// 探测超时：失败即按 sso，不让登录页久等。
  static const Duration probeTimeout = Duration(seconds: 8);

  static AuthMode? _cached;
  static Future<AuthMode>? _inflight;

  /// 已缓存的结果（未探测过为 null），供界面同步取用避免闪错界面。
  static AuthMode? get cached => _cached;

  /// 探测模式：并发调用共享同一请求，结果缓存到进程结束。
  ///
  /// [client] / [baseUrl] / [timeout] 仅用于测试注入。
  static Future<AuthMode> get({
    http.Client? client,
    String? baseUrl,
    Duration? timeout,
  }) {
    final hit = _cached;
    if (hit != null) return Future<AuthMode>.value(hit);
    final running = _inflight;
    if (running != null) return running;
    final f = _probe(
      client,
      baseUrl,
      timeout ?? probeTimeout,
    ).whenComplete(() => _inflight = null);
    _inflight = f;
    return f;
  }

  static Future<AuthMode> _probe(
    http.Client? client,
    String? baseUrl,
    Duration timeout,
  ) async {
    var mode = AuthMode.sso; // 默认与兜底：sso
    try {
      final uri = Uri.parse('${_base(baseUrl)}/api/admin/auth-mode');
      final res = await (client?.get(uri) ?? http.get(uri)).timeout(timeout);
      if (res.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final value = decoded is Map ? decoded['authMode'] : null;
        if (value == 'builtin') mode = AuthMode.builtin;
      }
    } catch (_) {
      // 网络异常 / 超时 / 坏 JSON：按 sso
    }
    _cached = mode;
    return mode;
  }

  static String _base(String? baseUrl) {
    final b = (baseUrl ?? kApiBase).trim();
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  /// 仅测试用：清空缓存与在途请求。
  @visibleForTesting
  static void reset() {
    _cached = null;
    _inflight = null;
  }

  /// 仅测试用：直接写入缓存（跳过网络）。
  @visibleForTesting
  static void seed(AuthMode mode) {
    _cached = mode;
    _inflight = null;
  }
}
