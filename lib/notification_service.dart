import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'notification_model.dart';
import 'notification_store.dart';

/// 常驻通知文案（克制，不花哨）
const String kNotificationServiceTitle = 'HomeAdmin';
const String kNotificationServiceText = '通知服务运行中';

/// 本地通知渠道（与前台服务通知分开，避免互相覆盖）
const String kLocalChannelId = 'home_admin_notifications';
const String kLocalChannelName = '通知消息';
const String kLocalChannelDescription = '收到新通知时提醒';

/// SSE 连接：建立/读取超时；无数据传输由心跳超时兜底
const Duration _kConnectTimeout = Duration(seconds: 20);

/// 服务 isolate 因 401 失效时回调（main 注入 `forceLogout`，避免与 login_page 循环依赖）
void Function()? onNotificationAuthRequired;

/// 点开本地通知时跳转通知页（HomePage 注入，切换抽屉 Tab）
void Function()? onOpenNotifications;

/// 前台服务 isolate 入口（必须是顶层函数 + entry-point 标注）
@pragma('vm:entry-point')
void notificationServiceCallback() {
  FlutterForegroundTask.setTaskHandler(NotificationTaskHandler());
}

/// 前台服务 / 本地通知的装配与开关（主 isolate 侧）。
class NotificationService {
  NotificationService._();

  /// 与服务 Manifest 中的 serviceId 对应（任意稳定正整数）
  static const int _serviceId = 2005;

  static bool _initialized = false;

  static bool get _android => !kIsWeb && Platform.isAndroid;

  /// 在 `runApp` 前调用：初始化前台服务与本地通知。
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (!_android) return;

    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'home_admin_service',
        channelName: '后台通知服务',
        channelDescription: '保持通知连接常驻',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 15s 一次：用于调用 onRepeatEvent 做心跳超时兜底检查
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);

    await _initLocalNotifications();
  }

  static Future<void> _initLocalNotifications() async {
    try {
      await FlutterLocalNotificationsPlugin().initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (_) => onOpenNotifications?.call(),
      );
    } catch (e) {
      debugPrint('本地通知初始化失败: $e');
    }
  }

  static void _onTaskData(Object data) {
    NotificationStore.applyTaskData(data);
    if (data is Map && data['type'] == 'auth_required') {
      onNotificationAuthRequired?.call();
    }
  }

  /// 已登录则确保服务在运行；返回当前是否运行。
  static Future<bool> ensureStarted() async {
    if (!_android || !_initialized) return false;
    if (Api.token.isEmpty) return false;
    if (await FlutterForegroundTask.isRunningService) {
      NotificationStore.running.value = true;
      return true;
    }
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: kNotificationServiceTitle,
      notificationText: kNotificationServiceText,
      notificationInitialRoute: '/',
      callback: notificationServiceCallback,
    );
    final ok = result is ServiceRequestSuccess;
    NotificationStore.running.value = ok;
    return ok;
  }

  /// 重启通知服务；未运行则直接启动。返回是否最终在运行。
  static Future<bool> restart() async {
    if (!_android || !_initialized) return false;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await ensureStarted();
    }
    final running = await FlutterForegroundTask.isRunningService;
    NotificationStore.running.value = running;
    return running;
  }

  /// 停止服务（退出登录时调用）。
  static Future<void> stop() async {
    if (!_android || !_initialized) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('通知服务停止失败: $e');
    }
    NotificationStore.running.value = false;
  }

  static Future<bool> isRunning() async {
    if (!_android || !_initialized) return false;
    return FlutterForegroundTask.isRunningService;
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_android || !_initialized) return false;
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  /// 申请忽略电池优化（自签名分发，不走商店，可用）。
  static Future<void> requestIgnoreBatteryOptimization() async {
    if (!_android || !_initialized) return;
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  /// App 是否由点开本地通知启动（冷启动直达通知页）。
  static Future<bool> launchedFromNotification() async {
    if (!_android) return false;
    try {
      final details =
          await FlutterLocalNotificationsPlugin().getNotificationAppLaunchDetails();
      return details?.didNotificationLaunchApp ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 前台服务任务：在独立 isolate 内维持通知 SSE 长连接 + 弹本地通知。
class NotificationTaskHandler extends TaskHandler {
  _NotificationStreamRunner? _runner;
  FlutterLocalNotificationsPlugin? _local;
  bool _localReady = false;
  int _unread = 0;

  /// 最后一次收到事件的时间（epoch 秒）
  int _lastEvent = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _unread =
        (await FlutterForegroundTask.getData<int>(
          key: NotificationStore.kUnreadKey,
        )) ??
        0;
    _lastEvent =
        (await FlutterForegroundTask.getData<int>(
          key: NotificationStore.kHeartbeatKey,
        )) ??
        0;
    await _ensureLocalNotifications();

    final token = await Api.readPersistedToken();
    FlutterForegroundTask.sendDataToMain({
      'type': 'service_started',
      'unread': _unread,
      'ts': _lastEvent,
    });
    if (token.isEmpty) return; // 未登录：保持服务但不连接

    _runner = _NotificationStreamRunner(
      token: token,
      onNotification: _handleNotification,
      onHeartbeat: _handleHeartbeat,
      onAuthRequired: _handleAuthRequired,
    )..start();
  }

  /// 心跳超时兜底：连接已死但没收到 onDone 时，主动断开触发重连。
  @override
  void onRepeatEvent(DateTime timestamp) {
    _runner?.checkHeartbeatTimeout();
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    if (data['type'] == 'set_unread') {
      final value = data['value'];
      if (value is num) {
        _unread = value.toInt() < 0 ? 0 : value.toInt();
        unawaited(_persist());
        unawaited(_refreshServiceNotification());
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _runner?.stop();
    _runner = null;
  }

  Future<void> _ensureLocalNotifications() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _local = plugin;
      _localReady = true;
    } catch (e) {
      debugPrint('服务内本地通知初始化失败: $e');
      _localReady = false;
    }
  }

  Future<void> _persist() async {
    await FlutterForegroundTask.saveData(
      key: NotificationStore.kUnreadKey,
      value: _unread,
    );
    await FlutterForegroundTask.saveData(
      key: NotificationStore.kHeartbeatKey,
      value: _lastEvent,
    );
  }

  Future<void> _handleNotification(NotificationItem item) async {
    _unread += 1;
    _lastEvent = _nowSeconds();
    await _persist();
    FlutterForegroundTask.sendDataToMain({
      'type': 'notification',
      'item': item.toJson(),
      'unread': _unread,
      'ts': _lastEvent,
    });
    await _showLocal(item);
    await _refreshServiceNotification();
  }

  Future<void> _handleHeartbeat(int epochSeconds) async {
    _lastEvent = epochSeconds > 0 ? epochSeconds : _nowSeconds();
    await _persist();
    FlutterForegroundTask.sendDataToMain({
      'type': 'heartbeat',
      'ts': _lastEvent,
      'unread': _unread,
    });
  }

  Future<void> _handleAuthRequired() async {
    _runner?.stop();
    _runner = null;
    FlutterForegroundTask.sendDataToMain({'type': 'auth_required'});
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('401 后停止通知服务失败: $e');
    }
  }

  Future<void> _showLocal(NotificationItem item) async {
    final plugin = _local;
    if (!_localReady || plugin == null) return;
    final title = item.title.isEmpty ? kNotificationServiceTitle : item.title;
    final body =
        (item.body != null && item.body!.isNotEmpty) ? item.body! : item.source;
    try {
      await plugin.show(
        id: notificationLocalId(item.id),
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kLocalChannelId,
            kLocalChannelName,
            channelDescription: kLocalChannelDescription,
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
        payload: item.link ?? '',
      );
    } catch (e) {
      debugPrint('弹本地通知失败: $e');
    }
  }

  Future<void> _refreshServiceNotification() async {
    if (_runner == null) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: kNotificationServiceTitle,
        notificationText: _unread > 0
            ? '$kNotificationServiceText · 未读 $_unread'
            : kNotificationServiceText,
      );
    } catch (e) {
      debugPrint('更新常驻通知失败: $e');
    }
  }
}

