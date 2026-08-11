import 'package:flutter/material.dart';

import 'api.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'theme.dart';
import 'ws.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.restoreToken();
  await ThemePrefs.load();
  Api.onAuthRequired = forceLogout;
  WsClient.instance.onAuthRequired = forceLogout;
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
