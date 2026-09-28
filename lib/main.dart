import 'package:flutter/material.dart';

import 'api.dart';
import 'auth.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'notification_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Auth.init();
  // access_token 可能已过期但 refresh_token 仍有效：启动时先静默续期一次
  final loggedIn = await Auth.ensureValidAccessToken();
  await ThemePrefs.load();
  Api.onAuthRequired = forceLogout;
  // 前台服务 isolate 若发现 401，统一上报主 isolate 续期/登出（见下）
  onNotificationAuthRequired = handleNotificationAuthRequired;
  await NotificationService.init();
  runApp(AdminApp(loggedIn: loggedIn));
}

/// 通知服务 isolate 上报 401：主 isolate 是**唯一**续期方（refresh_token 一次性，
/// 两个 isolate 同时续期会触发认证中心的重放保护、作废整条链）。
/// 续期成功则重启通知服务（服务会从安全存储读到新 token），失败才全局登出。
Future<void> handleNotificationAuthRequired() async {
  if (!Auth.hasSession) return; // 已在登出流程中，幂等返回
  final ok = await Auth.refresh();
  if (ok) {
    await NotificationService.restart();
  } else {
    await forceLogout();
  }
}

class AdminApp extends StatelessWidget {
  const AdminApp({super.key, required this.loggedIn});

  final bool loggedIn;

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
          home: loggedIn ? const HomePage() : const LoginPage(),
        );
      },
    );
  }
}
