import 'dart:convert';

/// 通知级别（与 admin-server 契约一致，字段名/取值不要改）
const String kNotificationLevelUrgent = 'urgent';

/// 通知级别选项（value 与后端 NOTIFICATION_LEVELS 一一对应），发通知表单使用。
const List<(String, String)> kNotificationLevelOptions = [
  ('urgent', '紧急'),
  ('normal', '常规'),
  ('digest', '汇总'),
];

/// 级别中文名（未知级别回退「通知」），列表与筛选共用。
String notificationLevelLabel(String level) {
  switch (level) {
    case 'urgent':
      return '紧急';
    case 'digest':
      return '汇总';
    case 'normal':
      return '常规';
    default:
      return '通知';
  }
}

/// 通知类别（type）：**由服务端定义**，字段与
/// `GET /api/admin/notifications/types` 的 item 一一对应。
///
/// 铁律：客户端不得内置任何类别清单——本类只是服务端返回值的载体，
/// 筛选器与展示名都从这里来；服务端新增类别无需发版即可出现。
class NotificationType {
  const NotificationType({
    required this.key,
    required this.label,
    this.description,
    this.defaultLevel,
    this.sort = 0,
    this.enabled = true,
    this.count,
    this.unread,
  });

  /// 稳定标识，写入与筛选都用它（如 watchdog / monitor）。
  final String key;

  /// 展示名（服务端可改，如「看门狗」）；空则回退 [key]。
  final String label;
  final String? description;
  final String? defaultLevel;
  final int sort;

  /// 停用后不出现在筛选器里（历史数据仍在）。
  final bool enabled;

  /// 当前库内统计（仅供参考，可能缺省）。
  final int? count;
  final int? unread;

  /// 展示名：服务端 label 优先，取不到回退原始 key。
  String get displayLabel => label.isNotEmpty ? label : key;

