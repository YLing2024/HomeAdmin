import 'dart:async';

import 'package:flutter/material.dart';

import 'auth.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'notification_service.dart';
import 'theme.dart';

/// 启动阶段：`loading` 期间只渲染轻量占位（不闪白屏），`ready` 后按登录态切换。
enum StartupPhase { loading, ready }

/// 首帧之后异步就绪的启动状态。界面只监听它，不依赖任何未完成的 IO。
@immutable
class StartupStatus {
  const StartupStatus({this.phase = StartupPhase.loading, this.loggedIn = false});

  final StartupPhase phase;
  final bool loggedIn;

  StartupStatus copyWith({StartupPhase? phase, bool? loggedIn}) => StartupStatus(
    phase: phase ?? this.phase,
    loggedIn: loggedIn ?? this.loggedIn,
  );
}

/// 启动编排：**只能在 `runApp` 之后调用**。
///
/// 首帧路径上只保留同步调用；这里每一步都独立 try/catch + 超时，失败一律降级，
/// 绝不抛出、绝不阻塞界面。安全存储不可用时本次会话走内存态（见 [Auth]）。
class AppStartup {
  AppStartup._();

  /// 本地读取（安全存储 / 偏好）超时：超过按不可用继续，不让启动挂住。
  static const Duration localTimeout = Duration(seconds: 5);

  /// 启动状态：根组件监听它决定渲染占位 / 登录页 / 主页。
  static final ValueNotifier<StartupStatus> status =
      ValueNotifier<StartupStatus>(const StartupStatus());

  static bool _started = false;

  /// 在 `runApp` 之后 fire-and-forget。多次调用幂等。
  static Future<void> run() async {
    if (_started) return;
    _started = true;

    // 1) 登录态：安全存储 5s 超时，失败按未登录，绝不影响首帧
    try {
      await Auth.init().timeout(localTimeout);
    } catch (e) {
      debugPrint('启动：读取登录态失败，按未登录继续: $e');
    }

    // 2) 主题偏好：失败保留默认（深色）
    try {
      await ThemePrefs.load().timeout(localTimeout);
    } catch (e) {
      debugPrint('启动：读取主题偏好失败，用默认深色: $e');
    }

    // 首帧所需状态就绪：未登录 → 登录页，已登录 → 主页（由界面监听切换）
    status.value = status.value.copyWith(
      phase: StartupPhase.ready,
      loggedIn: Auth.hasSession,
    );

    // 3)(4) 之后的都是后台增强，失败不进主流程：静默续期 + 通知服务
    unawaited(_ensureAccessTokenQuietly());
    unawaited(_initNotificationsQuietly());
  }

  /// access_token 过期时静默续期（只允许主 isolate，见 auth.dart 头注）；
  /// 续期失败说明整条链已废，回登录页。任何异常只记录。
  static Future<void> _ensureAccessTokenQuietly() async {
    if (!Auth.hasSession) return;
    try {
      final ok = await Auth.ensureValidAccessToken();
      if (!ok && Auth.hasSession) await forceLogout();
    } catch (e) {
      debugPrint('启动：静默续期失败: $e');
    }
  }

  /// 通知服务初始化：独立 try/catch，起不来不影响主界面与登录。
  static Future<void> _initNotificationsQuietly() async {
    try {
      await NotificationService.init();
    } catch (e) {
      debugPrint('启动：通知服务初始化失败（已隔离）: $e');
    }
  }

  /// 仅测试用：重置编排状态（生产的启动只发生一次）。
  @visibleForTesting
  static void resetForTest() {
    _started = false;
    status.value = const StartupStatus();
  }
}

/// 启动闸门：占位 → 按登录态渲染主页或登录页。界面只依赖 [AppStartup.status]。
class StartupGate extends StatelessWidget {
  const StartupGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<StartupStatus>(
      valueListenable: AppStartup.status,
      builder: (context, status, _) {
        if (status.phase == StartupPhase.loading) return const StartupSplash();
        return status.loggedIn ? const HomePage() : const LoginPage();
      },
    );
  }
}

/// 轻量启动占位：与登录页同一底色与标识，避免白屏闪烁；无网络、无动画依赖。
class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: GlowBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
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
              const SizedBox(height: 20),
              Text(
                'Admin',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '正在恢复登录状态',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