/// 通知 SSE 长连接：指数退避重连（1s→2s→…→60s），90s 无事件主动重连。
class _NotificationStreamRunner {
  _NotificationStreamRunner({
    required this.token,
    required this.onNotification,
    required this.onHeartbeat,
    required this.onAuthRequired,
  });

  final String token;
  final Future<void> Function(NotificationItem item) onNotification;
  final Future<void> Function(int epochSeconds) onHeartbeat;
  final Future<void> Function() onAuthRequired;

  http.Client? _active;
  bool _stopped = false;
  int _lastEvent = 0;
  Duration _backoff = kNotificationInitialBackoff;

  void start() {
    unawaited(_loop());
  }

  void stop() {
    _stopped = true;
    _active?.close();
    _active = null;
  }

  /// 心跳超时：切掉当前连接，让 `_loop` 进入下一轮退避重连。
  void checkHeartbeatTimeout() {
    if (_stopped) return;
    if (_lastEvent > 0 &&
        notificationHeartbeatExpired(_lastEvent, _nowSeconds())) {
      _active?.close();
    }
  }

  Future<void> _loop() async {
    while (!_stopped) {
      final client = http.Client();
      _active = client;
      try {
        final request = http.Request(
          'GET',
          Uri.parse('$kApiBase/api/admin/notifications/stream'),
        );
        request.headers['Authorization'] = 'Bearer $token';
        request.headers['Accept'] = 'text/event-stream';
        request.headers['Cache-Control'] = 'no-cache';
        request.headers['Connection'] = 'keep-alive';
        final response = await client.send(request).timeout(_kConnectTimeout);

        if (response.statusCode == 401) {
          _stopped = true;
          await onAuthRequired();
          break;
        }
        if (response.statusCode != 200) {
          throw http.ClientException('SSE HTTP ${response.statusCode}');
        }

        _backoff = kNotificationInitialBackoff;
        _lastEvent = _nowSeconds();
        final parser = SseParser();
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          if (_stopped) break;
          for (final frame in parser.feed(chunk)) {
            _lastEvent = _nowSeconds();
            await _dispatch(frame);
          }
        }
      } catch (e) {
        if (!_stopped) debugPrint('通知流连接中断: $e');
      } finally {
        client.close();
        if (identical(_active, client)) _active = null;
      }

      if (_stopped) break;
      await Future<void>.delayed(_backoff);
      _backoff = nextNotificationBackoff(_backoff);
    }
  }

  Future<void> _dispatch(SseFrame frame) async {
    if (frame.event == 'notification') {
      final json = frame.json;
      if (json != null) {
        await onNotification(NotificationItem.fromJson(json));
      }
    } else if (frame.event == 'heartbeat') {
      final ts = frame.json?['ts'];
      await onHeartbeat(ts is num ? ts.toInt() : _nowSeconds());
    }
  }
}

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
