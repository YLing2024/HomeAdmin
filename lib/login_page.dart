import 'package:flutter/material.dart';

import 'auth.dart';
import 'api.dart';
import 'home_page.dart';
import 'notification_service.dart';
import 'theme.dart';

/// 全局导航 key（供 401 登出跳转使用）
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

bool _forceLogoutRunning = false;

/// 全局登出：清空系统安全存储 + best-effort 吊销令牌，回到登录页。
/// 幂等，可被多次触发（401 兜底 / 用户主动退出 / 服务 isolate 上报）。
Future<void> forceLogout() async {
  if (_forceLogoutRunning) return;
  _forceLogoutRunning = true;
  try {
    // 登出即停通知服务，避免用已失效 token 继续连 SSE
    await NotificationService.stop();
    await Auth.logout();
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

/// 处理鉴权失败（401 且续期失败）：登出并回到登录页。返回是否已处理。
Future<bool> handleAuthError(BuildContext context, Object e) async {
  if (e is! ApiException || !e.isAuth) return false;
  await forceLogout();
  return true;
}

/// 登录页：不再输入 TOTP 动态码；点击后在**系统浏览器**完成认证中心的
/// 标准 OAuth2 PKCE 登录，授权码经回环地址回调换令牌，token 存系统安全存储。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Auth.login();
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
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
                    color: c.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
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
                            color: c.fg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.admin_panel_settings,
                            color: c.bg,
                            size: 40,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Admin',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '云铃管理后台',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 32),
                      ElevatedButton(
                        onPressed: _busy ? null : _login,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.2),
                              )
                            : const Text('使用系统浏览器登录'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.danger, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline, size: 14, color: kMutedHint),
                          SizedBox(width: 6),
                          Text(
                            '标准 OAuth2 PKCE · 登录态存系统安全存储',
                            style: TextStyle(color: kMutedHint, fontSize: 12),
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

/// 登录页底部小字（浅深色通用的灰色）
const Color kMutedHint = Color(0xFF8A857F);
