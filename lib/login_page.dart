import 'package:flutter/material.dart';

import 'api.dart';
import 'home_page.dart';
import 'theme.dart';
import 'ws.dart';

/// 全局导航 key（供 401 / WS 4001 登出跳转使用）
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

bool _forceLogoutRunning = false;

/// 全局登出：清除 token、关闭 WS、回到登录页。幂等，可被多次触发。
Future<void> forceLogout() async {
  if (_forceLogoutRunning) return;
  _forceLogoutRunning = true;
  try {
    await Api.logout();
    await WsClient.instance.close();
    final nav = rootNavigatorKey.currentState;
    if (nav != null) {
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }
  } finally {
    _forceLogoutRunning = false;
  }
}

/// 处理鉴权失败（401）：登出并回到登录页。返回是否已处理。
Future<bool> handleAuthError(BuildContext context, Object e) async {
  if (e is! ApiException || !e.isAuth) return false;
  await forceLogout();
  return true;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _pw = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final pw = _pw.text.trim();
    if (pw.isEmpty) {
      _toast('请输入密码');
      return;
    }
    setState(() => _busy = true);
    try {
      final token = await Api.login(pw);
      await Api.saveToken(token);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GlowBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
                  decoration: BoxDecoration(
                    color: kSurface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: kBorder),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 40,
                        offset: Offset(0, 20),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        child: Container(
                          width: 76,
                          height: 76,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            gradient: kAmberGradient,
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: kAmber.withValues(alpha: 0.35),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.admin_panel_settings,
                            color: Colors.black,
                            size: 40,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Admin',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '云铃管理后台',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kMuted, fontSize: 13),
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _pw,
                        obscureText: _obscure,
                        autofocus: true,
                        enabled: !_busy,
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          hintText: '请输入管理密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: kAmberGradient,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: kAmber.withValues(alpha: 0.25),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: _busy ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                          ),
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text('登 录'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.fingerprint,
                            size: 14,
                            color: kMuted,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '仅限管理员访问',
                            style: TextStyle(color: kMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
