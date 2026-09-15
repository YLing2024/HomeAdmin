import 'image_refs.dart';

/* ============ 聊天消息模型与归一化 ============ */
// 浏览（历史会话）UI 已移除；此处保留消息解析模型，供后续聊天页复用。

class Session {
  final String id;
  final String title;
  final DateTime? time;
  final int messageCount;
  const Session(this.id, this.title, {this.time, this.messageCount = 0});
}

class FileRef {
  final String path;
  final String ext;
  final String name;
  FileRef(this.path, this.ext)
      : name = (() {
          final parts = path.split('/');
          return parts.isEmpty ? path : parts.last;
        })();
}

class ChatMessage {
  final String role; // user / assistant
  final String content;
  final List<String> images;
  final List<FileRef> files;
  final DateTime? ts;

  const ChatMessage({
    required this.role,
    required this.content,
    this.images = const [],
    this.files = const [],
    this.ts,
  });
}

/* ============ 字段归一化 ============ */

List<Session> toSessions(dynamic data) {
  final arr = _arrayOf(data, 'sessions');
  return arr.whereType<Map>().map((m) {
    final id = (m['id'] ?? m['session_id'] ?? m['sessionId'] ?? '').toString();
    final title = (m['title'] ?? m['name'] ?? id).toString();
    final raw = m['time'] ?? m['last_activity_at'] ?? m['started_at'] ?? m['ts'];
    final count = m['message_count'];
    return Session(
      id,
      title.isEmpty ? '会话' : title,
      time: _parseTs({'time': raw}),
      messageCount: count is num ? count.toInt() : 0,
    );
  }).toList();
}

List<ChatMessage> toMessages(dynamic data) {
  final arr = _arrayOf(data, 'messages');
  return arr.whereType<Map>().map((m) {
    final raw = Map<String, dynamic>.from(m);
    final content = _extractContent(raw);
    // 历史带图消息以文本引用 @image:/abs/path 落库：解析出路径并入 images
    final parsed = parseImageRefs(content);
    return ChatMessage(
      role: raw['role'] == 'assistant' ? 'assistant' : 'user',
      content: parsed.text,
      images: parsed.images,
      ts: _parseTs(raw),
    );
  }).where((m) => m.role == 'user' || m.role == 'assistant').toList();
}

List<dynamic> _arrayOf(dynamic data, String key) {
  if (data is List) return data;
  if (data is Map && data[key] is List) return data[key] as List;
  return const [];
}

String _extractContent(Map<String, dynamic> m) {
  final c = m['content'];
  if (c is String) return c;
  if (c is List) {
    return c
        .whereType<Map>()
        .map((p) {
          final text = p['text'];
          final content = p['content'];
          return text is String ? text : (content is String ? content : '');
        })
        .where((s) => s.isNotEmpty)
        .join('\n');
  }
  final t = m['text'];
  return t is String ? t : '';
}

DateTime? _parseTs(Map<String, dynamic> m) {
  final raw = m['created_at'] ??
      m['create_time'] ??
      m['timestamp'] ??
      m['time'] ??
      m['createdAt'] ??
      m['when'] ??
      m['ts'];
  if (raw == null || raw == '') return null;
  int? t;
  if (raw is num) {
    t = raw.toInt();
  } else if (raw is String && RegExp(r'^\d+$').hasMatch(raw)) {
    t = int.tryParse(raw);
  } else if (raw is String) {
    t = DateTime.tryParse(raw)?.millisecondsSinceEpoch;
  }
  if (t == null) return null;
  if (t < 1000000000000) t *= 1000; // 秒 -> 毫秒
  return DateTime.fromMillisecondsSinceEpoch(t);
}

/// 时间显示：同日 HH:MM，跨天 MM-DD HH:MM
String formatMessageTime(DateTime? ts) {
  if (ts == null) return '';
  final now = DateTime.now();
  final sameDay =
      ts.year == now.year && ts.month == now.month && ts.day == now.day;
  String p2(int n) => n.toString().padLeft(2, '0');
  final hm = '${p2(ts.hour)}:${p2(ts.minute)}';
  return sameDay ? hm : '${p2(ts.month)}-${p2(ts.day)} $hm';
}
