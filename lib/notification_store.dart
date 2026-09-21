import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'notification_model.dart';

/// 主 isolate 与前台服务 isolate 共享的通知状态（未读 / 最后心跳 / 服务是否运行）。
///
/// 持久化走 `flutter_foreground_task` 的原生存储（而非 shared_preferences），
/// 因为它本来就是为跨 isolate 通信设计的，两边读写同一份，不会互相覆盖缓存。
class NotificationStore {
  NotificationStore._();

  /// 服务侧存储键（服务 isolate 与主 isolate 必须一致）
  static const String kUnreadKey = 'notif_unread';
  static const String kHeartbeatKey = 'notif_last_heartbeat';

  static final ValueNotifier<int> unread = ValueNotifier<int>(0);

  /// 最后一次收到事件（通知 / 心跳）的时间，epoch 秒，0 表示从未。
  static final ValueNotifier<int> lastHeartbeat = ValueNotifier<int>(0);

  static final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  /// 服务实时推来的最新一条通知（通知页据此置顶，不必轮询）。
  static final ValueNotifier<NotificationItem?> incoming =
      ValueNotifier<NotificationItem?>(null);

  static bool get _android => !kIsWeb && Platform.isAndroid;

  /// App 启动 / 回到前台时，从服务侧存储恢复状态。
  static Future<void> syncFromService() async {
    if (!_android) return;
    unread.value =
        (await FlutterForegroundTask.getData<int>(key: kUnreadKey)) ?? 0;
    lastHeartbeat.value =
        (await FlutterForegroundTask.getData<int>(key: kHeartbeatKey)) ?? 0;
    running.value = await FlutterForegroundTask.isRunningService;
  }

  /// 接收服务 isolate 经 `sendDataToMain` 发来的事件。
  static void applyTaskData(Object data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);
    switch (map['type']) {
      case 'service_started':
        running.value = true;
        _applyHeartbeat(map);
      case 'service_stopped':
        running.value = false;
      case 'auth_required':
        running.value = false;
      case 'heartbeat':
        running.value = true;
        _applyHeartbeat(map);
      case 'notification':
        running.value = true;
        _applyHeartbeat(map);
        final item = map['item'];
        if (item is Map) {
          incoming.value =
              NotificationItem.fromJson(Map<String, dynamic>.from(item));
        }
    }
  }

  static void _applyHeartbeat(Map<String, dynamic> map) {
    final ts = map['ts'];
    if (ts is num && ts > 0) lastHeartbeat.value = ts.toInt();
    final n = map['unread'];
    if (n is num) unread.value = n.toInt() < 0 ? 0 : n.toInt();
  }

  /// 主 isolate 侧更新未读（标记已读 / 全部已读 / 拉取校正），并同步给服务。
  static Future<void> setUnread(int value) async {
    final next = value < 0 ? 0 : value;
    unread.value = next;
    if (!_android) return;
    await FlutterForegroundTask.saveData(key: kUnreadKey, value: next);
    FlutterForegroundTask.sendDataToTask({'type': 'set_unread', 'value': next});
  }
}
