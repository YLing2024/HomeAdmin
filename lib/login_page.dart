import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'auth.dart';
import 'auth_mode.dart';
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

/// 登录页（唯一入口）：按服务端认证模式渲染两套界面。
///
/// - `sso`（认证中心 PKCE）：系统浏览器完成标准 OAuth2 PKCE 登录（现状不变）。
/// - `builtin`（服务端自带口令）：输入 6 位动态验证码登录；首次使用先扫码绑定。
///
/// 进入页面先探测模式，未确定期间只显示 loading，不闪错界面；探测失败按 sso。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.initialMode, this.client, this.baseUrl});

  /// 仅测试注入：预置模式（跳过探测）。
  final AuthMode? initialMode;

  /// 仅测试注入：HTTP 客户端 / API 基址。
  final http.Client? client;
  final String? baseUrl;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  /// 当前模式（null = 探测中）。
  AuthMode? _mode;

  // sso
  bool _busy = false;
  String? _error;

  // builtin
  final TextEditingController _code = TextEditingController();
  bool _builtinBusy = false;
  String? _builtinError;
  int _lockRemaining = 0;
  Timer? _lockTimer;
  bool _binding = false;
  String? _bindUri;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    final preset = widget.initialMode ?? AuthModeProbe.cached;
    if (preset != null) {
      _mode = preset;
    } else {
      _probeMode();
    }
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _probeMode() async {
    final mode = await AuthModeProbe.get(
      client: widget.client,
      baseUrl: widget.baseUrl,
    );
    if (mounted) setState(() => _mode = mode);
  }

  /* ============ sso 登录 ============ */

  Future<void> _login() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Auth.login();
      if (!mounted) return;
      _afterLogin();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* ============ builtin 登录 ============ */

  Future<void> _builtinLogin() async {
    if (_builtinBusy || _lockRemaining > 0) return;
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _builtinError = '请输入 6 位数字验证码');
      return;
    }
    setState(() {
      _builtinBusy = true;
      _builtinError = null;
    });
    try {
      await Auth.loginWithCode(
        code,
        client: widget.client,
        baseUrl: widget.baseUrl,
      );
      if (!mounted) return;
      _afterLogin();
    } on BuiltinLoginException catch (e) {
      if (!mounted) return;
      if (e.setupRequired) {
        await _startBinding();
      } else {
        setState(() => _builtinError = e.message);
        final wait = e.retryAfter;
        if (wait != null && wait > 0) _startLock(wait);
      }
    } catch (e) {
      if (mounted) setState(() => _builtinError = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _builtinBusy = false);
    }
  }

  /// 首次使用：取绑定信息展示二维码，用户扫码后输入动态码即登录。
  Future<void> _startBinding() async {
    setState(() {
      _builtinBusy = true;
      _builtinError = null;
    });
    try {
      final uri = await Auth.fetchTotpSetup(
        client: widget.client,
        baseUrl: widget.baseUrl,
      );
      if (!mounted) return;
      setState(() {
        _binding = true;
        _bindUri = uri;
      });
    } on BuiltinLoginException catch (e) {
      if (mounted) setState(() => _builtinError = e.message);
    } catch (e) {
      if (mounted) setState(() => _builtinError = '获取绑定信息失败：$e');
    } finally {
      if (mounted) setState(() => _builtinBusy = false);
    }
  }

  /// 失败过多（429）：按 retryAfter 倒计时并禁用提交。
  void _startLock(int seconds) {
    _lockTimer?.cancel();
    setState(() => _lockRemaining = seconds);
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _lockRemaining--;
        if (_lockRemaining <= 0) {
          _lockRemaining = 0;
          timer.cancel();
        }
      });
    });
  }

  Future<void> _copyUri() async {
    final uri = _bindUri;
    if (uri == null || uri.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: uri));
      if (!mounted) return;
      setState(() => _copied = true);
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) setState(() => _copied = false);
    } catch (_) {
      if (mounted) setState(() => _builtinError = '复制失败，请手动复制');
    }
  }

  /// 登录成功：安全存储不可用时明确告知（不静默假装成功），再进主界面。
  void _afterLogin() {
    if (!Auth.storageAvailable.value) {
      showRootToast('本次登录不会持久保存，重启后需重新登录');
    }
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  /* ============ 界面 ============ */

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
                    children: _mode == null
                        ? _probing()
                        : _mode == AuthMode.builtin
                        ? _builtin()
                        : _sso(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _header() => [
    Align(
      child: Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.c.fg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.admin_panel_settings, color: context.c.bg, size: 40),
      ),
    ),
    const SizedBox(height: 20),
    Text(
      'Admin',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: context.c.fg,
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    ),
    const SizedBox(height: 6),
    Text(
      '云铃管理后台',
      textAlign: TextAlign.center,
      style: TextStyle(color: context.c.muted, fontSize: 13),
    ),
  ];

  /// 模式未定：只显示加载，不闪错界面。
  List<Widget> _probing() => [
    ..._header(),
    const SizedBox(height: 32),
    const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      ),
    ),
    const SizedBox(height: 14),
    Text(
      '正在连接服务',
      textAlign: TextAlign.center,
      style: TextStyle(color: context.c.muted, fontSize: 12),
    ),
  ];

  /// 认证中心 PKCE（原界面，行为不变）。
  List<Widget> _sso() => [
    ..._header(),
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
        style: TextStyle(color: context.c.danger, fontSize: 12),
      ),
    ],
    _storageWarning(),
    const SizedBox(height: 16),
    const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_outline, size: 14, color: kMutedHint),
        SizedBox(width: 6),
        Flexible(
          child: Text(
            '标准 OAuth2 PKCE · 登录态存系统安全存储',
            style: TextStyle(color: kMutedHint, fontSize: 12),
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          ),
        ),
      ],
    ),
  ];

  /// 服务端自带口令：6 位动态码登录 / 首次绑定。
  List<Widget> _builtin() {
    final c = context.c;
    final locked = _lockRemaining > 0;
    return [
      ..._header(),
      const SizedBox(height: 32),
      if (_binding) ...[
        Text(
          '在身份验证器中扫码添加，再输入生成的动态验证码。',
          style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 14),
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: QrImageView(
              data: _bindUri ?? '',
              size: 180,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: c.bg,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            (_bindUri ?? '').isEmpty ? '（未获取到绑定信息）' : _bindUri!,
            style: const TextStyle(
              color: kMutedHint,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _copied || (_bindUri ?? '').isEmpty ? null : _copyUri,
            icon: const Icon(Icons.copy, size: 14),
            label: Text(_copied ? '已复制' : '复制绑定信息'),
          ),
        ),
        const SizedBox(height: 6),
      ],
      TextField(
        controller: _code,
        enabled: !_builtinBusy && !locked,
        keyboardType: TextInputType.number,
        maxLength: 6,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        onSubmitted: (_) => _builtinLogin(),
        decoration: const InputDecoration(
          hintText: '输入 6 位动态验证码',
          counterText: '',
        ),
      ),
      const SizedBox(height: 16),
      ElevatedButton(
        onPressed: _builtinBusy || locked ? null : _builtinLogin,
        child: _builtinBusy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : const Text('登录'),
      ),
      if (_builtinError != null) ...[
        const SizedBox(height: 14),
        Text(
          _builtinError!,
          textAlign: TextAlign.center,
          style: TextStyle(color: c.danger, fontSize: 12),
        ),
      ],
      if (locked) ...[
        const SizedBox(height: 14),
        Text(
          '尝试次数过多，请 $_lockRemaining 秒后重试',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.warn, fontSize: 12),
        ),
      ],
      _storageWarning(),
      const SizedBox(height: 16),
      const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline, size: 14, color: kMutedHint),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              '动态验证码登录 · 登录态存系统安全存储',
              style: TextStyle(color: kMutedHint, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
        ],
      ),
    ];
  }

  /// 安全存储不可用：本次登录只在内存生效，明确告知（不静默）。
  Widget _storageWarning() {
    final c = context.c;
    return ValueListenableBuilder<bool>(
      valueListenable: Auth.storageAvailable,
      builder: (context, available, _) => available
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                '本次登录不会持久保存，重启后需重新登录',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.warn, fontSize: 12),
              ),
            ),
    );
  }
}

/// 登录页底部小字（浅深色通用的灰色）
const Color kMutedHint = Color(0xFF8A857F);
