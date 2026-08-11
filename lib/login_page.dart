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

/// 登录页：输入 6 位 TOTP 动态验证码，调认证中心 /api/login 校验
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      _toast('请输入验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await Api.login(code);
      await Api.saveToken(token);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (handled) return;
      setState(() => _error = _messageOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _messageOf(Object e) {
    if (e is ApiException) {
      if (e.errorCode == 'rate_limited' && e.retryAfter != null) {
        return '尝试过多，请 ${e.retryAfter} 秒后再试';
      }
      if (e.errorCode == 'totp_setup_required') {
        return '服务端 TOTP 未配置，请先联系管理员设置';
      }
      return e.message;
    }
    return e.toString();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
                      TextField(
                        controller: _code,
                        focusNode: _focus,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        maxLength: 6,
                        onSubmitted: (_) => _busy ? null : _login(),
                        decoration: InputDecoration(
                          hintText: '输入 6 位动态验证码',
                          counterText: '',
                          prefixIcon: const Icon(Icons.fingerprint),
                          errorText: _error,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _busy ? null : _login,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.2),
                              )
                            : const Text('登 录'),
                      ),
                      const SizedBox(height: 16),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.fingerprint, size: 14, color: kMutedHint),
                          SizedBox(width: 6),
                          Text(
                            'TOTP 动态验证码登录',
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
