/// 通知管理页的纯逻辑（可单测，不依赖 UI / 网络）。
library;

/// 通知级别选项（value 与后端 NOTIFICATION_LEVELS 一一对应）。
const List<(String, String)> kNotificationLevelOptions = [
  ('urgent', '紧急'),
  ('normal', '常规'),
  ('digest', '汇总'),
];

/// 级别中文名（未知级别回退「通知」）。
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

/// 批量删除请求体：只带非空筛选；[dryRun] 供二次确认前取准确条数。
/// 与后端 `POST /api/admin/notifications/bulk-delete` 契约一致。
Map<String, dynamic> bulkDeleteBody({
  String? level,
  String? source,
  bool unreadOnly = false,
  bool readOnly = false,
  bool dryRun = false,
}) {
  final body = <String, dynamic>{};
  final lv = level?.trim() ?? '';
  final src = source?.trim() ?? '';
  if (lv.isNotEmpty) body['level'] = lv;
  if (src.isNotEmpty) body['source'] = src;
  if (unreadOnly) body['unreadOnly'] = true;
  if (readOnly) body['readOnly'] = true;
  if (dryRun) body['dryRun'] = true;
  return body;
}

/// 批量删除范围描述（用于二次确认文案），如「（级别 紧急 · 来源 admin · 仅未读）」；
/// 无筛选返回空串（即「全部」）。
String describeBulkScope({
  String? level,
  String? source,
  bool unreadOnly = false,
  bool readOnly = false,
}) {
  final parts = <String>[];
  final lv = level?.trim() ?? '';
  final src = source?.trim() ?? '';
  if (lv.isNotEmpty) {
    parts.add('级别 ${notificationLevelLabel(lv)}');
  }
  if (src.isNotEmpty) parts.add('来源 $src');
  if (unreadOnly) parts.add('仅未读');
  if (readOnly) parts.add('仅已读');
  return parts.isEmpty ? '' : '（${parts.join(' · ')}）';
}

/// 统计行文案：「共 N 条 · 未读 M · 来源 K 个」。
String notificationStatsLine({
  required int total,
  required int unread,
  required int sourceCount,
}) {
  return '共 $total 条 · 未读 $unread · 来源 $sourceCount 个';
}

/// 来源 Top N：后端已按条数降序返回，这里只做截断与类型收敛。
List<Map<String, dynamic>> topNotificationSources(
  List<dynamic> sources, {
  int max = 5,
}) {
  final out = <Map<String, dynamic>>[];
  for (final raw in sources) {
    if (raw is! Map) continue;
    final m = Map<String, dynamic>.from(raw);
    final name = (m['source'] ?? '').toString();
    if (name.isEmpty) continue;
    final value = m['count'];
    final int count;
    if (value is num) {
      count = value.toInt();
    } else if (value is String) {
      count = int.tryParse(value) ?? 0;
    } else {
      count = 0;
    }
    out.add({'source': name, 'count': count});
    if (out.length >= max) break;
  }
  return out;
}