  factory NotificationType.fromJson(Map<String, dynamic> json) {
    return NotificationType(
      key: (json['key'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      description: _asNonEmptyString(json['description']),
      defaultLevel: _asNonEmptyString(json['defaultLevel']),
      sort: _asInt(json['sort']) ?? 0,
      enabled: _asBool(json['enabled'], fallback: true),
      count: _asInt(json['count']),
      unread: _asInt(json['unread']),
    );
  }
}

/// 筛选下拉选项（仅 enabled 的类别）：`[('', '全部类别'), ...(key, label)]`。
///
/// 类别清单完全来自 [types]；接口失败时传空列表即降级为只剩「全部类别」，
/// 不阻塞通知列表加载。
List<(String, String)> notificationTypeFilterOptions(
  List<NotificationType> types,
) {
  final options = <(String, String)>[('', '全部类别')];
  for (final t in types) {
    if (t.key.isEmpty || !t.enabled) continue;
    options.add((t.key, t.displayLabel));
  }
  return options;
}

/// 显示某条通知的类别名：用服务端给的 label，取不到才回退原始 key。
///
/// 注意这里在**全量** [types] 里查（含 enabled=false）：停用类别不再出现在
/// 筛选器里，但历史通知仍要能显示它的名字。
String notificationTypeLabel(String key, List<NotificationType> types) {
  if (key.isEmpty) return '';
  for (final t in types) {
    if (t.key == key && t.label.isNotEmpty) return t.label;
  }
  return key;
}

/// 通知条目，字段与 `GET /api/admin/notifications` 的 item 一一对应。
///
/// 重要：后端 `ts` 与 `readAt` 均为 **epoch 秒**（admin-server `notificationView`），
/// 与系统指标 metrics 口径一致；展示前不要当作毫秒。
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.ts,
    required this.level,
    required this.source,
    required this.title,
    this.type = '',
    this.body,
    this.link,
    this.readAt,
  });

  final int id;
  final int ts;
  final String level;
  final String source;
  final String title;

  /// 通知类别键（服务端 `type`）。老数据 / 缺省时为空，用 [category] 回退。
  final String type;
  final String? body;
  final String? link;
  final int? readAt;

  bool get isUrgent => level == kNotificationLevelUrgent;
  bool get isUnread => readAt == null;

  /// 类别键：优先用服务端 `type`；缺省时按服务端写入规则回退 `source`
  /// （未传 type 的写入方以 source 作为类别键）。
  String get category => type.isNotEmpty ? type : source;

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      id: _asInt(json['id']) ?? 0,
      ts: _asInt(json['ts']) ?? 0,
      level: (json['level'] ?? 'normal').toString(),
      source: (json['source'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      body: _asNonEmptyString(json['body']),
      link: _asNonEmptyString(json['link']),
      readAt: _asInt(json['readAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': ts,
        'level': level,
        'source': source,
        'title': title,
        'type': type,
        'body': body,
        'link': link,
        'readAt': readAt,
      };

  NotificationItem copyWith({int? readAt}) => NotificationItem(
        id: id,
        ts: ts,
        level: level,
        source: source,
        title: title,
        type: type,
        body: body,
        link: link,
        readAt: readAt ?? this.readAt,
      );
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _asNonEmptyString(Object? value) {
  final s = value?.toString();
  if (s == null || s.isEmpty) return null;
  return s;
}

/// 兼容服务端 `enabled` 的多种表示：bool / 0-1 / 'true' / '1'。
bool _asBool(Object? value, {required bool fallback}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final s = value.toString().trim().toLowerCase();
  if (s.isEmpty) return fallback;
  return s == 'true' || s == '1' || s == 'yes';
}

/// 单条 SSE 帧（event + data），不含注释与 retry 行。
class SseFrame {
  const SseFrame(this.event, this.data);

  final String event;
  final String data;

  /// data 解析为 JSON 对象；失败返回 null（不抛）。
  Map<String, dynamic>? get json {
    try {
      final decoded = jsonDecode(data);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}

/// 增量式 SSE 解析器：按空行分帧，兼容 `\n\n` 与 `\r\n\r\n`，
/// 忽略无 `event:` 的帧（如服务端启动时的 `retry: 5000`）与注释行。
/// 纯函数式，可在单测中喂任意分块边界。
class SseParser {
  String _buffer = '';

  List<SseFrame> feed(String chunk) {
    final text = (_buffer + chunk).replaceAll('\r\n', '\n');
    final frames = <SseFrame>[];
    var start = 0;
    while (true) {
      final idx = text.indexOf('\n\n', start);
      if (idx == -1) break;
      final raw = text.substring(start, idx);
      start = idx + 2;
      final frame = parseFrame(raw);
      if (frame != null) frames.add(frame);
    }
    _buffer = text.substring(start);
    return frames;
  }

  /// 解析单个帧文本；无 event 或空 data 返回 null。
  static SseFrame? parseFrame(String raw) {
    String? event;
    final dataLines = <String>[];
    for (final line in raw.split('\n')) {
      if (line.startsWith(':')) continue; // 注释
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (event == null || event.isEmpty || dataLines.isEmpty) return null;
    return SseFrame(event, dataLines.join('\n'));
  }
}

/// 断线重连退避：调用方从 [kNotificationInitialBackoff] 起步，
/// 每次失败后取下一个（1s → 2s → 4s … 上限 60s）。
const Duration kNotificationInitialBackoff = Duration(seconds: 1);
const int kNotificationMaxBackoffSeconds = 60;

Duration nextNotificationBackoff(Duration current) {
  final seconds = current.inSeconds <= 0 ? 1 : current.inSeconds;
  final doubled = seconds * 2;
  final capped = doubled > kNotificationMaxBackoffSeconds
      ? kNotificationMaxBackoffSeconds
      : doubled;
  return Duration(seconds: capped);
}

/// 超过 90 秒未收到任何事件（含心跳）即认为连接已死，主动重连。
const int kNotificationHeartbeatTimeoutSeconds = 90;

bool notificationHeartbeatExpired(int lastEventEpochSeconds, int nowEpochSeconds) {
  if (lastEventEpochSeconds <= 0) return true;
  return nowEpochSeconds - lastEventEpochSeconds >=
      kNotificationHeartbeatTimeoutSeconds;
}

/// 本地通知需要正数 id：把后端自增 id 收敛到 int31。
int notificationLocalId(int id) => id & 0x7fffffff;

/// 相对时间（输入为 epoch 秒）。文案克制，无 emoji。
String formatNotificationTime(int? epochSeconds, {DateTime? now}) {
  if (epochSeconds == null || epochSeconds <= 0) return '—';
  final current = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final diff = current - epochSeconds;
  if (diff < 5) return '刚刚';
  if (diff < 60) return '$diff 秒前';
  if (diff < 3600) return '${diff ~/ 60} 分钟前';
  if (diff < 86400) return '${diff ~/ 3600} 小时前';
  if (diff < 86400 * 30) return '${diff ~/ 86400} 天前';
  final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  return '${d.year}-${_p2(d.month)}-${_p2(d.day)}';
}

String _p2(int n) => n.toString().padLeft(2, '0');
