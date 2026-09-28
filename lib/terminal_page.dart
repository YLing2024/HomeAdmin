import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api.dart';
import 'theme.dart';

/// 服务器终端（对齐 Web Terminal.jsx）：
/// - ttyd 内嵌 WebView；会话名 + 12h 票据按 `--url-arg` 顺序传给服务端 wrapper，
///   wrapper 用 tmux `new-session -A -s <名字>` 接回已有会话或新建；
/// - 多标签（类似浏览器标签页）：标签条 + 存活圆点 + 关闭/新建/锁定/重连；
/// - 二次验证：口令换取票据（仅内存保存，App 重启即失效，需重新验证）；
/// - 关闭标签结束对应会话；锁定批量结束全部会话并清空票据；
/// - 会话存活状态 6s 轮询（与 Web 相同），Tab 未激活时不轮询。
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, this.active = true});

  /// 是否处于可见 Tab：轮询仅在激活时进行（对齐 Web），WebView 常驻保留滚动历史
  final bool active;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// 终端标签（id 即 tmux 会话名，服务端白名单 ^term-[a-z0-9][a-z0-9-]{0,31}$）
class _TermTab {
  _TermTab(this.id, this.title);

  final String id;
  final String title;

  Map<String, dynamic> toJson() => {'id': id, 'title': title};

  static _TermTab? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final title = raw['title'];
    return _TermTab(id, (title is String && title.isNotEmpty) ? title : '终端');
  }
}

const _kStoreKey = 'admin_term_tabs'; // 与 Web localStorage 同键名
const _kPollMs = 6000;
const _kTermBg = Color(0xFF13110F); // 终端底色，消除加载瞬间白闪（对齐 Web .term-frame）

class _TerminalPageState extends State<TerminalPage> {
  static final math.Random _rand = math.Random();

  final List<_TermTab> _tabs = [];
  final Set<String> _alive = {};
  final Map<String, WebViewController> _webviews = {};
  final Map<String, String> _builtTicket = {};
  final Map<String, int> _builtNonce = {};

  final TextEditingController _pwCtrl = TextEditingController();
  final FocusNode _pwFocus = FocusNode();

