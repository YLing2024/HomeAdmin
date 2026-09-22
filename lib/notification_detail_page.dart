import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'notification_model.dart';
import 'theme.dart';

/// 详情页正文 Text 的 Key，供 widget 测试定位「全文无截断」。
const Key kNotificationDetailBodyKey = Key('notification-detail-body');

/// 详情页操作结果，push 方据此更新列表。
enum NotificationDetailAction { markedRead, deleted }

/// 通知详情页：列表点条目 `Navigator.push` 进入，顶部返回。
///
/// - 正文完整显示（保留换行、页面可滚动），不做截断；正文 / 链接可复制。
/// - 元信息：类别（服务端 label）/ 级别 / 来源 / 完整时间 `YYYY-MM-DD HH:mm:ss` /
///   link（点击经 `url_launcher` 打开）。
/// - 页内操作：「标记已读」「删除（二次确认）」，成功后 `Navigator.pop(action)`
///   返回列表并由调用方更新（见 [NotificationDetailAction]）。
///
/// 铁律：本页不直接发请求——[onMarkRead] / [onDelete] 由列表页注入，
/// 便于复用既有 `Api` 调用与未读同步，也让本页可脱离网络单测。
class NotificationDetailPage extends StatefulWidget {
  const NotificationDetailPage({
    super.key,
    required this.item,
    required this.onMarkRead,
    required this.onDelete,
    this.types = const [],
    this.onOpenLink,
  });

  final NotificationItem item;

  /// 服务端类别清单，用于把 category key 显示为 label；接口失败时可为空。
  final List<NotificationType> types;

  /// 标记已读：返回 true 表示服务端成功，页面随即返回列表。
  final Future<bool> Function(NotificationItem item) onMarkRead;

  /// 删除：返回 true 表示服务端成功，页面随即返回列表。
  final Future<bool> Function(NotificationItem item) onDelete;

  /// 打开链接；缺省用 `url_launcher` 外部打开（测试可注入）。
  final Future<bool> Function(String url)? onOpenLink;

  @override
  State<NotificationDetailPage> createState() => _NotificationDetailPageState();
}

class _NotificationDetailPageState extends State<NotificationDetailPage> {
  bool _busy = false;

  Future<void> _markRead() async {
    if (_busy || !widget.item.isUnread) return;
    setState(() => _busy = true);
    final ok = await widget.onMarkRead(widget.item);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(NotificationDetailAction.markedRead);
      return;
    }
    setState(() => _busy = false);
    showAppToast(context, '标记已读失败', ok: false);
  }

  Future<void> _delete() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        title: Text('删除通知', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
        content: Text(
          '删除这条通知？删除后不可恢复。',
          style: TextStyle(color: ctx.c.fg, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: ctx.c.danger, fontSize: 13)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await widget.onDelete(widget.item);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(NotificationDetailAction.deleted);
      return;
    }
    setState(() => _busy = false);
    showAppToast(context, '删除失败', ok: false);
  }

  Future<void> _openLink() async {
    final url = widget.item.link;
    if (url == null || url.isEmpty) return;
    final open = widget.onOpenLink ?? _launchExternal;
    final ok = await open(url);
    if (mounted && !ok) showAppToast(context, '无法打开链接', ok: false);
  }

  static Future<bool> _launchExternal(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showAppToast(context, '$label已复制', ok: true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final item = widget.item;
    final category = notificationTypeLabel(item.category, widget.types);
    final body = item.body ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('通知详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
        children: [
          Row(
            children: [
              _badge(
                c,
                notificationLevelLabel(item.level),
                urgent: item.isUrgent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  category.isEmpty ? '未分类' : category,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ),
              if (item.isUnread)
                Text(
                  '未读',
                  style: TextStyle(color: c.accent, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            item.title.isEmpty ? '(无标题)' : item.title,
            style: TextStyle(
              color: c.fg,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          _meta(c, '级别', notificationLevelLabel(item.level)),
          _meta(c, '类别', category.isEmpty ? '—' : category),
          _meta(c, '来源', item.source.isEmpty ? '—' : item.source),
          _meta(c, '时间', formatNotificationFullTime(item.ts)),
          if (item.link != null && item.link!.isNotEmpty) _linkRow(c, item.link!),
          const Divider(height: 28),
          Row(
            children: [
              Text(
                '正文',
                style: TextStyle(
                  color: c.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              if (body.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _copy(body, '正文'),
                  icon: Icon(Icons.copy, size: 14, color: c.muted),
                  label: Text(
                    '复制',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (body.isEmpty)
            Text('（无正文）', style: TextStyle(color: c.muted, fontSize: 13))
          else
            Text(
              body,
              key: kNotificationDetailBodyKey,
              style: TextStyle(color: c.fg, fontSize: 14, height: 1.6),
            ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: item.isUnread && !_busy ? _markRead : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(_busy ? '处理中…' : (item.isUnread ? '标记已读' : '已读')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _delete,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    foregroundColor: c.danger,
                    side: BorderSide(color: c.border),
                  ),
                  child: const Text('删除'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(AppColors c, String text, {bool urgent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: urgent ? c.accentSoft : null,
        border: Border.all(color: urgent ? c.accentBorder : c.border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(color: urgent ? c.accent : c.muted, fontSize: 11),
      ),
    );
  }

  Widget _meta(AppColors c, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: c.fg, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkRow(AppColors c, String link) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text('链接', style: TextStyle(color: c.muted, fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(link, style: TextStyle(color: c.fg, fontSize: 13)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _openLink,
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('打开链接'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => _copy(link, '链接'),
                      icon: Icon(Icons.copy, size: 14, color: c.muted),
                      label: Text(
                        '复制',
                        style: TextStyle(color: c.muted, fontSize: 12),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
