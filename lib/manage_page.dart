import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'login_page.dart';
import 'notification_model.dart';
import 'notification_service.dart';
import 'notification_store.dart';
import 'theme.dart';

/// 管理 Tab：设备会话管理 + 接口令牌管理（对齐 Web Manage.jsx）
class ManagePage extends StatefulWidget {
  const ManagePage({super.key});

  @override
  State<ManagePage> createState() => _ManagePageState();
}

class _ManagePageState extends State<ManagePage> {
  /* ===== 设备会话 ===== */
  List<Map<String, dynamic>> _sessions = [];
  bool _loadingSessions = true;
  String? _sessionsError;
  String? _editingId; // 正在重命名的会话 id
  final TextEditingController _editNameCtrl = TextEditingController();
  final FocusNode _editFocus = FocusNode();
  String? _editError;
  bool _editSaving = false;
  bool _renameInFlight = false;

  /* ===== 接口令牌 ===== */
  List<Map<String, dynamic>> _tokens = [];
  bool _loadingTokens = true;
  String? _tokensError;

  /* ===== 通知保活 ===== */
  bool _ignoringBattery = false;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _loadTokens();
    NotificationStore.syncFromService();
    _loadBatteryStatus();
  }

  @override
  void dispose() {
    _editNameCtrl.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  /* ============ 设备会话 ============ */

  Future<void> _loadSessions() async {
    setState(() {
      _loadingSessions = true;
      _sessionsError = null;
    });
    try {
      final list = await Api.sessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loadingSessions = false;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) {
        setState(() {
          _sessionsError = e.toString();
          _loadingSessions = false;
        });
      }
    }
  }

  void _startRename(Map<String, dynamic> s) {
    setState(() {
      _editingId = s['id'].toString();
      _editNameCtrl.text = (s['deviceName'] ?? '').toString();
      _editError = null;
    });
  }

  void _cancelRename() {
    setState(() {
      _editingId = null;
      _editNameCtrl.clear();
      _editError = null;
    });
  }

  Future<void> _saveRename(Map<String, dynamic> s) async {
    final name = _editNameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _editError = '设备名称不能为空');
      return;
    }
    if (name == (s['deviceName'] ?? '').toString()) {
      _cancelRename(); // 未改动：直接退出编辑态，不发请求
      return;
    }
    if (_renameInFlight) return; // 失焦与保存同帧触发时去重
    _renameInFlight = true;
    setState(() {
      _editSaving = true;
      _editError = null;
    });
    try {
      await Api.sessionRename(s['id'].toString(), name);
      if (!mounted) return;
      setState(() {
        _sessions = [
          for (final x in _sessions)
            if (x['id'].toString() == s['id'].toString())
              {...x, 'deviceName': name}
            else
              x,
        ];
      });
      _cancelRename();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _editError = e.toString());
    } finally {
      _renameInFlight = false;
      if (mounted) setState(() => _editSaving = false);
    }
  }

  void _askDeleteSession(Map<String, dynamic> s) {
    final isCurrent = s['isCurrent'] == true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        title: Text('删除设备', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '删除设备「${(s['deviceName'] ?? '').toString().isEmpty ? '未命名设备' : s['deviceName']}」并撤销其登录凭证？',
              style: TextStyle(color: ctx.c.fg, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              isCurrent
                  ? '该设备将立即退出，必须重新认证才能进入管理后台。'
                  : '该设备将立即失效，必须重新 TOTP 认证后才能进入管理后台。',
              style: TextStyle(color: ctx.c.muted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _confirmDeleteSession(s);
            },
            child: Text('删除', style: TextStyle(color: ctx.c.danger, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteSession(Map<String, dynamic> s) async {
    try {
      await Api.sessionDelete(s['id'].toString());
      if (!mounted) return;
      if (s['isCurrent'] == true) {
        // 删除当前设备：撤销自身凭证 → 立即退出登录
        await forceLogout();
        return;
      }
      setState(() {
        _sessions = _sessions.where((x) => x['id'].toString() != s['id'].toString()).toList();
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _sessionsError = e.toString());
    }
  }

  /* ============ 接口令牌 ============ */

  Future<void> _loadTokens() async {
    setState(() {
      _loadingTokens = true;
      _tokensError = null;
    });
    try {
      final list = await Api.apiTokens();
      if (!mounted) return;
      setState(() {
        _tokens = list;
        _loadingTokens = false;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) {
        setState(() {
          _tokensError = e.toString();
          _loadingTokens = false;
        });
      }
    }
  }

  /* ============ 通知保活 ============ */

  Future<void> _loadBatteryStatus() async {
    final ignoring = await NotificationService.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() => _ignoringBattery = ignoring);
  }

  Future<void> _restartNotificationService() async {
    final ok = await NotificationService.restart();
    if (!mounted) return;
    showAppToast(context, ok ? '通知服务已重启' : '通知服务启动失败', ok: ok);
  }

  Future<void> _requestBatteryOptimization() async {
    await NotificationService.requestIgnoreBatteryOptimization();
    await _loadBatteryStatus();
  }

  Future<void> _openCreate() async {
    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final customCtrl = TextEditingController();
    var days = '30';
    var creating = false;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> submit() async {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) {
              setDialogState(() => error = '令牌名称不能为空');
              return;
            }
            final raw = days == 'custom' ? customCtrl.text : days;
            final n = int.tryParse(raw.trim());
            if (n == null || n < 1 || n > 365) {
              setDialogState(() => error = '有效期需为 1~365 天的整数');
              return;
            }
            setDialogState(() {
              creating = true;
              error = null;
            });
            try {
              final data = await Api.apiTokenCreate(
                name: name,
                note: noteCtrl.text.trim(),
                expiresInDays: n,
              );
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              await _loadTokens();
              if (!mounted) return;
              await _showCreatedToken((data['token'] ?? '').toString());
            } catch (e) {
              if (!ctx.mounted) return;
              final handled = await handleAuthError(ctx, e);
              setDialogState(() {
                creating = false;
                error = handled ? null : e.toString();
              });
            }
          }

          return AlertDialog(
            backgroundColor: ctx.c.surface,
            title: Text('生成接口令牌', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _dialogField(
                    ctx,
                    label: '令牌名称',
                    controller: nameCtrl,
                    maxLength: 64,
                    hint: '如：行情脚本',
                  ),
                  const SizedBox(height: 12),
                  _dialogField(
                    ctx,
                    label: '备注（选填）',
                    controller: noteCtrl,
                    maxLength: 200,
                    hint: '用途说明',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '有效期',
                    style: TextStyle(
                      color: ctx.c.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: days,
                    isExpanded: true,
                    dropdownColor: ctx.c.surface,
                    style: TextStyle(color: ctx.c.fg, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: ctx.c.surface2,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: ctx.c.border),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: '7', child: Text('7 天')),
                      DropdownMenuItem(value: '30', child: Text('30 天')),
                      DropdownMenuItem(value: '90', child: Text('90 天')),
                      DropdownMenuItem(value: 'custom', child: Text('自定义天数')),
                    ],
                    onChanged: (v) => setDialogState(() => days = v ?? '30'),
                  ),
                  if (days == 'custom') ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: customCtrl,
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: ctx.c.fg, fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '1~365',
                        hintStyle: TextStyle(color: ctx.c.muted, fontSize: 13),
                        filled: true,
                        fillColor: ctx.c.surface2,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: ctx.c.border),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(color: ctx.c.danger, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: creating ? null : () => Navigator.of(ctx).pop(),
                child: Text('取消', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
              ),
              TextButton(
                onPressed: creating ? null : submit,
                child: Text(
                  creating ? '生成中…' : '生成',
                  style: TextStyle(color: ctx.c.accent, fontSize: 13),
                ),
              ),
            ],
          );
        },
      ),
    );
    nameCtrl.dispose();
    noteCtrl.dispose();
    customCtrl.dispose();
  }

  Future<void> _showCreatedToken(String token) async {
    var copied = false;
    final curl =
        'curl -H "Authorization: Bearer $token" $kApiBase/api/admin/system';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: ctx.c.surface,
          title: Text('接口令牌已生成', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '令牌仅显示一次，关闭后无法再次查看，请立即保存。',
                  style: TextStyle(color: ctx.c.muted, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ctx.c.bg,
                    border: Border.all(color: ctx.c.border),
                  ),
                  child: SelectableText(
                    token,
                    style: TextStyle(
                      color: ctx.c.fg,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: token));
                    if (!ctx.mounted) return;
                    setDialogState(() => copied = true);
                    Future.delayed(const Duration(milliseconds: 1500), () {
                      if (ctx.mounted) setDialogState(() => copied = false);
                    });
                  },
                  icon: Icon(copied ? Icons.check : Icons.copy, size: 16, color: ctx.c.accent),
                  label: Text(
                    copied ? '已复制' : '复制令牌',
                    style: TextStyle(color: ctx.c.accent, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'curl 用法示例',
                  style: TextStyle(
                    color: ctx.c.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ctx.c.bg,
                    border: Border.all(color: ctx.c.border),
                  ),
                  child: SelectableText(
                    curl,
                    style: TextStyle(
                      color: ctx.c.muted,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('关闭', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEdit(Map<String, dynamic> t) async {
    final nameCtrl = TextEditingController(text: (t['name'] ?? '').toString());
    final noteCtrl = TextEditingController(text: (t['note'] ?? '').toString());
    final daysCtrl = TextEditingController();
    var saving = false;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> submit() async {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) {
              setDialogState(() => error = '令牌名称不能为空');
              return;
            }
            final patch = <String, dynamic>{};
            if (name != (t['name'] ?? '').toString()) patch['name'] = name;
            if (noteCtrl.text.trim() != (t['note'] ?? '').toString()) {
              patch['note'] = noteCtrl.text.trim();
            }
            final daysRaw = daysCtrl.text.trim();
            if (daysRaw.isNotEmpty) {
              final n = int.tryParse(daysRaw);
              if (n == null || n < 1 || n > 365) {
                setDialogState(() => error = '有效期需为 1~365 天的整数');
                return;
              }
              patch['expiresInDays'] = n;
            }
            if (patch.isEmpty) {
              Navigator.of(ctx).pop(); // 无改动：直接关闭
              return;
            }
            setDialogState(() {
              saving = true;
              error = null;
            });
            try {
              await Api.apiTokenUpdate(t['id'].toString(), patch);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              await _loadTokens();
            } catch (e) {
              if (!ctx.mounted) return;
              final handled = await handleAuthError(ctx, e);
              setDialogState(() {
                saving = false;
                error = handled ? null : e.toString();
              });
            }
          }

          return AlertDialog(
            backgroundColor: ctx.c.surface,
            title: Text('编辑接口令牌', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _dialogField(ctx, label: '令牌名称', controller: nameCtrl, maxLength: 64),
                  const SizedBox(height: 12),
                  _dialogField(ctx, label: '备注（选填）', controller: noteCtrl, maxLength: 200, hint: '用途说明'),
                  const SizedBox(height: 12),
                  _dialogField(
                    ctx,
                    label: '重置有效期（选填）',
                    controller: daysCtrl,
                    hint: '留空则保持当前有效期',
                    number: true,
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(color: ctx.c.danger, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                child: Text('取消', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
              ),
              TextButton(
                onPressed: saving ? null : submit,
                child: Text(
                  saving ? '保存中…' : '保存',
                  style: TextStyle(color: ctx.c.accent, fontSize: 13),
                ),
              ),
            ],
          );
        },
      ),
    );
    nameCtrl.dispose();
    noteCtrl.dispose();
    daysCtrl.dispose();
  }

  void _askRevoke(Map<String, dynamic> t) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        title: Text('吊销接口令牌', style: TextStyle(color: ctx.c.fg, fontSize: 16)),
        content: Text(
          '吊销令牌「${t['name']}」？吊销后立即失效，使用该令牌的工具将无法再调用接口。',
          style: TextStyle(color: ctx.c.fg, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: ctx.c.muted, fontSize: 13)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await Api.apiTokenDelete(t['id'].toString());
                if (!mounted) return;
                setState(() {
                  _tokens = _tokens.where((x) => x['id'].toString() != t['id'].toString()).toList();
                });
              } catch (e) {
                if (!mounted) return;
                final handled = await handleAuthError(context, e);
                if (!handled && mounted) setState(() => _tokensError = e.toString());
              }
            },
            child: Text('吊销', style: TextStyle(color: ctx.c.danger, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _dialogField(
    BuildContext ctx, {
    required String label,
    required TextEditingController controller,
    int? maxLength,
    String? hint,
    bool number = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: ctx.c.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLength: maxLength,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          style: TextStyle(color: ctx.c.fg, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: hint,
            hintStyle: TextStyle(color: ctx.c.muted, fontSize: 13),
            filled: true,
            fillColor: ctx.c.surface2,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(
              borderSide: BorderSide(color: ctx.c.border),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ],
    );
  }

  /* ============ 格式化 ============ */

  static String _p2(int n) => n.toString().padLeft(2, '0');

  String _fmtTime(num? ms) {
    if (ms == null || ms == 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return '${d.year}-${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';
  }

  String _fmtDate(num? ms) {
    if (ms == null || ms == 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return '${d.year}-${_p2(d.month)}-${_p2(d.day)}';
  }

  String _relativeTime(num? ms) {
    if (ms == null || ms == 0) return '—';
    final diff = DateTime.now().millisecondsSinceEpoch - ms.toInt();
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 3600 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 86400 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }

  int _remainingDays(num? expiresAt) {
    if (expiresAt == null || expiresAt == 0) return 0;
    final diff = expiresAt.toInt() - DateTime.now().millisecondsSinceEpoch;
    return diff <= 0 ? 0 : diff ~/ 86400000;
  }

  /* ============ 布局 ============ */

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: () async {
        await Future.wait([
          _loadSessions(),
          _loadTokens(),
          NotificationStore.syncFromService(),
        ]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Spacer(),
              Text(
                '管理',
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
          _keepAliveSection(c),
          const SizedBox(height: 28),
          Container(height: 1, color: c.border),
          const SizedBox(height: 28),
          _buildSectionHeader(
            c,
            title: '设备管理',
            action: TextButton.icon(
              onPressed: _loadingSessions ? null : _loadSessions,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(_loadingSessions ? '刷新中…' : '刷新'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '删除设备会撤销其登录凭证，该设备必须重新认证才能进入管理后台。',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (_sessionsError != null) _errorBanner(c, _sessionsError!),
          if (_loadingSessions)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_sessions.isEmpty)
            _emptyBanner(c, '暂无已登录设备')
          else
            _sessionTable(c),
          const SizedBox(height: 28),
          Container(height: 1, color: c.border),
          const SizedBox(height: 28),
          _buildSectionHeader(
            c,
            title: '接口令牌',
            action: TextButton.icon(
              onPressed: _openCreate,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('生成令牌'),
            ),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              style: TextStyle(color: c.muted, fontSize: 12),
              children: [
                const TextSpan(text: '接口令牌用于第三方工具调用 Admin 接口。调用时在请求头携带 '),
                TextSpan(
                  text: 'Authorization: Bearer <令牌>',
                  style: TextStyle(
                    color: c.accent,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                const TextSpan(
                  text: ' 即可。令牌与登录设备相互独立，不占用设备登录。请妥善保管令牌，泄露可随时吊销。',
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_tokensError != null) _errorBanner(c, _tokensError!),
          if (_loadingTokens)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_tokens.isEmpty)
            _emptyBanner(c, '暂无接口令牌')
          else
            _tokenTable(c),
        ],
      ),
    );
  }

  /* ============ 区块组件 ============ */

  Widget _buildSectionHeader(AppColors c, {required String title, required Widget action}) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            color: c.fg,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const Spacer(),
        action,
      ],
    );
  }

  /// 通知保活状态卡：诚实展示服务状态与补救手段（对齐需求「管理页保活状态卡」）
  Widget _keepAliveSection(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          c,
          title: '通知保活',
          action: TextButton.icon(
            onPressed: _restartNotificationService,
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('重启通知服务'),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '保持与服务器的通知长连接，收到新通知时以系统通知提醒。',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Container(
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
                builder: (context, unread, _) => Column(
                  children: [
                    _statusRow(
                      c,
                      '服务状态',
                      running ? '运行中' : '未运行',
                      dot: running,
                    ),
                    _statusRow(
                      c,
                      '最后心跳',
                      heartbeat > 0
                          ? formatNotificationTime(heartbeat)
                          : '从未',
                    ),
                    _statusRow(c, '未读通知', '$unread'),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _ignoringBattery ? null : _requestBatteryOptimization,
          icon: Icon(
            _ignoringBattery ? Icons.check : Icons.battery_saver,
            size: 16,
          ),
          label: Text(_ignoringBattery ? '已忽略电池优化' : '申请忽略电池优化'),
        ),
        const SizedBox(height: 8),
        Text(
          '若厂商系统仍自动结束后台，请在系统设置中允许本应用自启动与后台运行。',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _statusRow(AppColors c, String label, String value, {bool? dot}) {
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
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dot ? c.ok : c.danger,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(value, style: TextStyle(color: c.fg, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _errorBanner(AppColors c, String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            child: Text(
              msg,
              style: TextStyle(color: c.danger, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyBanner(AppColors c, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Text(text, style: TextStyle(color: c.muted, fontSize: 13)),
    );
  }

  /* ============ 设备会话表格 ============ */

  Widget _sessionTable(AppColors c) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 640;
        if (wide) {
          return Container(
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                _tableHeader(c, ['设备', '设备 IP', '登录时间', '最近活跃', '凭证过期', '操作']),
                for (final s in _sessions) _sessionRow(c, s, wide),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (final s in _sessions) ...[
              _sessionRow(c, s, wide),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }

  Widget _tableHeader(AppColors c, List<String> cols) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          for (final (i, label) in cols.indexed)
            Expanded(
              flex: i == cols.length - 1 ? 1 : 2,
              child: Text(
                label,
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: TextStyle(
                  color: c.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sessionRow(AppColors c, Map<String, dynamic> s, bool wide) {
    final id = s['id'].toString();
    final editing = _editingId == id;
    final expiresAt =
        (s['expiresAt'] is num) ? (s['expiresAt'] as num).toInt() * 1000 : null;

    final deviceCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editing)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _editNameCtrl,
                focusNode: _editFocus,
                maxLength: 64,
                enabled: !_editSaving,
                autofocus: true,
                style: TextStyle(color: c.fg, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  hintText: '设备名称',
                  hintStyle: TextStyle(color: c.muted, fontSize: 13),
                  filled: true,
                  fillColor: c.surface2,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: c.accentBorder),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: c.accentBorder),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: c.accent),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                onSubmitted: (_) => _saveRename(s),
                onTapOutside: (_) {
                  // 失焦自动保存（对齐 Web 编辑态：无「取消」，失焦即保存）
                  _saveRename(s);
                },
              ),
              if (_editError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _editError!,
                    style: TextStyle(color: c.danger, fontSize: 11),
                  ),
                ),
            ],
          )
        else
          Row(
            children: [
              Flexible(
                child: Text(
                  (s['deviceName'] ?? '').toString().isEmpty
                      ? '未命名设备'
                      : (s['deviceName'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _startRename(s),
                borderRadius: BorderRadius.circular(3),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.edit_outlined, size: 13, color: c.muted),
                ),
              ),
              if (s['isCurrent'] == true) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.accentBorder),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '当前设备',
                    style: TextStyle(color: c.accent, fontSize: 10),
                  ),
                ),
              ],
            ],
          ),
        if ((s['userAgent'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              (s['userAgent'] ?? '').toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ),
      ],
    );

    if (wide) {
      final cells = [
        deviceCol,
        Text(
          (s['ip'] ?? '').toString().isEmpty ? '—' : (s['ip'] ?? '').toString(),
          textAlign: TextAlign.right,
          style: TextStyle(
            color: c.fg,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
        Text(
          _fmtTime(s['createdAt'] is num ? (s['createdAt'] as num) : null),
          textAlign: TextAlign.right,
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        Text(
          _relativeTime(s['lastSeenAt'] is num ? (s['lastSeenAt'] as num) : null),
          textAlign: TextAlign.right,
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        Text(
          _fmtTime(expiresAt),
          textAlign: TextAlign.right,
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        editing
            ? TextButton(
                onPressed: _editSaving ? null : () => _saveRename(s),
                child: Text(
                  _editSaving ? '保存中…' : '保存',
                  style: TextStyle(color: c.accent, fontSize: 12),
                ),
              )
            : TextButton(
                onPressed: () => _askDeleteSession(s),
                child: Text('删除', style: TextStyle(color: c.danger, fontSize: 12)),
              ),
      ];
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
        ),
        child: Row(
          children: [
            for (final (i, cell) in cells.indexed)
              Expanded(
                flex: i == cells.length - 1 ? 1 : 2,
                child: i == 0 ? cell : Align(alignment: Alignment.centerRight, child: cell),
              ),
          ],
        ),
      );
    }

    // 窄屏卡片式布局
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          deviceCol,
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _kvLine(c, 'IP', (s['ip'] ?? '—').toString()),
              ),
              Expanded(
                child: _kvLine(
                  c,
                  '登录',
                  _fmtTime(s['createdAt'] is num ? (s['createdAt'] as num) : null),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _kvLine(
                  c,
                  '活跃',
                  _relativeTime(s['lastSeenAt'] is num ? (s['lastSeenAt'] as num) : null),
                ),
              ),
              Expanded(
                child: _kvLine(c, '过期', _fmtTime(expiresAt)),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: editing
                ? TextButton(
                    onPressed: _editSaving ? null : () => _saveRename(s),
                    child: Text(
                      _editSaving ? '保存中…' : '保存',
                      style: TextStyle(color: c.accent, fontSize: 12),
                    ),
                  )
                : TextButton(
                    onPressed: () => _askDeleteSession(s),
                    child: Text('删除', style: TextStyle(color: c.danger, fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _kvLine(AppColors c, String label, String value) {
    return RichText(
      text: TextSpan(
        style: TextStyle(color: c.muted, fontSize: 12),
        children: [
          TextSpan(text: '$label '),
          TextSpan(
            text: value,
            style: TextStyle(color: c.fg, fontSize: 12),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /* ============ 接口令牌表格 ============ */

  Widget _tokenTable(AppColors c) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 640;
        if (wide) {
          return Container(
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                _tableHeader(c, ['名称', '备注', '创建时间', '过期时间', '最近使用', '操作']),
                for (final t in _tokens) _tokenRow(c, t, wide),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (final t in _tokens) ...[
              _tokenRow(c, t, wide),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }

  Widget _tokenRow(AppColors c, Map<String, dynamic> t, bool wide) {
    final expiresAt = t['expiresAt'] is num ? (t['expiresAt'] as num).toInt() : null;
    final expired = expiresAt != null &&
        expiresAt > 0 &&
        expiresAt <= DateTime.now().millisecondsSinceEpoch;
    final lastUsed = t['lastUsedAt'] is num ? (t['lastUsedAt'] as num).toInt() : null;

    final nameCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (t['name'] ?? '').toString(),
          style: TextStyle(
            color: c.fg,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        if ((t['note'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              (t['note'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ),
      ],
    );

    final expiryCol = expired
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: c.danger),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '已过期',
              style: TextStyle(color: c.danger, fontSize: 10),
            ),
          )
        : Text(
            '${_fmtDate(expiresAt?.toDouble())} · 剩余 ${_remainingDays(expiresAt?.toDouble())} 天',
            textAlign: TextAlign.right,
            style: TextStyle(color: c.fg, fontSize: 12),
          );

    final lastUsedCol = lastUsed == null || lastUsed == 0
        ? Text('从未使用', style: TextStyle(color: c.muted, fontSize: 12))
        : Text(
            _fmtTime(lastUsed.toDouble()),
            textAlign: TextAlign.right,
            style: TextStyle(color: c.muted, fontSize: 12),
          );

    final opsCol = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () => _openEdit(t),
          child: Text('编辑', style: TextStyle(color: c.accent, fontSize: 12)),
        ),
        TextButton(
          onPressed: () => _askRevoke(t),
          child: Text('吊销', style: TextStyle(color: c.danger, fontSize: 12)),
        ),
      ],
    );

    if (wide) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(flex: 2, child: nameCol),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  (t['note'] ?? '').toString().isEmpty ? '—' : (t['note'] ?? '').toString(),
                  textAlign: TextAlign.right,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _fmtDate(t['createdAt'] is num ? (t['createdAt'] as num) : null),
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(alignment: Alignment.centerRight, child: expiryCol),
            ),
            Expanded(
              flex: 1,
              child: Align(alignment: Alignment.centerRight, child: lastUsedCol),
            ),
            Expanded(
              flex: 1,
              child: Align(alignment: Alignment.centerRight, child: opsCol),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          nameCol,
          const SizedBox(height: 8),
          _kvLine(
            c,
            '创建',
            _fmtDate(t['createdAt'] is num ? (t['createdAt'] as num) : null),
          ),
          const SizedBox(height: 4),
          _kvLine(
            c,
            '过期',
            expired
                ? '已过期'
                : '${_fmtDate(expiresAt?.toDouble())} · 剩余 ${_remainingDays(expiresAt?.toDouble())} 天',
          ),
          const SizedBox(height: 4),
          _kvLine(
            c,
            '使用',
            lastUsed == null || lastUsed == 0 ? '从未使用' : _fmtTime(lastUsed.toDouble()),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: opsCol,
          ),
        ],
      ),
    );
  }
}
