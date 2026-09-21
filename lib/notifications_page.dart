import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'debug_tools.dart' show buildNotificationPayload;
import 'login_page.dart';
import 'notification_feed.dart';
import 'notification_model.dart';
import 'notification_push.dart';
import 'notification_store.dart';
import 'notification_type_filter.dart';
import 'push_wait_result.dart';
import 'theme.dart';

/// 通知页：发通知（页头内联表单）+ 列表 + 筛选 + 单条已读/删除 + 全部已读。
///
/// 数据源：`GET /api/admin/notifications`（ts / readAt 均为 epoch 秒）。
/// 服务器 SSE 实时推送的新通知经 [NotificationStore.incoming] 置顶。
///
/// 铁律：本页发出通知后**禁止乐观更新** —— 不本地插入、不刷未读，只显示
/// 「已提交到服务器，等待推送…」，以 [PushWaitResult] 呈现收到 / 超时。
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, this.active = true});

  /// 是否为当前可见 Tab；由不可见变为可见时刷新一次。
  final bool active;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  static const int _pageSize = 50;

  /// 发通知固定来源：后端 source 必填且不能为空，界面上不露出（先例与 Web 一致取 admin）。
  static const String _composeSource = 'admin';

  final ScrollController _scroll = ScrollController();
  final NotificationFeed _feed = NotificationFeed(pageSize: _pageSize);

  bool _loading = true;
  bool _loadingMore = false;
  bool _markingAll = false;
  String? _error;

  /* ===== 筛选 ===== */
  bool _unreadOnly = false;
  String _levelFilter = '';
  String _sourceFilter = '';

  /// 通知类别键（服务端定义），空串为「全部」；列表请求带 `type=<key>`。
  String _typeFilter = '';

  /// 服务端返回的类别（含停用，用于显示历史通知类别名）；接口失败时为空。
  List<NotificationType> _types = const [];
  final Set<String> _sources = {};

  /* ===== 发通知（页头内联表单） ===== */
  final PushWaitController _pushWait = PushWaitController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _bodyText = TextEditingController();
  final TextEditingController _link = TextEditingController();
  String _level = 'normal';
  bool _composeOpen = false;
  bool _sending = false;
  bool _repulled = false;
  String? _composeError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    NotificationStore.incoming.addListener(_onIncoming);
    NotificationStore.reloadTick.addListener(_onReloadRequest);
    _loadTypes();
    _load();
  }

  @override
  void didUpdateWidget(covariant NotificationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其它 Tab 切回本页：静默刷新，保留列表避免闪烁
    if (widget.active && !oldWidget.active) {
      _loadTypes();
      _load(silent: _feed.items.isNotEmpty);
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    NotificationStore.incoming.removeListener(_onIncoming);
    NotificationStore.reloadTick.removeListener(_onReloadRequest);
    _pushWait.dispose();
    _title.dispose();
    _bodyText.dispose();
    _link.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 服务器推送：唯一的新增入口（发送方不做本地插入）。
  void _onIncoming() {
    final item = NotificationStore.incoming.value;
    if (item == null || !mounted) return;
    _addSources([item]);
    // 对齐 Web：不匹配当前筛选的推送不插入列表（未读徽标仍由服务状态更新）。
    if (!_matchesFilter(item)) return;
    _feed.applyPush(item);
    setState(() {});
  }

  /// 调试页 / 其它发送方超时后请求「重新拉取列表」。
  void _onReloadRequest() {
    if (!mounted) return;
    _load(silent: _feed.items.isNotEmpty);
  }

  /// 拉取服务端定义的类别清单（进通知页 / 切回本页时）。
  ///
  /// 接口失败 → 类别置空、筛选回落「全部」，**不阻塞通知列表**（列表仍照常加载）。
  Future<void> _loadTypes() async {
    try {
      final types = await Api.notificationTypes();
      if (!mounted) return;
      setState(() {
        _types = types;
        // 选中的类别在新清单里不存在 / 已停用 → 回落「全部」
        final stillValid = types.any(
          (t) => t.key == _typeFilter && t.enabled,
        );
        if (!stillValid) _typeFilter = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _types = const [];
        _typeFilter = '';
      });
      await handleAuthError(context, e);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await Api.notifications(
        limit: _pageSize,
        unreadOnly: _unreadOnly,
        level: _levelFilter,
        source: _sourceFilter,
        type: _typeFilter,
      );
      final list = _itemsOf(data);
      final unread = data['unread'];
      if (!mounted) return;
      _addSources(list);
      setState(() {
        _feed.replaceAll(list, unread is num ? unread.toInt() : null);
        _loading = false;
        _error = null;
      });
      await NotificationStore.setUnread(_feed.unread);
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
    if (_loadingMore || _loading || !_feed.hasMore || _feed.items.isEmpty) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final data = await Api.notifications(
        limit: _pageSize,
        before: _feed.items.last.id,
        unreadOnly: _unreadOnly,
        level: _levelFilter,
        source: _sourceFilter,
        type: _typeFilter,
      );
      final list = _itemsOf(data);
      if (!mounted) return;
      setState(() {
        _feed.appendOlder(list);
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

  void _addSources(Iterable<NotificationItem> items) {
    for (final item in items) {
      if (item.source.isNotEmpty) _sources.add(item.source);
    }
  }

  bool _matchesFilter(NotificationItem item) {
    if (_unreadOnly && !item.isUnread) return false;
    if (_levelFilter.isNotEmpty && item.level != _levelFilter) return false;
    if (_sourceFilter.isNotEmpty && item.source != _sourceFilter) return false;
    if (_typeFilter.isNotEmpty && item.category != _typeFilter) return false;
    return true;
  }

  /* ============ 筛选切换 ============ */

  void _setUnreadOnly(bool value) {
    if (_unreadOnly == value) return;
    setState(() => _unreadOnly = value);
    _load();
  }

  void _setLevelFilter(String value) {
    if (_levelFilter == value) return;
    setState(() => _levelFilter = value);
    _load();
  }

  void _setSourceFilter(String value) {
    if (_sourceFilter == value) return;
    setState(() => _sourceFilter = value);
    _load();
  }

  void _setTypeFilter(String value) {
    if (_typeFilter == value) return;
    setState(() => _typeFilter = value);
    _load();
  }

  /* ============ 单条已读 / 打开链接 ============ */

  Future<void> _open(NotificationItem item) async {
    if (item.isUnread) {
      setState(() => _feed.markRead(item.id, _nowSeconds()));
      await NotificationStore.setUnread(_feed.unread);
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
    if (_feed.unread == 0 || _markingAll) return;
    setState(() => _markingAll = true);
    try {
      await Api.notificationReadAll();
      if (!mounted) return;
      setState(() {
        _feed.markAllRead(_nowSeconds());
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

  /* ============ 单条删除（二次确认） ============ */

  Future<void> _delete(NotificationItem item) async {
    final confirmed = await _confirm(title: '删除通知', message: '删除这条通知？删除后不可恢复。');
    if (!confirmed || !mounted) return;
    try {
      await Api.notificationDelete(item.id);
      if (!mounted) return;
      final removed = _feed.remove(item.id);
      if (removed != null) setState(() {});
      await NotificationStore.setUnread(_feed.unread);
      if (mounted) showAppToast(context, '已删除', ok: true);
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) showAppToast(context, '删除失败', ok: false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        title: Text(title, style: TextStyle(color: ctx.c.fg, fontSize: 16)),
        content: Text(message, style: TextStyle(color: ctx.c.fg, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              '取消',
              style: TextStyle(color: ctx.c.muted, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: ctx.c.danger, fontSize: 13),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
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

  /* ============ 发通知 ============ */

  Future<void> _sendNotification() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _composeError = '标题不能为空');
      return;
    }
    final payload = buildNotificationPayload(
      level: _level,
      title: title,
      source: _composeSource,
      body: _bodyText.text,
      link: _link.text,
    );
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _sending = true;
      _composeError = null;
      _repulled = false;
    });
    try {
      final r = await Api.createNotification(payload);
      if (!mounted) return;
      setState(() => _sending = false);
      if (!r.ok) {
        setState(() => _composeError = '发送失败：HTTP ${r.status}');
        return;
      }
      _title.clear();
      _bodyText.clear();
      _link.clear();
      // 铁律：禁止乐观更新。不插入列表、不刷未读，只等服务器 SSE 推送。
      _pushWait.begin(
        PushTarget(id: r.id, title: title, source: _composeSource),
        startedAtMillis: startedAt,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _composeError = e.toString();
      });
      await handleAuthError(context, e);
    }
  }

  /// 等待超时后的显式动作：重新拉取列表（用户主动触发，允许更新未读）。
  Future<void> _repull() async {
    setState(() => _repulled = true);
    await _load(silent: _feed.items.isNotEmpty);
  }

  /* ============ 布局 ============ */

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: () async {
        // 类别清单可能被后台新增/改名/停用，随下拉刷新一起重拉
        await _loadTypes();
        await _load(silent: _feed.items.isNotEmpty);
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _header(c)),
          if (_composeOpen) SliverToBoxAdapter(child: _composeSection(c)),
          SliverToBoxAdapter(child: const Divider(height: 1)),
          SliverToBoxAdapter(child: _filterBar(c)),
          SliverToBoxAdapter(child: const Divider(height: 1)),
          ..._bodySlivers(c),
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
          if (_feed.unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: c.accentSoft,
                border: Border.all(color: c.accentBorder),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '未读 ${_feed.unread}',
                style: TextStyle(color: c.accent, fontSize: 11),
              ),
            ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _composeOpen = !_composeOpen),
            child: Text(
              _composeOpen ? '收起' : '发通知',
              style: TextStyle(color: c.accent, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: (_feed.unread == 0 || _markingAll) ? null : _readAll,
            child: Text(
              _markingAll ? '处理中…' : '全部已读',
              style: TextStyle(color: c.accent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _segment(c, '全部', !_unreadOnly, () => _setUnreadOnly(false)),
          _segment(c, '未读', _unreadOnly, () => _setUnreadOnly(true)),
          NotificationTypeFilter(
            types: _types,
            value: _typeFilter,
            onChanged: _setTypeFilter,
          ),
          _dropdown(
            c,
            value: _levelFilter,
            items: [('', '全部级别'), ...kNotificationLevelOptions],
            onChanged: _setLevelFilter,
          ),
          _dropdown(
            c,
            width: 140,
            value: _sourceFilter,
            items: [('', '全部来源'), for (final s in _sources) (s, s)],
            onChanged: _setSourceFilter,
          ),
        ],
      ),
    );
  }

  List<Widget> _bodySlivers(AppColors c) {
    if (_loading && _feed.items.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ];
    }
    if (_error != null && _feed.items.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: _errorBanner(c, _error!),
          ),
        ),
      ];
    }
    if (_feed.items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _unreadOnly ||
                          _levelFilter.isNotEmpty ||
                          _sourceFilter.isNotEmpty ||
                          _typeFilter.isNotEmpty
                      ? '没有符合条件的通知'
                      : '暂无通知',
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
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        sliver: SliverList.builder(
          itemCount: _feed.items.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _itemTile(c, _feed.items[i]),
          ),
        ),
      ),
      SliverToBoxAdapter(child: _footer(c)),
    ];
  }

  Widget _footer(AppColors c) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_feed.hasMore) {
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: urgent ? c.accentBorder : c.border,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    notificationLevelLabel(item.level),
                    style: TextStyle(
                      color: urgent ? c.accent : c.muted,
                      fontSize: 10,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    notificationTypeLabel(item.category, _types),
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
                      fontWeight: item.isUnread
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (item.link != null && item.link!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 1),
                    child: Icon(Icons.open_in_new, size: 14, color: c.muted),
                  ),
                IconButton(
                  onPressed: () => _delete(item),
                  tooltip: '删除',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 24,
                  ),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline, size: 16, color: c.muted),
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

  /* ============ 发通知表单 ============ */

  Widget _composeSection(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldLabel(c, '级别'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _level,
            isExpanded: true,
            dropdownColor: c.surface,
            style: TextStyle(color: c.fg, fontSize: 13),
            decoration: _inputDecoration(c),
            items: [
              for (final (value, label) in kNotificationLevelOptions)
                DropdownMenuItem(value: value, child: Text(label)),
            ],
            onChanged: _sending
                ? null
                : (v) => setState(() => _level = v ?? 'normal'),
          ),
          const SizedBox(height: 12),
          _fieldLabel(c, '标题'),
          const SizedBox(height: 6),
          TextField(
            controller: _title,
            maxLength: 80,
            enabled: !_sending,
            style: TextStyle(color: c.fg, fontSize: 13),
            decoration: _inputDecoration(c).copyWith(
              counterText: '',
              hintText: '给你自己看的通知，≤ 80 字',
              hintStyle: TextStyle(color: c.muted, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          _fieldLabel(c, '正文（选填，纯文本）'),
          const SizedBox(height: 6),
          TextField(
            controller: _bodyText,
            maxLines: 3,
            enabled: !_sending,
            style: TextStyle(color: c.fg, fontSize: 13),
            decoration: _inputDecoration(c).copyWith(
              hintText: '可留空',
              hintStyle: TextStyle(color: c.muted, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          _fieldLabel(c, '链接（选填）'),
          const SizedBox(height: 6),
          TextField(
            controller: _link,
            enabled: !_sending,
            keyboardType: TextInputType.url,
            style: TextStyle(color: c.fg, fontSize: 13),
            decoration: _inputDecoration(c).copyWith(
              hintText: 'https://…',
              hintStyle: TextStyle(color: c.muted, fontSize: 13),
            ),
          ),
          if (_composeError != null) ...[
            const SizedBox(height: 10),
            _banner(c, _composeError!, ok: false),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _sending ? null : _sendNotification,
              child: Text(_sending ? '发送中…' : '发送'),
            ),
          ),
          ListenableBuilder(
            listenable: _pushWait,
            builder: (context, _) => PushWaitResult(
              state: _pushWait.state,
              onRepull: _repull,
              repulled: _repulled,
            ),
          ),
        ],
      ),
    );
  }

  Widget _segment(
    AppColors c,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.accentSoft : Colors.transparent,
          border: Border.all(color: selected ? c.accentBorder : c.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c.accent : c.muted,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _dropdown(
    AppColors c, {
    required String value,
    required List<(String, String)> items,
    required ValueChanged<String> onChanged,
    double width = 120,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: c.surface,
          style: TextStyle(color: c.fg, fontSize: 13),
          icon: Icon(Icons.arrow_drop_down, size: 18, color: c.muted),
          items: [
            for (final (v, label) in items)
              DropdownMenuItem(
                value: v,
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }

  Widget _banner(AppColors c, String msg, {required bool ok}) {
    final color = ok ? c.ok : c.danger;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Text(msg, style: TextStyle(color: color, fontSize: 13)),
    );
  }

  Widget _fieldLabel(AppColors c, String text) {
    return Text(
      text,
      style: TextStyle(
        color: c.muted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }

  InputDecoration _inputDecoration(AppColors c) {
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: c.surface2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(
        borderSide: BorderSide(color: c.border),
        borderRadius: BorderRadius.circular(4),
      ),
    );
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
            child: Text('重试', style: TextStyle(color: c.accent, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
