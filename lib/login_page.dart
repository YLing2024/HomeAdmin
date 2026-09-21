import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'home_page.dart';
import 'notification_service.dart';
import 'theme.dart';

/// 全局导航 key（供 401 登出跳转使用）
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

bool _forceLogoutRunning = false;

/// 全局登出：清除 token、回到登录页。幂等，可被多次触发。
Future<void> forceLogout() async {
  if (_forceLogoutRunning) return;
  _forceLogoutRunning = true;
  try {
    // 登出即停通知服务，避免用已失效 token 继续连 SSE
    await NotificationService.stop();
    await Api.logout();
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
        // 首次使用：服务端 TOTP 未配置 → 引导首次绑定（对齐认证中心登录页 setup 流程）
        _startSetup();
        return '首次使用：请先完成下方绑定，再输入动态码';
      }
      return e.message;
    }
    return e.toString();
  }

  /// 首次 TOTP 绑定：调认证中心 /api/totp/setup 获取 secret + otpauthUri，
  /// 弹窗展示 QR 码 + secret（对齐认证中心登录页 setup 区块）
  Future<void> _startSetup() async {
    try {
      final data = await Api.totpSetup();
      if (!mounted) return;
      final secret = (data['secret'] ?? '').toString();
      final uri = (data['otpauthUri'] ?? '').toString();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: ctx.c.surface,
          title: Text('绑定 TOTP 验证器', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '在验证器 App（如 Google Authenticator / 1Password）中扫描二维码，或手动输入密钥，然后回登录页输入动态码。',
                  style: TextStyle(color: ctx.c.muted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                Center(
                  child: QrImageView(
                    data: uri,
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.all(8),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'SECRET',
                  style: TextStyle(
                    color: ctx.c.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ctx.c.bg,
                    border: Border.all(color: ctx.c.border),
                  ),
                  child: SelectableText(
                    secret,
                    style: TextStyle(
                      color: ctx.c.fg,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'OTPAUTH URI',
                  style: TextStyle(
                    color: ctx.c.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ctx.c.bg,
                    border: Border.all(color: ctx.c.border),
                  ),
                  child: SelectableText(
                    uri,
                    style: TextStyle(color: ctx.c.muted, fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: secret));
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('密钥已复制')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制密钥'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('关闭', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '初始化失败: ${e.toString()}');
    }
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
