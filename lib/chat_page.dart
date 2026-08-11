import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'login_page.dart';
import 'theme.dart';
import 'ws.dart';

class Session {
  final String storedId;
  final String title;
  Session(this.storedId, this.title);
}

class FileRef {
  final String path;
  final String name;
  final bool isImage;
  FileRef(this.path, this.name, {this.isImage = false});
}

class ChatMessage {
  final String id;
  final String role; // user / assistant / system
  final String content;
  final List<String> images;
  final List<FileRef> files;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.images = const [],
    this.files = const [],
  });
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const double _drawerWidth = 276;

  final List<Session> _sessions = [];
  final List<ChatMessage> _messages = [];
  final List<FileRef> _pending = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String? _currentStoredId;
  String? _currentId;
  bool _streaming = false;
  bool _initDone = false;
  bool _drawerOpen = false;
  String? _error;

  StreamSubscription<WsEvent>? _sub;
  ValueNotifier<WsStatus>? _wsStatus;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _wsStatus?.removeListener(_onWsStatus);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await WsClient.instance.connect();
      _wsStatus = WsClient.instance.status;
      _wsStatus?.addListener(_onWsStatus);
      _sub = WsClient.instance.events.listen(_onEvent);

      final data = await WsClient.instance.rpc('session.list');
      final sessions = _toSessions(data);
      if (!mounted) return;
      setState(() {
        _sessions.clear();
        _sessions.addAll(sessions);
      });
      if (sessions.isNotEmpty) {
        await _switchSession(sessions.first.storedId);
      } else {
        await _createSession();
      }
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _showError('初始化失败: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _initDone = true);
    }
  }

  void _onWsStatus() {
    if (mounted) setState(() {});
  }

  /// 事件处理：流式追加
  void _onEvent(WsEvent ev) {
    if (ev.sessionId != null &&
        ev.sessionId!.isNotEmpty &&
        ev.sessionId != _currentId) {
      return; // 非当前会话的消息忽略
    }

    switch (ev.type) {
      case 'message.start':
        setState(() {
          _messages.add(ChatMessage(id: '', role: 'assistant', content: ''));
          _streaming = true;
        });
        _scrollToBottom();
        break;
      case 'message.delta':
        final text = ev.payload['text'] ?? ev.params['text'] ?? '';
        if (text is! String || text.isEmpty) return;
        setState(() {
          if (_messages.isNotEmpty) {
            final last = _messages.last;
            _messages[_messages.length - 1] = ChatMessage(
              id: last.id,
              role: last.role,
              content: last.content + text,
              images: last.images,
              files: last.files,
            );
          }
        });
        _scrollToBottom();
        break;
      case 'message.complete':
        final text = ev.payload['text'] ?? ev.params['text'] ?? '';
        final rawPaths = ev.payload['image_paths'] is List
            ? ev.payload['image_paths'] as List
            : const <dynamic>[];
        final paths = rawPaths.whereType<String>().toList();
        setState(() {
          if (_messages.isNotEmpty) {
            final last = _messages.last;
            _messages[_messages.length - 1] = ChatMessage(
              id: last.id,
              role: last.role,
              content: (text is String && text.isNotEmpty)
                  ? text
                  : last.content,
              images: [...last.images, ...paths],
              files: last.files,
            );
          }
          _streaming = false;
        });
        _scrollToBottom();
        break;
      case 'message.error':
        final em = ev.payload['message'] ?? ev.params['message'] ?? '回复出错';
        setState(() {
          _streaming = false;
          _messages.add(
            ChatMessage(
              id: 'err-${DateTime.now().millisecondsSinceEpoch}',
              role: 'system',
              content: em.toString(),
            ),
          );
        });
        _scrollToBottom();
        break;
    }
  }

  List<Session> _toSessions(dynamic data) {
    final arr = _arrayOf(data, 'sessions');
    return arr.whereType<Map>().map((m) {
      final id = (m['session_id'] ?? m['id'] ?? m['stored_id'] ?? '')
          .toString();
      final title = (m['title'] ?? m['name'] ?? id).toString();
      return Session(id, title);
    }).toList();
  }

  List<ChatMessage> _toMessages(dynamic data) {
    final arr = _arrayOf(data, 'messages');
    return arr.whereType<Map>().map((m) {
      final content = m['content'] is String
          ? m['content'] as String
          : (m['text'] is String ? m['text'] as String : '');
      final images = (m['image_paths'] is List)
          ? List<String>.from(m['image_paths'] as List)
          : (m['images'] is List
                ? List<String>.from(m['images'] as List)
                : const <String>[]);
      return ChatMessage(
        id: (m['message_id'] ?? m['id'] ?? '').toString(),
        role: m['role'] == 'assistant' ? 'assistant' : 'user',
        content: content,
        images: images,
      );
    }).toList();
  }

  List<dynamic> _arrayOf(dynamic data, String key) {
    if (data is List) return data;
    if (data is Map && data[key] is List) return data[key] as List;
    return const [];
  }

  String _strField(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v != null) return v.toString();
    }
    return '';
  }

  /// 切换到历史会话：先 resume（stored id → 短 id + 历史消息），再发消息
  Future<void> _switchSession(String storedId) async {
    setState(() {
      _currentStoredId = storedId;
      _currentId = null;
      _messages.clear();
      _streaming = false;
    });
    try {
      final data = await WsClient.instance.rpc('session.resume', {
        'session_id': storedId,
      });
      if (!mounted || storedId != _currentStoredId) return;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final shortId = _strField(map ?? const {}, ['session_id', 'id']);
      final msgs = _toMessages(map != null ? map['messages'] : data);
      setState(() {
        _currentId = shortId.isNotEmpty ? shortId : storedId;
        _messages.addAll(msgs);
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _showError('加载历史失败: ${e.toString()}');
    }
  }

  Future<void> _createSession() async {
    try {
      final data = await WsClient.instance.rpc('session.create');
      final shortId = data is Map
          ? (data['session_id'] ?? data['id'] ?? '').toString()
          : '';
      final list = await WsClient.instance.rpc('session.list');
      final sessions = _toSessions(list);
      if (!mounted) return;
      setState(() {
        _sessions.clear();
        _sessions.addAll(sessions);
        _currentStoredId = shortId.isNotEmpty ? shortId : null;
        _currentId = shortId.isNotEmpty ? shortId : null;
        _messages.clear();
        _streaming = false;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _showError('创建会话失败: ${e.toString()}');
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _pending.isEmpty) ||
        _currentId == null ||
        _currentId!.isEmpty ||
        _streaming) {
      return;
    }

    final images = _pending.where((a) => a.isImage).map((a) => a.path).toList();
    final files = _pending.where((a) => !a.isImage).toList();
    // 普通文件没有专用字段：把文件名+路径以文本形式附在 text 后面
    final attachText = files.map((f) => '[附件] ${f.name}: ${f.path}').join('\n');
    final submitText = attachText.isNotEmpty
        ? (text.isNotEmpty ? '$text\n$attachText' : attachText)
        : text;

    setState(() {
      _messages.add(
        ChatMessage(
          id: 'local-${DateTime.now().millisecondsSinceEpoch}',
          role: 'user',
          content: submitText,
          images: List.of(images),
          files: List.of(files),
        ),
      );
      _streaming = true;
      _input.clear();
      _pending.clear();
      _error = null;
    });
    _scrollToBottom();

    try {
      await WsClient.instance.rpc('prompt.submit', {
        'session_id': _currentId,
        'text': submitText,
        if (images.isNotEmpty) 'image_paths': images,
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (handled) return;
      setState(() {
        _streaming = false;
        _messages.add(
          ChatMessage(
            id: 'err-${DateTime.now().millisecondsSinceEpoch}',
            role: 'system',
            content: '发送失败: ${e.toString()}',
          ),
        );
      });
    }
  }

  Future<void> _interrupt() async {
    if (_currentId == null || _currentId!.isEmpty) return;
    setState(() => _streaming = false);
    try {
      await WsClient.instance.rpc('session.interrupt', {
        'session_id': _currentId,
      });
    } catch (_) {
      // 中断失败可忽略
    }
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickMultiImage();
      if (picked.isEmpty) return;
      for (final p in picked) {
        await _upload(p.path, p.name, isImage: true);
      }
    } catch (e) {
      _showError('选择图片失败: ${e.toString()}');
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      for (final f in result.files) {
        final path = f.path;
        if (path == null || path.isEmpty) continue;
        await _upload(path, f.name, isImage: _isImageName(f.name));
      }
    } catch (e) {
      _showError('选择文件失败: ${e.toString()}');
    }
  }

  bool _isImageName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
    }.contains(ext);
  }

  Future<void> _upload(
    String path,
    String name, {
    required bool isImage,
  }) async {
    try {
      final serverPath = await Api.upload(File(path), name);
      if (!mounted) return;
      setState(() => _pending.add(FileRef(serverPath, name, isImage: isImage)));
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _showError('上传失败: ${e.toString()}');
    }
  }

  Future<void> _download(String serverPath, String name) async {
    try {
      final bytes = await Api.download(serverPath);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已保存: ${file.path}')));
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _showError('下载失败: ${e.toString()}');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() => _error = msg);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _previewImage(String serverPath) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: InteractiveViewer(
            child: Image.network(
              Api.downloadUrl(serverPath),
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wsReady =
        (_wsStatus?.value ?? WsStatus.disconnected) == WsStatus.ready;
    final activeTitle = _currentSessionTitle();
    return Stack(
      children: [
        Column(
          children: [
            _buildTopBar(wsReady: wsReady, title: activeTitle),
            const SizedBox(height: 6),
            Expanded(child: _buildMessageList()),
            if (_pending.isNotEmpty) _buildPendingBar(),
            if (_error != null) _buildErrorBar(),
            _buildComposer(),
          ],
        ),
        if (_drawerOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _drawerOpen = false),
              child: const ColoredBox(color: Colors.black54),
            ),
          ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          left: _drawerOpen ? 0 : -_drawerWidth - 32,
          top: 0,
          bottom: 0,
          width: _drawerWidth,
          child: _buildDrawer(),
        ),
      ],
    );
  }

  String _currentSessionTitle() {
    if (_currentStoredId == null) return '新会话';
    for (final s in _sessions) {
      if (s.storedId == _currentStoredId) return s.title;
    }
    return _currentStoredId!;
  }

  Widget _buildTopBar({required bool wsReady, required String title}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: kSurface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => setState(() => _drawerOpen = true),
            icon: const Icon(Icons.menu_rounded, color: Colors.white),
            tooltip: '会话列表',
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: wsReady
                            ? const Color(0xFF4CAF50)
                            : kMuted,
                        boxShadow: wsReady
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF4CAF50)
                                      .withValues(alpha: 0.5),
                                  blurRadius: 6,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      wsReady ? '已连接' : '连接中…',
                      style: const TextStyle(color: kMuted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_streaming)
            IconButton(
              onPressed: _interrupt,
              icon: const Icon(Icons.stop_circle_outlined, color: kAmber),
              tooltip: '中断生成',
            ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
        border: Border.all(color: kBorder),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(6, 0)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 12, 8),
            child: Row(
              children: [
                const Text(
                  '会话',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => setState(() => _drawerOpen = false),
                  icon: const Icon(Icons.close, color: kMuted, size: 20),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: kAmberGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ElevatedButton(
                  onPressed: () {
                    setState(() => _drawerOpen = false);
                    _createSession();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('＋ 新会话'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: _sessions.length,
              itemBuilder: (_, i) {
                final s = _sessions[i];
                final active = s.storedId == _currentStoredId;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  child: Material(
                    color: active
                        ? kAmber.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() => _drawerOpen = false);
                        _switchSession(s.storedId);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              active
                                  ? Icons.chat_bubble
                                  : Icons.chat_bubble_outline,
                              size: 16,
                              color: active ? kAmber : kMuted,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: active ? Colors.white : kMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (!_initDone) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: kAmberGradient,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: Colors.black,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '开始和 Hermes 对话吧',
              style: TextStyle(color: kMuted, fontSize: 14),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: _messages.length,
      itemBuilder: (_, i) =>
          _buildBubble(_messages[i], isLast: i == _messages.length - 1),
    );
  }

  Widget _buildBubble(ChatMessage m, {required bool isLast}) {
    final isUser = m.role == 'user';
    final isSystem = m.role == 'system';
    final showCursor = _streaming && isLast && !isUser;

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1A1A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF5C2A2A)),
            ),
            child: Text(
              m.content,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFEF9A9A), fontSize: 12.5),
            ),
          ),
        ),
      );
    }

    final maxW = MediaQuery.sizeOf(context).width * 0.76;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: kAmberGradient,
                shape: BoxShape.circle,
              ),
              child: const Text(
                'H',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxW),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                gradient: isUser ? kAmberGradient : null,
                color: isUser ? null : const Color(0xFF25252A),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 5),
                  bottomRight: Radius.circular(isUser ? 5 : 16),
                ),
                border: isUser ? null : Border.all(color: kBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.content.isNotEmpty)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            m.content,
                            style: TextStyle(
                              color: isUser ? Colors.black : Colors.white,
                              fontSize: 15,
                              height: 1.45,
                            ),
                          ),
                        ),
                        if (showCursor)
                          const Padding(
                            padding: EdgeInsets.only(left: 2, bottom: 2),
                            child: _TypingCursor(),
                          ),
                      ],
                    )
                  else if (showCursor)
                    const Padding(
                      padding: EdgeInsets.only(top: 3, bottom: 3),
                      child: _TypingCursor(),
                    ),
                  ...m.images.map((p) => _buildImage(p)),
                  ...m.files.map((f) => _buildFileChip(f)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage(String serverPath) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        onTap: () => _previewImage(serverPath),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            Api.downloadUrl(serverPath),
            width: 190,
            fit: BoxFit.cover,
            loadingBuilder: (c, child, progress) {
              if (progress == null) return child;
              return Container(
                width: 190,
                height: 130,
                color: const Color(0xFF2A2A2E),
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            },
            errorBuilder: (c, e, s) => Container(
              width: 190,
              height: 130,
              color: const Color(0xFF2A2A2E),
              child: const Center(
                child: Icon(Icons.broken_image_outlined, color: kMuted),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileChip(FileRef f) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () => _download(f.path, f.name),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF3A3A40)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.attach_file, size: 16, color: kMuted),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  f.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.download_outlined, size: 16, color: kAmber),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPendingBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kSurface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: _pending.asMap().entries.map((e) {
          final i = e.key;
          final a = e.value;
          return Chip(
            avatar: Icon(
              a.isImage ? Icons.image_outlined : Icons.attach_file,
              size: 16,
              color: kMuted,
            ),
            label: Text(a.name, overflow: TextOverflow.ellipsis),
            labelStyle: const TextStyle(fontSize: 12, color: Colors.white),
            backgroundColor: kCard,
            deleteIcon: const Icon(Icons.close, size: 14, color: kMuted),
            onDeleted: () => setState(() => _pending.removeAt(i)),
            visualDensity: VisualDensity.compact,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildErrorBar() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF5C2A2A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFEF9A9A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Color(0xFFEF9A9A), fontSize: 12),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _error = null),
            child: const Icon(Icons.close, size: 14, color: kMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 10),
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      decoration: BoxDecoration(
        color: kSurface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: _pickImage,
            icon: const Icon(Icons.image_outlined, color: kMuted, size: 22),
            tooltip: '图片',
          ),
          IconButton(
            onPressed: _pickFile,
            icon: const Icon(Icons.attach_file, color: kMuted, size: 22),
            tooltip: '文件',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: '输入消息…',
                  filled: true,
                  fillColor: kCard,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _streaming ? _stopButton() : _sendButton(),
        ],
      ),
    );
  }

  Widget _sendButton() {
    return _roundButton(
      onTap: _send,
      gradient: kAmberGradient,
      child: const Icon(Icons.arrow_upward_rounded, color: Colors.black, size: 24),
    );
  }

  Widget _stopButton() {
    return _roundButton(
      onTap: _interrupt,
      color: const Color(0xFF7A2B2B),
      child: const Icon(Icons.stop_rounded, color: Colors.white, size: 24),
    );
  }

  Widget _roundButton({
    required VoidCallback onTap,
    LinearGradient? gradient,
    Color? color,
    required Widget child,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          gradient: gradient,
          color: color,
          shape: BoxShape.circle,
          boxShadow: gradient != null
              ? [
                  BoxShadow(
                    color: kAmber.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Center(child: child),
      ),
    );
  }
}

/// 流式打字光标：闪烁的竖条
class _TypingCursor extends StatefulWidget {
  const _TypingCursor();

  @override
  State<_TypingCursor> createState() => _TypingCursorState();
}

class _TypingCursorState extends State<_TypingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.15, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 2.4,
        height: 16,
        decoration: BoxDecoration(
          color: kAmber,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
