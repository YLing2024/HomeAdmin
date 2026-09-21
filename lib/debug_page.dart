import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'debug_tools.dart';
import 'login_page.dart';
import 'notification_model.dart';
import 'notification_push.dart';
import 'notification_store.dart';
import 'push_wait_result.dart';
import 'theme.dart';

/// 调试页：工具容器（工具列表 + 工具面板）。
///
/// 当前只有一项工具「通知调试」；其余留空，不造占位工具（对齐 Web 端 Debug.jsx）。
class DebugPage extends StatefulWidget {
  const DebugPage({super.key, this.active = true});

  /// 是否为当前可见 Tab；仅可见时刷新状态并驱动相对时间重绘。
  final bool active;

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  static const List<String> _tools = ['通知调试'];
  int _tool = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              const Spacer(),
              Text(
                '调试',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              for (var i = 0; i < _tools.length; i++)
                _ToolChip(
                  label: _tools[i],
                  selected: i == _tool,
                  onTap: () => setState(() => _tool = i),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(
            index: _tool,
            children: [
              NotificationDebugPanel(active: widget.active),
            ],
          ),
        ),
      ],
    );
  }
}

/// 工具选择项（当前只有一项，横向排列以便窄屏）
class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
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
}

/// 通知调试面板：实时状态 / 发测试通知 / 接口说明 / 调用结果。
///
/// 实时状态**复用** [NotificationStore]（notification_service.dart 的同源状态），
/// 不另起 SSE 连接；未读数以服务端 `GET /api/admin/notifications` 下拉刷新校正。
class NotificationDebugPanel extends StatefulWidget {
  const NotificationDebugPanel({super.key, this.active = true});

  final bool active;

  @override
  State<NotificationDebugPanel> createState() =>
      _NotificationDebugPanelState();
}

class _NotificationDebugPanelState extends State<NotificationDebugPanel> {
  final TextEditingController _title = TextEditingController(text: '测试通知');
  final TextEditingController _body = TextEditingController(text: '来自 Admin 调试');

  String _level = 'normal';
  bool _sending = false;
  bool _copied = false;
  bool _repulled = false;
  _CallResult? _result;
  Timer? _ticker;
  final PushWaitController _pushWait = PushWaitController();

  @override
  void initState() {
    super.initState();
    _syncTicker();
    if (widget.active) unawaited(_sync());
  }

