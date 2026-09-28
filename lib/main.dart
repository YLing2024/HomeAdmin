import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'auth.dart';
import 'login_page.dart';
import 'notification_service.dart';
import 'startup.dart';
import 'theme.dart';

void main() {
  // 首帧路径只允许同步调用：确保绑定就绪（无 IO、不会挂）。
  WidgetsFlutterBinding.ensureInitialized();

  // 同步装配回调（纯赋值，不阻塞首帧）。
  Api.onAuthRequired = forceLogout;
  onNotificationAuthRequired = handleNotificationAuthRequired;

  // 先把界面画出来：安全存储 / 令牌 / 主题 / 通知服务全部移到 runApp 之后
  // 异步进行（各步自带超时与降级，见 startup.dart），任何一步失败都不白屏。
  runApp(const AdminApp());
  unawaited(AppStartup.run());
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
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          theme: buildTheme(brightness),
          // 登录态异步就绪后再切换登录页 / 主页
          home: const StartupGate(),
        );
      },
    );
  }
}
