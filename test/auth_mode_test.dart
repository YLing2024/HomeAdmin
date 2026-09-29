import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_admin/auth_mode.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 探测必须"宁 sso 勿 builtin"：任何异常 / 非 200 / 结构不符都按 sso。
void main() {
  setUp(AuthModeProbe.reset);

  MockClient ok(String body, [int status = 200]) =>
      MockClient((_) async => http.Response(body, status));

  test('200 且 authMode=sso → sso', () async {
    final mode = await AuthModeProbe.get(
      client: ok('{"authMode":"sso"}'),
      baseUrl: 'https://probe.test',
    );
    expect(mode, AuthMode.sso);
  });

  test('200 且 authMode=builtin → builtin', () async {
    final mode = await AuthModeProbe.get(
      client: ok('{"authMode":"builtin"}'),
      baseUrl: 'https://probe.test',
    );
    expect(mode, AuthMode.builtin);
  });

  test('非 200（500）→ sso', () async {
    final mode = await AuthModeProbe.get(
      client: ok('{"authMode":"builtin"}', 500),
      baseUrl: 'https://probe.test',
    );
    expect(mode, AuthMode.sso);
  });

  test('坏 JSON → sso', () async {
    final mode = await AuthModeProbe.get(
      client: ok('not json at all'),
      baseUrl: 'https://probe.test',
    );
    expect(mode, AuthMode.sso);
  });

  test('结构不符（authMode 为未知值 / 缺字段 / 非对象）→ sso', () async {
    for (final body in ['{"authMode":"weird"}', '{}', '"builtin"', '[]']) {
      AuthModeProbe.reset();
      final mode = await AuthModeProbe.get(
        client: ok(body),
        baseUrl: 'https://probe.test',
      );
      expect(mode, AuthMode.sso, reason: 'body=$body');
    }
  });

  test('请求抛异常 → sso', () async {
    final client = MockClient((_) async => throw const SocketExceptionLike());
    final mode = await AuthModeProbe.get(
      client: client,
      baseUrl: 'https://probe.test',
    );
    expect(mode, AuthMode.sso);
  });

  test('超时 → sso', () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    final mode = await AuthModeProbe.get(
      client: client,
      baseUrl: 'https://probe.test',
      timeout: const Duration(milliseconds: 30),
    );
    expect(mode, AuthMode.sso);
  });

  test('缓存生效：同一进程只探一次', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{"authMode":"builtin"}', 200);
    });
    final first = await AuthModeProbe.get(
      client: client,
      baseUrl: 'https://probe.test',
    );
    final second = await AuthModeProbe.get(
      client: client,
      baseUrl: 'https://probe.test',
    );
    expect(first, AuthMode.builtin);
    expect(second, AuthMode.builtin);
    expect(calls, 1, reason: '第二次命中缓存，不应再发请求');
    expect(AuthModeProbe.cached, AuthMode.builtin);
  });

  test('并发探只发一次请求（单飞）', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response('{"authMode":"sso"}', 200);
    });
    final results = await Future.wait([
      AuthModeProbe.get(client: client, baseUrl: 'https://probe.test'),
      AuthModeProbe.get(client: client, baseUrl: 'https://probe.test'),
    ]);
    expect(results, [AuthMode.sso, AuthMode.sso]);
    expect(calls, 1);
  });
}

/// 用于模拟网络异常（避免依赖 dart:io 的具体异常类型）。
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