  @override
  void didUpdateWidget(covariant NotificationDebugPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) unawaited(_sync());
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pushWait.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// 仅在可见时每秒重绘，让「x 秒前」等相对时间保持准确
  void _syncTicker() {
    if (widget.active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!widget.active) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 恢复服务状态 + 向服务端校正未读数（下拉刷新 / Tab 切入）
  Future<void> _sync() async {
    await NotificationStore.syncFromService();
    await _refreshUnread();
  }

  Future<void> _refreshUnread() async {
    try {
      final data = await Api.notifications(limit: 1);
      final unread = data['unread'];
      if (unread is num) await NotificationStore.setUnread(unread.toInt());
    } catch (e) {
      // 实时状态以服务推送为准，校正失败不打断页面；401 仍走全局登出
      if (!mounted) return;
      await handleAuthError(context, e);
    }
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() {
        _result = _CallResult(status: 0, body: '标题不能为空', at: _now());
      });
      return;
    }
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _sending = true;
      _repulled = false;
    });
    final payload = buildNotificationPayload(
      level: _level,
      title: title,
      body: _body.text,
    );
    try {
      final r = await Api.createNotification(payload);
      if (!mounted) return;
      setState(() {
        _sending = false;
        _result = _CallResult(status: r.status, body: r.body, at: _now());
      });
      if (r.ok) {
        // 铁律：禁止乐观更新。只清空表单并等待服务器 SSE 推送，
        // 列表与未读徽标都不在此处本地 +1（那是连通性检测的对象）。
        _title.clear();
        _body.clear();
        _pushWait.begin(
          PushTarget(id: r.id, title: title, source: kDebugNotificationSource),
          startedAtMillis: startedAt,
        );
      } else {
        showAppToast(context, '发送失败：HTTP ${r.status}', ok: false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _result = _CallResult(status: 0, body: e.toString(), at: _now());
      });
      showAppToast(context, '发送失败', ok: false);
    }
  }

  /// 等待超时后的显式动作：重新拉取列表（用户主动触发，允许更新徽标）。
  Future<void> _repull() async {
    setState(() => _repulled = true);
    NotificationStore.requestReload();
    await _refreshUnread();
  }

  Future<void> _copyExample() async {
    try {
      await Clipboard.setData(ClipboardData(text: notificationExampleJson()));
      if (!mounted) return;
      setState(() => _copied = true);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      // 复制失败静默降级：示例为可选中文本，可长按手动复制
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: _sync,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _blockTitle(c, '实时状态'),
          const SizedBox(height: 10),
          _statusCard(c),
          const SizedBox(height: 26),
          Container(height: 1, color: c.border),
          const SizedBox(height: 26),
          _blockTitle(c, '发一条测试通知'),
          const SizedBox(height: 10),
          _sendForm(c),
          ListenableBuilder(
            listenable: _pushWait,
            builder: (context, _) => PushWaitResult(
              state: _pushWait.state,
              onRepull: _repull,
              repulled: _repulled,
            ),
          ),
          const SizedBox(height: 26),
          Container(height: 1, color: c.border),
          const SizedBox(height: 26),
          _apiSection(c),
          const SizedBox(height: 26),
          Container(height: 1, color: c.border),
          const SizedBox(height: 26),
          _blockTitle(c, '调用结果'),
          const SizedBox(height: 10),
          _resultSection(c),
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

  /* ============ 1) 实时状态 ============ */

  Widget _statusCard(AppColors c) {
    final now = _now();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: NotificationStore.running,
        builder: (context, running, _) => ValueListenableBuilder<int>(
          valueListenable: NotificationStore.lastHeartbeat,
          builder: (context, heartbeat, _) => ValueListenableBuilder<int>(
            valueListenable: NotificationStore.unread,
            builder: (context, unread, _) {
              final conn = notificationConnectionLabel(
                running: running,
                lastHeartbeatEpochSeconds: heartbeat,
                nowEpochSeconds: now,
              );
              final connColor = conn == '已连接'
                  ? c.ok
                  : (conn == '重连中' ? c.warn : c.danger);
              return Column(
                children: [
                  _statusRow(
                    c,
                    '前台服务',
                    running ? '运行中' : '未运行',
                    dot: running ? c.ok : c.danger,
                  ),
                  _statusRow(c, 'SSE 连接', conn, dot: connColor),
                  _statusRow(
                    c,
                    '最近事件/心跳',
                    formatNotificationTime(heartbeat),
                  ),
                  _statusRow(c, '未读通知', '$unread'),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _statusRow(AppColors c, String label, String value, {Color? dot}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: c.muted, fontSize: 12)),
          const Spacer(),
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
            ),
            const SizedBox(width: 6),
          ],
          Text(value, style: TextStyle(color: c.fg, fontSize: 12)),
        ],
      ),
    );
  }

  /* ============ 2) 发一条测试通知 ============ */

  Widget _sendForm(AppColors c) {
    return Column(
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
            for (final l in kDebugNotificationLevels)
              DropdownMenuItem(value: l.value, child: Text(l.label)),
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
            hintText: '标题，≤ 80 字',
            hintStyle: TextStyle(color: c.muted, fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        _fieldLabel(c, '正文'),
        const SizedBox(height: 6),
        TextField(
          controller: _body,
          maxLines: 3,
          enabled: !_sending,
          style: TextStyle(color: c.fg, fontSize: 13),
          decoration: _inputDecoration(c).copyWith(
            hintText: '纯文本，可留空',
            hintStyle: TextStyle(color: c.muted, fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '来源固定为 $kDebugNotificationSource',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _sending ? null : _send,
            child: Text(_sending ? '发送中…' : '发送测试通知'),
          ),
        ),
      ],
    );
  }

  /* ============ 3) 接口说明 ============ */

  Widget _apiSection(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _blockTitle(c, '接口说明'),
            const Spacer(),
            TextButton.icon(
              onPressed: _copyExample,
              icon: Icon(
                _copied ? Icons.check : Icons.copy,
                size: 16,
                color: c.accent,
              ),
              label: Text(
                _copied ? '已复制' : '复制',
                style: TextStyle(color: c.accent, fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _codeBox(
          c,
          'POST ${notificationEndpoint()}',
          color: c.accent,
        ),
        const SizedBox(height: 12),
        _fieldTable(c),
        const SizedBox(height: 14),
        _fieldLabel(c, '请求体示例'),
        const SizedBox(height: 6),
        _codeBox(c, notificationExampleJson(), color: c.fg),
        const SizedBox(height: 8),
        Text(
          '鉴权：登录会话，或可在「管理」页生成的可写接口令牌。',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
      ],
    );
  }

  static const List<(String, String, String)> _fields = [
    ('level', '是', 'urgent / normal / digest'),
    ('source', '是', '来源标识，调试固定 $kDebugNotificationSource'),
    ('title', '是', '标题，≤ 80 字'),
    ('body', '否', '正文，纯文本'),
    ('link', '否', '跳转链接'),
    ('dedupKey', '否', '去重键，10 分钟内相同键只保留一条'),
  ];

  Widget _fieldTable(AppColors c) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: c.border)),
      child: Column(
        children: [
          for (final (i, f) in _fields.indexed) ...[
            if (i > 0) Container(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(
                      f.$1,
                      style: TextStyle(
                        color: c.accent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 30,
                    child: Text(
                      f.$2,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      f.$3,
                      style: TextStyle(color: c.fg, fontSize: 12, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /* ============ 4) 调用结果 ============ */

  Widget _resultSection(AppColors c) {
    final r = _result;
    if (r == null) {
      return Text('尚无调用', style: TextStyle(color: c.muted, fontSize: 13));
    }
    final ok = r.status >= 200 && r.status < 300;
    final statusText = r.status > 0 ? 'HTTP ${r.status}' : 'HTTP —';
    final body = r.body.isEmpty ? '(空响应体)' : r.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              ok ? '成功' : '失败',
              style: TextStyle(
                color: ok ? c.ok : c.danger,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              statusText,
              style: TextStyle(
                color: c.fg,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
            const Spacer(),
            Text(
              formatNotificationTime(r.at),
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _codeBox(c, truncateDebugText(body), color: c.fg),
      ],
    );
  }

  /* ============ 小组件 ============ */

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

  Widget _codeBox(AppColors c, String text, {required Color color}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.codeBg,
        border: Border.all(color: c.border),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontFamily: 'monospace',
          height: 1.5,
        ),
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

/// 最近一次调用的结果（本页发出的测试通知）
class _CallResult {
  const _CallResult({required this.status, required this.body, required this.at});

  /// HTTP 状态码；0 表示未发出请求（如本地校验失败）
  final int status;
  final String body;

  /// 发生时间（epoch 秒）
  final int at;
}