  String? _current;
  String _ticket = ''; // 仅内存：Web 用 sessionStorage，App 重启即失效需重新验证
  String _pw = '';
  String _err = '';
  bool _busy = false;
  bool _inited = false;
  bool _loaded = false;
  int _nonce = 0; // 「重连」自增，令所有 WebView 重建加载
  bool _polling = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant TerminalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _init();
      _syncPolling(); // 首次初始化之后再次激活：恢复轮询（_init 有 _inited 早退）
      _focusGate();
    } else if (!widget.active && oldWidget.active) {
      _stopPolling();
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _pwCtrl.dispose();
    _pwFocus.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadTabs();
    if (!mounted) return;
    if (widget.active) _init();
  }

  /// 首次激活时初始化：无标签则建一个默认标签（对齐 Web inited + 首个「终端 1」）
  void _init() {
    if (_inited || !_loaded) return; // 本地标签读取完成前不建默认标签，避免重复
    _inited = true;
    if (_tabs.isEmpty) {
      final t = _newTab();
      setState(() {
        _tabs.add(t);
        _current = t.id;
      });
      _saveTabs();
    }
    _syncPolling();
    _focusGate();
  }

  /// 激活且未解锁时聚焦口令输入（避免 IndexedStack 隐藏时 autofocus 弹键盘）
  void _focusGate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && _ticket.isEmpty) _pwFocus.requestFocus();
    });
  }

  /* ============ 本地标签持久化 ============ */

  Future<void> _loadTabs() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kStoreKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final t = _TermTab.fromJson(item);
            if (t != null) _tabs.add(t);
          }
        }
      } catch (_) {
        /* 忽略损坏的本地记录（对齐 Web loadTabs） */
      }
    }
    if (!mounted) return;
    setState(() {
      if (_tabs.isNotEmpty) _current = _tabs.first.id;
    });
    _loaded = true;
  }

  Future<void> _saveTabs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kStoreKey,
      jsonEncode(_tabs.map((t) => t.toJson()).toList()),
    );
  }

  /* ============ 会话存活轮询 ============ */

  void _syncPolling() {
    final should = widget.active && _ticket.isNotEmpty && _tabs.isNotEmpty;
    if (!should) {
      _stopPolling();
      return;
    }
    _pollTimer ??= Timer.periodic(
      const Duration(milliseconds: _kPollMs),
      (_) => _refreshAlive(),
    );
    _refreshAlive();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _refreshAlive() async {
    if (_polling || _ticket.isEmpty) return;
    _polling = true;
    try {
      final list = await Api.termSessions();
      if (!mounted) return;
      setState(() {
        _alive
          ..clear()
          ..addAll(list.map((s) => '${s['name']}'));
      });
    } catch (_) {
      /* 网络波动忽略（对齐 Web refreshAlive） */
    } finally {
      _polling = false;
    }
  }

  /* ============ 二次验证门 ============ */

  Future<void> _unlock() async {
    if (_busy || _pw.isEmpty) return;
    setState(() {
      _busy = true;
      _err = '';
    });
    try {
      final d = await Api.termUnlock(_pw);
      final ticket = d['ticket'];
      if (ticket is! String || ticket.isEmpty) {
        throw ApiException('口令不正确', code: 401);
      }
      if (!mounted) return;
      _pwCtrl.clear();
      setState(() {
        _ticket = ticket;
        _pw = '';
      });
      _syncPolling();
    } on ApiException catch (e) {
      // 注意：口令错误服务端同样返回 401，这里不触发全局登出（对齐 Web）；
      // 若 SSO 真过期，后续会话轮询/关闭接口的 401 会走全局登出兜底。
      if (!mounted) return;
      _pwCtrl.clear();
      setState(() {
        _pw = '';
        if (e.code == 429) {
          _err = '尝试过多，请 ${e.retryAfter ?? 600} 秒后再试';
        } else if (e.code == 401) {
          _err = '口令不正确';
        } else {
          _err = e.message;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _err = '网络异常，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _lock() async {
    final names = _tabs.map((t) => t.id).toList();
    if (names.isNotEmpty) {
      try {
        await Api.termCloseSessions(names);
      } catch (_) {
        /* 失败由服务端 reaper 兜底（对齐 Web lock） */
      }
    }
    if (!mounted) return;
    _stopPolling();
    _pwCtrl.clear();
    setState(() {
      _ticket = '';
      _pw = '';
      _err = '';
      _alive.clear();
      _webviews.clear();
      _builtTicket.clear();
      _builtNonce.clear();
    });
    _focusGate();
  }

  /* ============ 标签操作 ============ */

  _TermTab _newTab() {
    final id = 'term-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '${_rand.nextInt(1 << 20).toRadixString(36)}';
    var max = 0;
    for (final t in _tabs) {
      final m = RegExp(r'^终端\s*(\d+)$').firstMatch(t.title);
      final n = int.tryParse(m?.group(1) ?? '') ?? 0;
      if (n > max) max = n;
    }
    return _TermTab(id, '终端 ${max + 1}');
  }

  void _addTab() {
    final t = _newTab();
    setState(() {
      _tabs.add(t);
      _current = t.id;
    });
    _saveTabs();
    _syncPolling();
  }

  Future<void> _closeTab(String id) async {
    final rest = _tabs.where((t) => t.id != id).toList();
    setState(() {
      _tabs
        ..clear()
        ..addAll(rest);
      _webviews.remove(id);
      _builtTicket.remove(id);
      _builtNonce.remove(id);
      if (_current == id) _current = rest.isNotEmpty ? rest.last.id : null;
    });
    _saveTabs();
    try {
      await Api.termCloseSession(id);
    } catch (_) {
      /* 忽略（对齐 Web closeTab finally refreshAlive） */
    }
    _refreshAlive();
    _syncPolling();
  }

  void _reconnect() {
    setState(() {
      _nonce++;
      _webviews.clear();
      _builtTicket.clear();
      _builtNonce.clear();
    });
    _refreshAlive();
  }

  /* ============ WebView 管理 ============ */

  WebViewController _controllerFor(_TermTab t) {
    final existing = _webviews[t.id];
    if (existing != null &&
        _builtTicket[t.id] == _ticket &&
        _builtNonce[t.id] == _nonce) {
      return existing;
    }
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_kTermBg)
      // 存活状态即时刷新（对齐 Web：iframe onLoad 后 800ms refreshAlive）
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            Future.delayed(const Duration(milliseconds: 800), () {
              if (mounted) _refreshAlive();
            });
          },
        ),
      )
      // 鉴权走网关 Bearer：WebView 首帧请求头带 Authorization（不再用 URL token，
      // 避免令牌落进 URL / 历史记录）。子资源由 ttyd 同源加载，依赖前端会话态。
      ..loadRequest(
        Uri.parse(Api.termUrl(t.id, _ticket)),
        headers: Api.webviewHeaders(),
      );
    _webviews[t.id] = controller;
    _builtTicket[t.id] = _ticket;
    _builtNonce[t.id] = _nonce;
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (_ticket.isEmpty) return _gate(c);

    final tabs = _tabs;
    var index = tabs.indexWhere((t) => t.id == _current);
    if (index < 0) index = 0;

    return Column(
      children: [
        _tabStrip(c, tabs),
        Expanded(
          child: Container(
            color: _kTermBg,
            child: tabs.isEmpty
                ? Center(
                    child: Text(
                      '点击 ＋ 新建终端',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  )
                : IndexedStack(
                    index: index,
                    children: [
                      for (final t in tabs)
                        WebViewWidget(controller: _controllerFor(t)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /* ============ 二次验证门（对齐 Web .term-gate） ============ */

  Widget _gate(AppColors c) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '服务器终端',
              style: TextStyle(
                color: c.fg,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '需二次验证后进入',
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _pwCtrl,
                      focusNode: _pwFocus,
                      obscureText: true,
                      enabled: !_busy,
                      onChanged: (v) => setState(() => _pw = v),
                      onSubmitted: (_) => _unlock(),
                      style: TextStyle(
                        color: c.fg,
                        fontSize: 14,
                        fontFamily: 'monospace',
                        letterSpacing: 2,
                      ),
                      decoration: const InputDecoration(
                        hintText: '访问口令',
                        contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: (_busy || _pw.isEmpty) ? null : _unlock,
                    child: Container(
                      width: 76,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.circular(4),
                        color: (_busy || _pw.isEmpty) ? null : c.surface2,
                      ),
                      child: Text(
                        _busy ? '校验中' : '进入',
                        style: TextStyle(
                          color: (_busy || _pw.isEmpty) ? c.muted : c.fg,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_err.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _err,
                style: TextStyle(color: c.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /* ============ 标签条（对齐 Web .term-tabs） ============ */

  Widget _tabStrip(AppColors c, List<_TermTab> tabs) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final t in tabs) _tabItem(c, t),
                  _stripBtn(c, '＋', '新建终端', _addTab),
                  _stripBtn(c, '锁定', '锁定并关闭全部会话', _lock),
                ],
              ),
            ),
          ),
          Container(width: 0.5, color: c.border),
          _stripBtn(c, '重连', '重连当前终端', _reconnect),
        ],
      ),
    );
  }

  Widget _tabItem(AppColors c, _TermTab t) {
    final active = t.id == _current;
    final alive = _alive.contains(t.id);
    return InkWell(
      onTap: () => setState(() => _current = t.id),
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: active ? c.surface2 : null,
          border: Border(
            right: BorderSide(color: c.border, width: 0.5),
            bottom: BorderSide(
              color: active ? c.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 5,
              color: alive ? c.ok : c.muted,
            ),
            const SizedBox(width: 7),
            Text(
              t.title,
              style: TextStyle(
                color: active ? c.fg : c.muted,
                fontSize: 11.5,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              onTap: () => _closeTab(t.id),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  '×',
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 14,
                    height: 1,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stripBtn(AppColors c, String label, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: c.border, width: 0.5)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: c.muted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}
