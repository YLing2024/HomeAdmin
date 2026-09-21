import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'login_page.dart';
import 'notification_model.dart';
import 'notification_store.dart';
import 'theme.dart';

/// 通知 Tab：未读概览 + 列表（下拉刷新 / 翻页 / 标记已读 / 打开外链）。
///
/// 数据源：`GET /api/admin/notifications`（ts / readAt 均为 epoch 秒）。
/// 服务 isolate 通过 SSE 实时推送的新通知经 [NotificationStore.incoming] 置顶。
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, this.active = true});

  /// 是否为当前可见 Tab；由不可见变为可见时刷新一次。
  final bool active;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  static const int _pageSize = 50;

  final ScrollController _scroll = ScrollController();
  final List<NotificationItem> _items = [];

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _markingAll = false;
  String? _error;
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    NotificationStore.incoming.addListener(_onIncoming);
    _load();
  }

  @override
  void didUpdateWidget(covariant NotificationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其它 Tab 切回本页：静默刷新，保留列表避免闪烁
    if (widget.active && !oldWidget.active) _load(silent: _items.isNotEmpty);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    NotificationStore.incoming.removeListener(_onIncoming);
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  void _onIncoming() {
    final item = NotificationStore.incoming.value;
    if (item == null || !mounted) return;
    if (_items.any((x) => x.id == item.id)) return;
    setState(() {
      _items.insert(0, item);
      _unread += 1;
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await Api.notifications(limit: _pageSize);
      final list = _itemsOf(data);
      final unread = data['unread'];
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _unread = unread is num
            ? unread.toInt()
            : _items.where((x) => x.isUnread).length;
        _hasMore = list.length >= _pageSize;
        _loading = false;
        _error = null;
      });
      await NotificationStore.setUnread(_unread);
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final data = await Api.notifications(
        limit: _pageSize,
        before: _items.last.id,
      );
      final list = _itemsOf(data);
      if (!mounted) return;
      setState(() {
        for (final item in list) {
          if (_items.every((x) => x.id != item.id)) _items.add(item);
        }
        _hasMore = list.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) {
        setState(() => _loadingMore = false);
        showAppToast(context, '加载更多失败', ok: false);
      }
    }
  }

  List<NotificationItem> _itemsOf(Map<String, dynamic> data) {
    final raw = data['items'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((m) => NotificationItem.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> _open(NotificationItem item) async {
    if (item.isUnread) {
      final index = _items.indexWhere((x) => x.id == item.id);
      setState(() {
        if (index != -1) _items[index] = item.copyWith(readAt: _nowSeconds());
        if (_unread > 0) _unread -= 1;
      });
      await NotificationStore.setUnread(_unread);
      try {
        await Api.notificationRead(item.id);
      } catch (e) {
        if (!mounted) return;
        final handled = await handleAuthError(context, e);
        if (!handled && mounted) showAppToast(context, '标记已读失败', ok: false);
      }
    }
    final link = item.link;
    if (link != null && link.isNotEmpty) await _openLink(link);
  }

  Future<void> _readAll() async {
    if (_unread == 0 || _markingAll) return;
    setState(() => _markingAll = true);
    try {
      await Api.notificationReadAll();
      if (!mounted) return;
      final now = _nowSeconds();
      setState(() {
        for (var i = 0; i < _items.length; i++) {
          if (_items[i].isUnread) {
            _items[i] = _items[i].copyWith(readAt: now);
          }
        }
        _unread = 0;
        _markingAll = false;
      });
      await NotificationStore.setUnread(0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _markingAll = false);
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) showAppToast(context, '操作失败', ok: false);
    }
  }

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) showAppToast(context, '无法打开链接', ok: false);
    } catch (_) {
      if (mounted) showAppToast(context, '无法打开链接', ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: () => _load(silent: _items.isNotEmpty),
      child: Column(
        children: [
          _header(c),
          const Divider(height: 1),
          Expanded(child: _body(c)),
        ],
      ),
    );
  }

  Widget _header(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Text(
            '通知',
            style: TextStyle(
              color: c.fg,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 10),
          if (_unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: c.accentSoft,
                border: Border.all(color: c.accentBorder),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '未读 $_unread',
                style: TextStyle(color: c.accent, fontSize: 11),
              ),
            ),
          const Spacer(),
          TextButton(
            onPressed: (_unread == 0 || _markingAll) ? null : _readAll,
            child: Text(
              _markingAll ? '处理中…' : '全部已读',
              style: TextStyle(color: c.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(AppColors c) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [_errorBanner(c, _error!)],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          const SizedBox(height: 120),
          Text(
            '暂无通知',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.fg, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '新的系统通知会出现在这里。',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      );
    }
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _items.length + 1,
      itemBuilder: (_, i) {
        if (i == _items.length) return _footer(c);
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _itemTile(c, _items[i]),
        );
      },
    );
  }

  Widget _footer(AppColors c) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_hasMore) {
      return const SizedBox(height: 18);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Text(
        '没有更多了',
        textAlign: TextAlign.center,
        style: TextStyle(color: c.muted, fontSize: 12),
      ),
    );
  }

  Widget _itemTile(AppColors c, NotificationItem item) {
    final urgent = item.isUrgent;
    final body = item.body ?? '';
    return InkWell(
      onTap: () => _open(item),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: urgent ? c.accentBorder : c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: urgent ? c.accentBorder : c.border,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    _levelLabel(item.level),
                    style: TextStyle(
                      color: urgent ? c.accent : c.muted,
                      fontSize: 10,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.source,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatNotificationTime(item.ts),
                  style: TextStyle(color: c.muted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.isUnread)
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 7),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.accent,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    item.title.isEmpty ? '(无标题)' : item.title,
                    style: TextStyle(
                      color: c.fg,
                      fontSize: 13,
                      fontWeight:
                          item.isUnread ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (item.link != null && item.link!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 1),
                    child: Icon(Icons.open_in_new, size: 14, color: c.muted),
                  ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _levelLabel(String level) {
    switch (level) {
      case 'urgent':
        return '紧急';
      case 'digest':
        return '摘要';
      default:
        return '通知';
    }
  }

  Widget _errorBanner(AppColors c, String msg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: c.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(msg, style: TextStyle(color: c.danger, fontSize: 13)),
          ),
          TextButton(
            onPressed: () => _load(),
            child: Text(
              '重试',
              style: TextStyle(color: c.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
