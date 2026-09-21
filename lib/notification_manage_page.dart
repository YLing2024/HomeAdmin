import 'package:flutter/material.dart';

import 'api.dart';
import 'debug_tools.dart' show buildNotificationPayload;
import 'login_page.dart';
import 'notification_manage.dart';
import 'notification_push.dart';
import 'notification_store.dart';
import 'push_wait_result.dart';
import 'theme.dart';

/// 通知管理页（管理面）：发通知 / 批量删除 / 清空已读 / 统计。
///
/// 与「通知」展示页分离：展示页只读，本页做写入与批量动作。
/// - 发通知铁律：POST 成功后不本地插入、不重拉列表、不刷统计，只等服务器 SSE
///   推送到达（[PushWaitResult] 显示耗时/超时，用于连通性检测）。
/// - 统计只随推送更新；批量删除 / 清空已读属于本地用户动作，就地刷新。
/// - 状态源与通知页 / 调试页统一走 [NotificationStore]（服务状态与推送）。
class NotificationManagePage extends StatefulWidget {
  const NotificationManagePage({super.key, this.active = true});

  /// 是否为当前可见 Tab；切回本页时刷新一次统计。
  final bool active;

  @override
  State<NotificationManagePage> createState() => _NotificationManagePageState();
}

class _NotificationManagePageState extends State<NotificationManagePage> {
  final PushWaitController _pushWait = PushWaitController();
  final TextEditingController _source = TextEditingController(text: 'admin');
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _link = TextEditingController();
  final TextEditingController _dedup = TextEditingController();

  String _level = 'normal';
  bool _showAdvanced = false;
  bool _sending = false;
  bool _repulled = false;
  String? _error;
  String? _notice;

  /* ===== 统计 ===== */
  int _total = 0;
  int _unread = 0;
  List<Map<String, dynamic>> _sources = [];
  bool _showSources = false;

  /* ===== 批量筛选 ===== */
  bool _mUnread = false;
  String _mLevel = '';
  String _mSource = '';
  bool _bulkBusy = false;

  @override
  void initState() {
    super.initState();
    NotificationStore.incoming.addListener(_onPush);
    if (widget.active) _loadStats();
  }

  @override
  void didUpdateWidget(covariant NotificationManagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 组件常驻挂载：切回本页时刷新统计，避免看到过期数字。
    if (widget.active && !oldWidget.active) _loadStats();
  }

  @override
  void dispose() {
    NotificationStore.incoming.removeListener(_onPush);
    _pushWait.dispose();
    _source.dispose();
    _title.dispose();
    _body.dispose();
    _link.dispose();
    _dedup.dispose();
    super.dispose();
  }

