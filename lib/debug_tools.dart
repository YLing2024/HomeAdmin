import 'dart:convert';

import 'api.dart';
import 'notification_model.dart';

/// 「调试」页 · 通知调试工具的纯逻辑（可单测，不依赖 UI）。

/// 调试页发测试通知时固定的来源标识（对齐 Web 端 NotificationDebug.jsx）
const String kDebugNotificationSource = 'admin-debug';

/// 调用结果响应体截断长度（与 Web 端调试页一致）
const int kDebugResponseTruncate = 600;

/// 通知级别选项（value 与后端 NOTIFICATION_LEVELS 一一对应）
class DebugNotificationLevel {
  const DebugNotificationLevel(this.value, this.label);

  final String value;
  final String label;
}

const List<DebugNotificationLevel> kDebugNotificationLevels = [
  DebugNotificationLevel('urgent', '紧急'),
  DebugNotificationLevel('normal', '常规'),
  DebugNotificationLevel('digest', '汇总'),
];

/// 构建 `POST /api/admin/notifications` 请求体：
/// level / source / title 必填；body / link / dedupKey 为空时不下发
/// （后端把空字符串视为 null，这里省去无意义字段）。
Map<String, dynamic> buildNotificationPayload({
  required String level,
  required String title,
  String source = kDebugNotificationSource,
  String? body,
  String? link,
  String? dedupKey,
}) {
  final payload = <String, dynamic>{
    'level': level,
    'source': source,
    'title': title.trim(),
  };
  void put(String key, String? value) {
    final v = value?.trim() ?? '';
    if (v.isNotEmpty) payload[key] = v;
  }

  put('body', body);
  put('link', link);
  put('dedupKey', dedupKey);
  return payload;
}

/// 接口说明里的 JSON 请求体示例（可直接复制；不含真实域名）。
String notificationExampleJson() {
  return const JsonEncoder.withIndent('  ').convert(
    buildNotificationPayload(
      level: 'normal',
      title: '测试通知',
      body: '来自 Admin 调试',
    ),
  );
}

/// 接口地址：用编译期注入的 [kApiBase] 拼出，不硬编码私有地址。
String notificationEndpoint() => '$kApiBase/api/admin/notifications';

/// SSE 连接状态文案，复用 notification_service 已有状态推导（不另起连接）：
/// - 前台服务未运行 → 未启动；
/// - 运行中且最近心跳未超时（< [kNotificationHeartbeatTimeoutSeconds]）→ 已连接；
/// - 运行中但心跳超时或从未收到 → 重连中。
String notificationConnectionLabel({
  required bool running,
  required int lastHeartbeatEpochSeconds,
  required int nowEpochSeconds,
}) {
  if (!running) return '未启动';
  if (lastHeartbeatEpochSeconds > 0 &&
      !notificationHeartbeatExpired(
        lastHeartbeatEpochSeconds,
        nowEpochSeconds,
      )) {
    return '已连接';
  }
  return '重连中';
}

/// 响应体截断（与 Web 端调试页一致，最长 [max] 字符）。
String truncateDebugText(String text, {int max = kDebugResponseTruncate}) {
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…';
}
