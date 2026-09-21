import 'package:flutter/material.dart';

import 'api.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'notification_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.restoreToken();
  await ThemePrefs.load();
  Api.onAuthRequired = forceLogout;
  // 前台服务 isolate 若发现 token 失效，走同一套全局登出
  onNotificationAuthRequired = forceLogout;
  await NotificationService.init();
  runApp(const AdminApp());
}

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Brightness>(
      valueListenable: ThemePrefs.brightness,
      builder: (context, brightness, _) {
        return MaterialApp(
          title: 'Admin',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          theme: buildTheme(brightness),
          home: Api.token.isEmpty ? const LoginPage() : const HomePage(),
        );
      },
    );
  }
}