  /// 统计只随服务器推送更新（发送方自己不刷，避免掩盖断链）。
  void _onPush() {
    if (!mounted) return;
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final data = await Api.notificationStats();
      if (!mounted) return;
      final total = data['total'];
      final unread = data['unread'];
      final sources = data['sources'];
      final parsed = topNotificationSources(sources is List ? sources : const []);
      setState(() {
        _total = total is num ? total.toInt() : 0;
        _unread = unread is num ? unread.toInt() : 0;
        _sources = parsed;
        // 已选来源若在最新统计里消失，重置为「全部来源」，避免下拉值不在选项内。
        if (_mSource.isNotEmpty &&
            !parsed.any((s) => s['source'] == _mSource)) {
          _mSource = '';
        }
      });
    } catch (e) {
      if (!mounted) return;
      await handleAuthError(context, e);
    }
  }

  /* ============ 发通知 ============ */

  Future<void> _send() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() {
        _error = '标题不能为空';
        _notice = null;
      });
      return;
    }
    final source = _source.text.trim().isEmpty ? 'admin' : _source.text.trim();
    final payload = buildNotificationPayload(
      level: _level,
      title: title,
      source: source,
      body: _body.text,
      link: _link.text,
      dedupKey: _dedup.text,
    );
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _sending = true;
      _error = null;
      _notice = null;
      _repulled = false;
    });
    try {
      final r = await Api.createNotification(payload);
      if (!mounted) return;
      setState(() => _sending = false);
      if (!r.ok) {
        setState(() => _error = '发送失败：HTTP ${r.status}');
        return;
      }
      _title.clear();
      _body.clear();
      _link.clear();
      _dedup.clear();
      _source.text = 'admin';
      setState(() => _showAdvanced = false);
      // 铁律：禁止乐观更新。不插入列表、不刷未读/统计，只等服务器 SSE 推送。
      _pushWait.begin(
        PushTarget(id: r.id, title: title, source: source),
        startedAtMillis: startedAt,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.toString();
      });
      await handleAuthError(context, e);
    }
  }

  /// 等待超时后的显式动作：重新拉取列表与统计。
  Future<void> _repull() async {
    setState(() => _repulled = true);
    NotificationStore.requestReload();
    await _loadStats();
  }

  /* ============ 批量操作 ============ */

  Future<void> _bulkDelete() async {
    if (_bulkBusy) return;
    setState(() {
      _bulkBusy = true;
      _error = null;
      _notice = null;
    });
    try {
      final dry = await Api.notificationBulkDelete(
        level: _mLevel,
        source: _mSource,
        unreadOnly: _mUnread,
        dryRun: true,
      );
      if (!mounted) return;
      if (dry == 0) {
        setState(() {
          _bulkBusy = false;
          _error = '当前条件下没有可删除的通知';
        });
        return;
      }
      final scope = describeBulkScope(
        level: _mLevel,
        source: _mSource,
        unreadOnly: _mUnread,
      );
      final prefix = scope.isEmpty ? '全部' : '当前筛选$scope';
      final confirmed = await _confirm(
        title: '批量删除',
        message: '将删除$prefix共 $dry 条通知，删除后不可恢复。确定继续？',
      );
      if (!confirmed) {
        if (mounted) setState(() => _bulkBusy = false);
        return;
      }
      final count = await Api.notificationBulkDelete(
        level: _mLevel,
        source: _mSource,
        unreadOnly: _mUnread,
      );
      if (!mounted) return;
      setState(() {
        _bulkBusy = false;
        _notice = '已删除 $count 条通知';
      });
      await _loadStats();
      NotificationStore.requestReload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bulkBusy = false;
        _error = e.toString();
      });
      await handleAuthError(context, e);
    }
  }

  Future<void> _clearRead() async {
    if (_bulkBusy) return;
    setState(() {
      _bulkBusy = true;
      _error = null;
      _notice = null;
    });
    try {
      final dry = await Api.notificationBulkDelete(
        readOnly: true,
        dryRun: true,
      );
      if (!mounted) return;
      if (dry == 0) {
        setState(() {
          _bulkBusy = false;
          _error = '没有已读通知';
        });
        return;
      }
      final confirmed = await _confirm(
        title: '清空已读',
        message: '将清空全部已读通知，共 $dry 条，删除后不可恢复。确定继续？',
      );
      if (!confirmed) {
        if (mounted) setState(() => _bulkBusy = false);
        return;
      }
      final count = await Api.notificationBulkDelete(readOnly: true);
      if (!mounted) return;
      setState(() {
        _bulkBusy = false;
        _notice = '已清空 $count 条已读通知';
      });
      await _loadStats();
      NotificationStore.requestReload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bulkBusy = false;
        _error = e.toString();
      });
      await handleAuthError(context, e);
    }
  }

  /// 二次确认；返回用户是否确认。
  Future<bool> _confirm({required String title, required String message}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        title: Text(title, style: TextStyle(color: ctx.c.fg, fontSize: 16)),
        content: Text(message, style: TextStyle(color: ctx.c.fg, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确定', style: TextStyle(color: ctx.c.danger, fontSize: 13)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /* ============ 布局 ============ */

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: _loadStats,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Spacer(),
              Text(
                '通知管理',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 12),
          _statsSection(c),
          const SizedBox(height: 26),
          Container(height: 1, color: c.border),
          const SizedBox(height: 26),
          _blockTitle(c, '发通知'),
          const SizedBox(height: 10),
          _composeForm(c),
          ListenableBuilder(
            listenable: _pushWait,
            builder: (context, _) => PushWaitResult(
              state: _pushWait.state,
              onRepull: _repull,
              repulled: _repulled,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '去重键：同一去重键 10 分钟内只保留一条，重复提交会更新原通知内容并重新置为未读。',
            style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 26),
          Container(height: 1, color: c.border),
          const SizedBox(height: 26),
          _blockTitle(c, '批量操作'),
          const SizedBox(height: 6),
          Text(
            '按下方筛选范围批量删除；清空已读会删除全部已读通知。两者都需二次确认。',
            style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 10),
          _bulkSection(c),
          if (_notice != null) ...[
            const SizedBox(height: 10),
            _banner(c, _notice!, ok: true),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            _banner(c, _error!, ok: false),
          ],
        ],
      ),
    );
  }

  Widget _blockTitle(AppColors c, String text) {
    return Text(
      text,
      style: TextStyle(
        color: c.fg,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    );
  }

  /* ============ 统计 ============ */

  Widget _statsSection(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showSources = !_showSources),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(
                  notificationStatsLine(
                    total: _total,
                    unread: _unread,
                    sourceCount: _sources.length,
                  ),
                  style: TextStyle(color: c.accent, fontSize: 13),
                ),
                const SizedBox(width: 4),
                Icon(
                  _showSources ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: c.muted,
                ),
              ],
            ),
          ),
        ),
        if (_showSources) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(border: Border.all(color: c.border)),
            child: Column(
              children: [
                if (_sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '暂无来源',
                        style: TextStyle(color: c.muted, fontSize: 12),
                      ),
                    ),
                  )
                else
                  for (final (i, s) in _sources.indexed) ...[
                    if (i > 0) Container(height: 1, color: c.border),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              s['source'].toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.fg, fontSize: 12),
                            ),
                          ),
                          Text(
                            s['count'].toString(),
                            style: TextStyle(
                              color: c.muted,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /* ============ 发通知表单 ============ */

  Widget _composeForm(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
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
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel(c, '来源'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _source,
                    maxLength: 40,
                    enabled: !_sending,
                    style: TextStyle(color: c.fg, fontSize: 13),
                    decoration: _inputDecoration(c).copyWith(
                      counterText: '',
                      hintText: 'admin',
                      hintStyle: TextStyle(color: c.muted, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
          controller: _body,
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
        const SizedBox(height: 6),
        TextButton(
          onPressed: _sending
              ? null
              : () => setState(() => _showAdvanced = !_showAdvanced),
          child: Text(
            _showAdvanced ? '收起高级' : '高级（去重键）',
            style: TextStyle(color: c.accent, fontSize: 13),
          ),
        ),
        if (_showAdvanced) ...[
          const SizedBox(height: 6),
          _fieldLabel(c, '去重键（选填）'),
          const SizedBox(height: 6),
          TextField(
            controller: _dedup,
            maxLength: 200,
            enabled: !_sending,
            style: TextStyle(color: c.fg, fontSize: 13),
            decoration: _inputDecoration(c).copyWith(
              counterText: '',
              hintText: '10 分钟内相同去重键只保留一条',
              hintStyle: TextStyle(color: c.muted, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _sending ? null : _send,
            child: Text(_sending ? '发送中…' : '发送'),
          ),
        ),
      ],
    );
  }

  /* ============ 批量操作 ============ */

  Widget _bulkSection(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _segment(c, '全部', !_mUnread, () => setState(() => _mUnread = false)),
            const SizedBox(width: 8),
            _segment(c, '仅未读', _mUnread, () => setState(() => _mUnread = true)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _mLevel,
                isExpanded: true,
                dropdownColor: c.surface,
                style: TextStyle(color: c.fg, fontSize: 13),
                decoration: _inputDecoration(c),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部级别')),
                  for (final (value, label) in kNotificationLevelOptions)
                    DropdownMenuItem(value: value, child: Text(label)),
                ],
                onChanged: _bulkBusy
                    ? null
                    : (v) => setState(() => _mLevel = v ?? ''),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('m-source-$_mSource'),
                initialValue: _mSource,
                isExpanded: true,
                dropdownColor: c.surface,
                style: TextStyle(color: c.fg, fontSize: 13),
                decoration: _inputDecoration(c),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部来源')),
                  for (final s in _sources)
                    DropdownMenuItem(
                      value: s['source'].toString(),
                      child: Text(
                        s['source'].toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _bulkBusy
                    ? null
                    : (v) => setState(() => _mSource = v ?? ''),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _bulkBusy ? null : _clearRead,
                child: Text(_bulkBusy ? '处理中…' : '清空已读'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _bulkBusy ? null : _bulkDelete,
                child: Text(
                  _bulkBusy ? '处理中…' : '批量删除',
                  style: TextStyle(color: c.danger),
                ),
              ),
            ),
          ],
        ),
      ],
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

  /* ============ 小组件 ============ */

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
}
