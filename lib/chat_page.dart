import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'file_refs.dart';
import 'image_refs.dart';
import 'media_tags.dart';
import 'theme.dart';

/* ============ 数据模型 ============ */

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

/* ============ 只读浏览页 ============ */

class BrowsePage extends StatefulWidget {
  const BrowsePage({super.key, this.active = true});

  /// 是否处于可见 Tab
  final bool active;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  static const double _drawerWidth = 280;

  final ScrollController _scroll = ScrollController();

  List<Session> _sessions = [];
  final List<ChatMessage> _messages = [];

  String? _currentId;
  String? _currentIdRef; // 切换中的会话 id（竞态守卫）

  bool _loading = true;
  bool _drawerOpen = false;
  bool _stickToBottom = true;
  bool _showScrollBtn = false;
  String? _error;
  String? _toastMsg;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BrowsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // 切回浏览 Tab：IndexedStack 恢复后瞬时定位到底部
      _scrollToBottom(force: true);
    }
  }

  Future<void> _loadSessions() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Api.historySessions();
      if (!mounted) return;
      // 按时间倒序
      final list = toSessions(data)
        ..sort((a, b) {
          final at = a.time?.millisecondsSinceEpoch ?? 0;
          final bt = b.time?.millisecondsSinceEpoch ?? 0;
          return bt.compareTo(at);
        });
      setState(() => _sessions = list);
      if (list.isEmpty) {
        _currentIdRef = null;
        setState(() {
          _currentId = null;
          _messages.clear();
          _loading = false;
        });
        return;
      }
      // 保持当前浏览会话，否则选中第一条
      final keep = list.any((s) => s.id == _currentIdRef);
      final id = keep ? _currentIdRef! : list.first.id;
      _currentIdRef = id;
      setState(() => _currentId = id);
      await _loadMessages(id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载会话列表失败: ${e.toString()}';
        _loading = false;
      });
    }
  }

  Future<void> _loadMessages(String id) async {
    setState(() {
      _messages.clear();
      _loading = true;
      _error = null;
    });
    try {
      final data = await Api.historyMessages(id);
      if (!mounted || _currentIdRef != id) return; // 期间已切走
      setState(() {
        _messages.addAll(toMessages(data));
        _loading = false;
      });
      _scrollToBottom(force: true);
    } catch (e) {
      if (!mounted || _currentIdRef != id) return;
      setState(() {
        _messages.clear();
        _error = '加载会话消息失败: ${e.toString()}';
        _loading = false;
      });
    }
  }

  Future<void> _switchSession(String id) async {
    if (id == _currentIdRef) return;
    _currentIdRef = id;
    setState(() {
      _currentId = id;
      _drawerOpen = false;
      _loading = true;
      _error = null;
    });
    await _loadMessages(id);
  }

  /* ============ 消息操作（复制） ============ */

  Future<void> _copyMessage(ChatMessage msg) async {
    final text = parseFileRefs(msg.content).text;
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制');
  }

  void _showMessageActions(ChatMessage msg) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy, size: 20),
              title: const Text('复制'),
              onTap: () {
                Navigator.of(ctx).pop();
                _copyMessage(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  /* ============ 下载 ============ */

  Future<void> _download(String serverPath, String name) async {
    try {
      final bytes = await Api.download(serverPath);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存: ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      _showError('下载失败: ${e.toString()}');
    }
  }

  /* ============ 工具 ============ */

  void _showError(String msg) {
    if (!mounted) return;
    setState(() => _error = msg);
  }

  void _toast(String msg) {
    if (!mounted) return;
    _toastTimer?.cancel();
    setState(() => _toastMsg = msg);
    _toastTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _toastMsg = null);
    });
  }

  void _scrollToBottom({bool force = false}) {
    if (force) _stickToBottom = true;
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (target > 0 && _scroll.offset < target) {
        _scroll.jumpTo(target);
      }
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final nearBottom =
        _scroll.position.maxScrollExtent - _scroll.offset < 48;
    _stickToBottom = nearBottom;
    if (nearBottom != !_showScrollBtn) {
      setState(() => _showScrollBtn = !nearBottom);
    }
  }

  void _previewImage(String serverPath) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: GestureDetector(
            onTap: () => Navigator.of(ctx).pop(),
            child: InteractiveViewer(
              child: Image.network(Api.downloadUrl(serverPath), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  /* ============ 构建 ============ */

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final title = _currentSessionTitle();
    return Stack(
      children: [
        Column(
          children: [
            _buildTopBar(c, title),
            const SizedBox(height: 6),
            _buildReadonlyHint(c),
            Expanded(child: _buildMessageList(c)),
            if (_error != null) _buildErrorBar(c),
          ],
        ),
        if (_showScrollBtn && !_loading)
          Positioned(
            right: 14,
            bottom: 120,
            child: FloatingActionButton.small(
              heroTag: 'scroll-bottom',
              backgroundColor: c.surface2,
              foregroundColor: c.accent,
              onPressed: () => _scrollToBottom(force: true),
              child: const Icon(Icons.keyboard_arrow_down),
            ),
          ),
        if (_drawerOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _drawerOpen = false),
              child: ColoredBox(color: c.overlay),
            ),
          ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          left: _drawerOpen ? 0 : -_drawerWidth - 32,
          top: 0,
          bottom: 0,
          width: _drawerWidth,
          child: _buildDrawer(c),
        ),
        if (_toastMsg != null)
          Positioned(
            top: 70,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  _toastMsg!,
                  style: TextStyle(color: c.ok, fontSize: 13),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _currentSessionTitle() {
    if (_currentId == null) return '历史会话';
    for (final s in _sessions) {
      if (s.id == _currentId) return s.title;
    }
    return _currentId!;
  }

  Widget _buildTopBar(AppColors c, String title) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => setState(() => _drawerOpen = true),
            icon: Icon(Icons.menu_rounded, color: c.fg),
            tooltip: '会话列表',
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.fg,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadonlyHint(AppColors c) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.accentBorder),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 14, color: c.accent),
          const SizedBox(width: 8),
          Text(
            '只读浏览 · 历史会话记录',
            style: TextStyle(color: c.accent, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
        border: Border.all(color: c.border),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(6, 0)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
            child: Row(
              children: [
                Text(
                  '历史会话',
                  style: TextStyle(
                    color: c.fg,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => setState(() => _drawerOpen = false),
                  icon: Icon(Icons.close, color: c.muted, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: _sessions.isEmpty
                ? Center(
                    child: Text(
                      '暂无历史会话',
                      style: TextStyle(color: c.muted, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: _sessions.length,
                    itemBuilder: (_, i) => _buildSessionItem(c, _sessions[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionItem(AppColors c, Session s) {
    final active = s.id == _currentId;
    final t = formatMessageTime(s.time);
    final timeText = t.isEmpty ? '暂无时间' : t;
    final sub = s.messageCount > 0 ? '$timeText · ${s.messageCount} 条' : timeText;
    return Container(
      decoration: BoxDecoration(
        color: active ? c.accentSoft : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: active ? c.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: InkWell(
        onTap: () {
          setState(() => _drawerOpen = false);
          _switchSession(s.id);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? c.accent : c.fg,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                sub,
                style: TextStyle(color: c.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(AppColors c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_currentId == null) {
      return _empty(c, Icons.history, '暂无历史会话');
    }
    if (_messages.isEmpty) {
      return _empty(c, Icons.forum_outlined, '该会话暂无消息');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        _onScroll();
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: _messages.length,
        // 服务端消息无 id，key 用索引兜底
        itemBuilder: (_, i) => KeyedSubtree(
          key: ValueKey('msg-$i'),
          child: _buildBubble(c, _messages[i]),
        ),
      ),
    );
  }

  Widget _empty(AppColors c, IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: c.muted, size: 30),
          const SizedBox(height: 14),
          Text(text, style: TextStyle(color: c.muted, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildBubble(AppColors c, ChatMessage m) {
    final isUser = m.role == 'user';

    // 渲染管线：@image / @file / MEDIA 解析（与 Web 一致），文本保留 markdown
    final imgR = parseImageRefs(m.content);
    final fileR = parseFileRefs(imgR.text);
    final mediaR = parseMediaTags(fileR.text);
    final displayText = mediaR.text;
    final images = <String>[
      ...m.images,
      ...imgR.images,
      ...mediaR.media.where((x) => x.isImage).map((x) => x.path),
    ];
    final files = <FileRef>[
      ...m.files,
      ...fileR.files.map((f) => FileRef(f.path, f.ext)),
      ...mediaR.media.where((x) => !x.isImage).map((x) => FileRef(x.path, x.ext)),
    ];

    final maxW = MediaQuery.sizeOf(context).width * 0.82;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onLongPress: () => _showMessageActions(m),
        child: Row(
          mainAxisAlignment: isUser
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  border: Border.all(color: c.accentBorder),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  'H',
                  style: TextStyle(
                    color: c.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Container(
                constraints: BoxConstraints(maxWidth: maxW),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isUser ? c.surface2 : c.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: c.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (displayText.isNotEmpty)
                      isUser
                          ? SelectableText(
                              displayText,
                              style: TextStyle(
                                color: c.fg,
                                fontSize: 15,
                                height: 1.5,
                              ),
                            )
                          : _buildMarkdown(c, displayText),
                    if (images.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _buildImageGrid(c, images),
                    ],
                    if (files.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...files.map((f) => _buildFileCard(c, f)),
                    ],
                    if (m.ts != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          formatMessageTime(m.ts),
                          style: TextStyle(color: c.muted, fontSize: 10),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarkdown(AppColors c, String text) {
    final styleSheet = MarkdownStyleSheet(
      p: TextStyle(color: c.fg, fontSize: 15, height: 1.55),
      strong: TextStyle(color: c.fg, fontWeight: FontWeight.w700),
      em: TextStyle(color: c.fg, fontStyle: FontStyle.italic),
      code: TextStyle(
        color: c.accent,
        fontSize: 13,
        backgroundColor: c.codeBg,
        fontFamily: 'monospace',
      ),
      codeblockDecoration: BoxDecoration(
        color: c.codeBg,
        border: Border.all(color: c.border),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquote: TextStyle(color: c.muted, fontSize: 14, height: 1.5),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.accent, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      listBullet: TextStyle(color: c.accent),
      tableHead: TextStyle(
        color: c.fg,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      tableBody: TextStyle(color: c.fg, fontSize: 14),
      tableBorder: TableBorder.all(color: c.border),
      tableColumnWidth: const FlexColumnWidth(),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      h1: TextStyle(color: c.fg, fontSize: 22, fontWeight: FontWeight.w700, height: 1.4),
      h2: TextStyle(color: c.fg, fontSize: 19, fontWeight: FontWeight.w700, height: 1.4),
      h3: TextStyle(color: c.fg, fontSize: 17, fontWeight: FontWeight.w700, height: 1.4),
      h4: TextStyle(color: c.fg, fontSize: 15, fontWeight: FontWeight.w600, height: 1.4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      styleSheet: styleSheet,
      builders: {'pre': _CodeBlockBuilder(c, _toast)},
      onTapLink: (text, href, title) {
        if (href != null && href.isNotEmpty) {
          launchUrl(
            Uri.parse(href),
            mode: LaunchMode.externalApplication,
          ).catchError((_) => false);
        }
      },
    );
  }

  Widget _buildImageGrid(AppColors c, List<String> images) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: images.map((p) => _buildImage(c, p)).toList(),
    );
  }

  Widget _buildImage(AppColors c, String serverPath) {
    return GestureDetector(
      onTap: () => _previewImage(serverPath),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          Api.downloadUrl(serverPath),
          width: 150,
          height: 110,
          fit: BoxFit.cover,
          loadingBuilder: (ctx, child, progress) {
            if (progress == null) return child;
            return Container(
              width: 150,
              height: 110,
              color: c.surface2,
              child: const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
          errorBuilder: (ctx, e, s) => Container(
            width: 150,
            height: 110,
            color: c.surface2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image_outlined, color: c.muted, size: 26),
                const SizedBox(height: 6),
                Text(
                  '图片加载失败',
                  style: TextStyle(color: c.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileCard(AppColors c, FileRef f) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: () => _download(f.path, f.name),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _fileBadge(c, f.ext),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.fg, fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.download_outlined, size: 16, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileBadge(AppColors c, String ext) {
    String badge;
    if (const {'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'apk', 'ipa'}.contains(ext)) {
      badge = 'ZIP';
    } else if (const {'mp3', 'm2a', 'wav', 'ogg', 'opus', 'm4a', 'flac'}.contains(ext)) {
      badge = 'AUD';
    } else if (const {'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'}.contains(ext)) {
      badge = 'VID';
    } else if (const {
      'pdf', 'doc', 'docx', 'odt', 'rtf', 'md', 'txt', 'epub',
      'xls', 'xlsx', 'ods', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml',
      'ppt', 'pptx', 'odp', 'key',
    }.contains(ext)) {
      badge = 'DOC';
    } else {
      badge = 'FILE';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.accentBorder),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        badge,
        style: TextStyle(
          color: badge == 'FILE' ? c.muted : c.accent,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildErrorBar(AppColors c) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: c.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: c.danger, fontSize: 12),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _error = null),
            child: Icon(Icons.close, size: 14, color: c.muted),
          ),
        ],
      ),
    );
  }
}

/* ============ 代码块复制按钮 ============ */

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.c, this.toast);

  final AppColors c;
  final void Function(String) toast;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: c.codeBg,
        border: Border.all(color: c.border),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 34, 10, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                code,
                style: TextStyle(
                  color: c.fg,
                  fontSize: 12.5,
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: code));
                toast('已复制');
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: c.border),
                  color: c.surface2,
                ),
                child: Text(
                  '复制',
                  style: TextStyle(color: c.muted, fontSize: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
