import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_admin/auth.dart';
import 'package:home_admin/auth_mode.dart';
import 'package:home_admin/home_page.dart';
import 'package:home_admin/login_page.dart';
import 'package:home_admin/main.dart' as app;
import 'package:home_admin/startup.dart';
import 'package:home_admin/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动回归：`main()` 必须在任何初始化之前先渲染首帧；
/// 安全存储异常/超时只能降级，绝不白屏、绝不崩。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Auth.storageAvailable.value = true;
    // 固定为 sso，避免用例依赖真实网络探测（探测本身由 auth_mode_test 覆盖）
    AuthModeProbe.seed(AuthMode.sso);
    AppStartup.resetForTest();
  });

  testWidgets('安全存储抛异常时 main 仍渲染首帧，降级到登录页而非白屏/崩溃', (tester) async {
    // 测试环境没有 flutter_secure_storage 的平台通道，Auth 读写必然抛
    // MissingPluginException——等价于真机上 KeyStore 异常/挂住。
    app.main();

    // 第一帧：启动占位已渲染（不是白屏）
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(StartupSplash), findsOneWidget);

    // 放行异步初始化（每步 try/catch + 5s 超时）
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));

    expect(Auth.storageAvailable.value, isFalse, reason: '安全存储异常应被判定为不可用');
    expect(find.byType(LoginPage), findsOneWidget, reason: '应降级到登录页');
    expect(find.byType(HomePage), findsNothing);
    expect(tester.takeException(), isNull, reason: '初始化失败不得抛出到界面');
  });

  testWidgets('初始化失败不阻断登录路径：登录页可交互并明确提示不持久保存', (tester) async {
    Auth.storageAvailable.value = false;

    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(Brightness.dark), home: const LoginPage()),
    );
    await tester.pump();

    expect(find.text('使用系统浏览器登录'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNotNull, reason: '登录按钮必须可用');
    expect(find.textContaining('不会持久保存'), findsOneWidget, reason: '不得静默假装成功');
    expect(tester.takeException(), isNull);
  });

  test('安全存储异常时 Auth 降级为未登录且不抛出', () async {
    await Auth.init().timeout(const Duration(seconds: 2));
    expect(Auth.storageAvailable.value, isFalse);
    expect(Auth.hasSession, isFalse);
  });
}
