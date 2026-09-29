import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_admin/auth.dart';
import 'package:home_admin/auth_mode.dart';
import 'package:home_admin/login_page.dart';
import 'package:home_admin/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 带 utf-8 charset 的 JSON 响应（中文 body 不能用默认 latin1 编码）。
http.Response _json(String body, int status) => http.Response(
  body,
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// 登录页双模式：builtin 渲染动态码界面（含首次绑定），sso 保持原界面。
void main() {
  setUp(() {
    AuthModeProbe.reset();
    Auth.storageAvailable.value = true;
  });

  Widget app({AuthMode? mode = AuthMode.builtin, http.Client? client}) =>
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: LoginPage(
          initialMode: mode,
          client: client,
          baseUrl: 'https://api.test',
        ),
      );

  MockClient reply(String body, int status) =>
      MockClient((_) async => _json(body, status));

  Future<void> submit(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(TextField), code);
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('builtin 渲染 6 位动态码输入，不显示 sso 按钮', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('使用系统浏览器登录'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.number);
    expect(field.maxLength, 6);
    expect(find.text('登录'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget);
  });

  testWidgets('sso 渲染现有 PKCE 界面（回归）', (tester) async {
    await tester.pumpWidget(app(mode: AuthMode.sso));
    expect(find.text('使用系统浏览器登录'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('模式未定时只显示 loading，不闪错界面', (tester) async {
    final client = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return http.Response('{"authMode":"builtin"}', 200);
    });
    await tester.pumpWidget(app(mode: null, client: client));
    expect(find.text('正在连接服务'), findsOneWidget);
    expect(find.text('使用系统浏览器登录'), findsNothing);
    expect(find.text('登录'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在连接服务'), findsNothing);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('提交后 401 显示服务端错误', (tester) async {
    await tester.pumpWidget(app(client: reply('{"error":"验证码不正确"}', 401)));
    await submit(tester, '123456');
    expect(find.text('验证码不正确'), findsOneWidget);
  });

  testWidgets('429 retryAfter 倒计时期间禁用提交，结束后恢复', (tester) async {
    await tester.pumpWidget(
      app(client: reply('{"error":"尝试次数过多","retryAfter":3}', 429)),
    );
    await submit(tester, '123456');

    expect(find.textContaining('秒后重试'), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
      reason: '倒计时期间不得提交',
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('秒后重试'), findsNothing);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
      reason: '倒计时结束应恢复提交',
    );
  });

  testWidgets('403 totp_setup_required 进入首次绑定：展示二维码与绑定信息', (tester) async {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/totp/setup')) {
        return _json(
          '{"otpauthUri":"otpauth://totp/Admin?secret=ABC123"}',
          200,
        );
      }
      return _json('{"error":"需要绑定验证器","code":"totp_setup_required"}', 403);
    });
    await tester.pumpWidget(app(client: client));
    await submit(tester, '123456');

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('otpauth://totp/Admin?secret=ABC123'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget, reason: '绑定后仍可输入动态码');
  });

  test('fetchTotpSetup 兼容老版字段：只有 secret 时拼出 otpauth URI', () async {
    final uri = await Auth.fetchTotpSetup(
      client: reply('{"secret":"XYZ789"}', 200),
      baseUrl: 'https://api.test',
    );
    expect(uri, contains('otpauth://totp/'));
    expect(uri, contains('secret=XYZ789'));
  });

  test('loginWithCode 403 映射为 setupRequired', () async {
    await expectLater(
      Auth.loginWithCode(
        '123456',
        client: reply('{"error":"需要绑定","code":"totp_setup_required"}', 403),
        baseUrl: 'https://api.test',
      ),
      throwsA(
        isA<BuiltinLoginException>()
            .having((e) => e.setupRequired, 'setupRequired', isTrue)
            .having((e) => e.message, 'message', '需要绑定'),
      ),
    );
  });
}
