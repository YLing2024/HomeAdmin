import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'command_palette.dart';
import 'file_refs.dart';
import 'image_refs.dart';
import 'login_page.dart';
import 'media_tags.dart';
import 'theme.dart';
import 'ws.dart';

/* ============ 数据模型 ============ */

class Session {
  final String storedId;
  final String title;
  final bool local;
  const Session(this.storedId, this.title, {this.local = false});
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
  final String id;
  final String role; // user / assistant / system
  final String content;
  final List<String> images;
  final List<FileRef> files;
  final DateTime? ts;
  final bool local;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.images = const [],
    this.files = const [],
    this.ts,
    this.local = false,
  });

  ChatMessage copyWith({
    String? id,
    String? content,
    List<String>? images,
    List<FileRef>? files,
    DateTime? ts,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role,
      content: content ?? this.content,
      images: images ?? this.images,
      files: files ?? this.files,
      ts: ts ?? this.ts,
      local: local,
    );
  }
}

/* ============ 字段归一化 ============ */

List<Session> toSessions(dynamic data) {
  final arr = _arrayOf(data, 'sessions');
  return arr.whereType<Map>().map((m) {
    final id = (m['session_id'] ?? m['id'] ?? m['sessionId'] ?? '').toString();
    final title = (m['title'] ?? m['name'] ?? m['session_id'] ?? m['id'] ?? '会话').toString();
    return Session(id, title);
  }).toList();
}

List<ChatMessage> toMessages(dynamic data) {
  final arr = _arrayOf(data, 'messages');
  return arr.whereType<Map>().map((m) {
    final raw = Map<String, dynamic>.from(m);
    final content = _extractContent(raw);
    // 历史带图消息以文本引用 @image:/abs/path 落库：解析出路径并入 images
    final parsed = parseImageRefs(content);
    final rawImages = raw['image_paths'] is List
        ? List<String>.from(raw['image_paths'] as List)
        : (raw['images'] is List ? List<String>.from(raw['images'] as List) : const <String>[]);
    return ChatMessage(
      id: (raw['message_id'] ?? raw['id'] ?? '').toString(),
      role: raw['role'] == 'assistant' ? 'assistant' : 'user',
      content: parsed.text,
      images: [...rawImages, ...parsed.images],
      ts: _parseTs(raw),
    );
  }).toList();
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

/* ============ 聊天页 ============ */

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.active = true});

  /// 是否处于可见 Tab（隐藏时暂停外部消息处理）
  final bool active;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const double _drawerWidth = 280;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  List<Session> _sessions = [];
  final List<ChatMessage> _messages = [];
  final List<String> _pendingImages = [];
  final List<String> _pendingFiles = [];
  final List<ChatMessage> _queue = [];

  String? _currentStoredId;
  String? _currentId;
  final Map<String, String> _localIdMap = {};
  final Map<String, String> _titleOverrides = {};

  bool _streaming = false;
  bool _busy = false;
  bool _loading = true;
  bool _drawerOpen = false;
  bool _everReady = false;
  bool _stickToBottom = true;
  bool _showScrollBtn = false;
  bool _sessionsLoaded = false;
  String? _error;
  String? _toastMsg;
  Timer? _toastTimer;
  late final void Function() _unregNewSession;
  late final void Function() _unregCopySessionId;

  StreamSubscription<WsEvent>? _sub;
  WsStatus _wsStatus = WsStatus.disconnected;

  // 外部消息（微信等）轮询
  Timer? _externalPollTimer;
  Timer? _externalDelayedTimer;
  String _lastExtText = '';
  int _lastExtTs = 0;
  int _pollCount = 0;

  // 草稿
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    _sub = WsClient.instance.onEvent(_onEvent);
    WsClient.instance.status.addListener(_onWsStatus);
    _unregNewSession = registerAction('newSession', _createSession);
    _unregCopySessionId = registerAction('copySessionId', _copySessionId);
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    WsClient.instance.status.removeListener(_onWsStatus);
    _toastTimer?.cancel();
    _draftTimer?.cancel();
    _stopExternalPoll();
    _stopExternalDelayed();
    _saveDraft();
    _unregNewSession();
    _unregCopySessionId();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _wsStatus = WsClient.instance.status.value;
    try {
      await WsClient.instance.connect();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '连接失败: ${e.toString()}，正在自动重连…');
      return;
    }
    if (mounted) {
      setState(() {
        _wsStatus = WsStatus.ready;
        _everReady = true;
      });
      _loadSessions();
    }
  }

  void _onWsStatus() {
    if (!mounted) return;
    final s = WsClient.instance.status.value;
    setState(() {
      _wsStatus = s;
      if (s == WsStatus.ready) {
        _everReady = true;
      } else if (s == WsStatus.disconnected) {
        // 断线：解除流式/忙碌锁，避免回复中断后 UI 永久锁死
        _streaming = false;
        _busy = false;
      }
    });
    if (s == WsStatus.ready && !_sessionsLoaded) {
      _loadSessions();
    }
  }

  /* ============ 事件处理 ============ */

  void _onEvent(WsEvent ev) {
    final type = ev.type;

    if (type == 'gateway.ready') {
      if (mounted) {
        setState(() {
          _everReady = true;
          _wsStatus = WsStatus.ready;
        });
      }
      return;
    }

    if (type == 'admin.external_message') {
      _handleExternal(ev);
      return;
    }

    if (type == 'sessions.changed') {
      if (!_streaming && !_busy) _refreshCurrentSession();
      return;
    }

    final sid = ev.sessionId;
    if (sid != null && sid.isNotEmpty && sid != _currentId) return;

    switch (type) {
      case 'message.start':
        setState(() {
          _messages.add(ChatMessage(id: '', role: 'assistant', content: ''));
          _streaming = true;
        });
        _scrollToBottom(force: true);
        break;
      case 'message.delta':
        final text = ev.payload['text'] ??
            ev.params['text'] ??
            ev.params['delta'] ??
            ev.params['content'] ??
            '';
        if (text is! String || text.isEmpty) return;
        setState(() {
          final idx = _lastAssistantIndex();
          if (idx >= 0) {
            final m = _messages[idx];
            _messages[idx] = m.copyWith(content: m.content + text);
          }
        });
        _scrollToBottom();
        break;
      case 'message.complete':
        try {
          final text = ev.payload['text'] ??
              ev.params['text'] ??
              ev.params['content'] ??
              '';
          final rawPaths = ev.payload['image_paths'] is List
              ? ev.payload['image_paths'] as List
              : (ev.params['image_paths'] is List
                    ? ev.params['image_paths'] as List
                    : const <dynamic>[]);
          final paths = rawPaths.whereType<String>().toList();
          setState(() {
            final idx = _lastAssistantIndex();
            if (idx >= 0) {
              final m = _messages[idx];
              _messages[idx] = m.copyWith(
                content: (text is String && text.isNotEmpty)
                    ? text
                    : m.content,
                images: [...m.images, ...paths],
              );
            }
          });
          _refreshSessions();
        } finally {
          _settleReply();
        }
        break;
      case 'message.error':
      case 'error':
        try {
          final em = ev.payload['message'] ??
              ev.params['message'] ??
              '回复出错';
          setState(() {
            _messages.add(
              ChatMessage(
                id: 'err-${DateTime.now().millisecondsSinceEpoch}',
                role: 'system',
                content: em.toString(),
                ts: DateTime.now(),
              ),
            );
          });
          _scrollToBottom(force: true);
        } finally {
          _settleReply();
        }
        break;
    }
  }

  int _lastAssistantIndex() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'assistant') return i;
    }
    return -1;
  }

  void _handleExternal(WsEvent ev) {
    if (!widget.active) return;
    final payload = ev.payload;
    final chatId = (payload['chat_id'] ?? '').toString();
    // chat_id 匹配：为空 / 当前存储长 id 包含 chat_id（微信 chat_id 是 session key 的一部分）
    final isCurrent =
        chatId.isEmpty || ((_currentStoredId ?? '').contains(chatId));
    if (!isCurrent) {
      _refreshSessions();
      return;
    }
    final storedId = _currentStoredId;
    if (storedId == null || storedId.isEmpty) return;
    final text = payload['text'] ?? ev.params['text'] ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (text is String && text.isNotEmpty) {
      // 防重复：2 秒内到达的相同 text 事件视为重复
      if (_lastExtText == text && now - _lastExtTs < 2000) return;
      _lastExtText = text;
      _lastExtTs = now;
      setState(() {
        _messages.add(
          ChatMessage(
            id: 'ext-$now',
            role: 'user',
            content: text,
            ts: DateTime.now(),
            local: true,
          ),
        );
      });
      _scrollToBottom(force: true);
    }
    if (!_streaming && !_busy) _refreshCurrentSession();
    _stopExternalDelayed();
    _externalDelayedTimer = Timer(const Duration(milliseconds: 1500), () {
      _externalDelayedTimer = null;
      if (_currentStoredId != storedId) return;
      _refreshCurrentSession();
    });
    _startExternalPoll(storedId);
  }

  /* ============ 会话 ============ */

  Future<void> _loadSessions() async {
    if (_sessionsLoaded) return;
    _sessionsLoaded = true;
    try {
      final data = await WsClient.instance.rpc('session.list');
      if (!mounted) return;
      final list = toSessions(data);
      setState(() => _sessions = list);
      if (list.isNotEmpty) {
        await _switchSession(list.first.storedId);
      } else {
        await _createSession();
      }
    } catch (e) {
      if (!mounted) return;
      _sessionsLoaded = false;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = '加载会话失败: ${e.toString()}');
    }
  }

  Future<void> _switchSession(String storedId) async {
    // 队列有未发送消息：提示切换将取消
    if (_queue.isNotEmpty) {
      final ok = await _confirm('提示', '有 ${_queue.length} 条消息排队中，切换会话将取消。确定切换？');
      if (!ok) return;
    }
    _saveDraft();
    _draftTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    // 当前会话正在生成时先中断，避免切走后回复仍写入旧会话
    if (_streaming && _currentId != null) {
      try {
        await WsClient.instance.rpc('session.interrupt', {'session_id': _currentId});
      } catch (_) {}
    }
    _stopExternalPoll();
    _stopExternalDelayed();
    _lastExtText = '';
    _lastExtTs = 0;
    setState(() {
      _streaming = false;
      _busy = false;
      _queue.clear();
      _drawerOpen = false;
      _stickToBottom = true;
    });
    final prevStoredId = _currentStoredId;
    _currentStoredId = storedId;
    // 本地新建未持久化会话：跳过 resume，直接用短 id 空会话
    final localShort = _localIdMap[storedId];
    if (localShort != null) {
      setState(() {
        _currentId = localShort;
        _messages.clear();
        _loading = false;
      });
      _restoreDraft();
      _scrollToBottom(force: true);
      return;
    }
    try {
      final data = await WsClient.instance.rpc('session.resume', {'session_id': storedId});
      if (!mounted || _currentStoredId != storedId) return;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final shortId = _strField(map, ['session_id', 'sessionId', 'resumed']);
      final msgs = toMessages(map != null ? (map['messages'] ?? data) : data);
      setState(() {
        _currentId = shortId.isNotEmpty ? shortId : storedId;
        _messages.clear();
        _messages.addAll(msgs);
        _loading = false;
      });
      _restoreDraft();
      _scrollToBottom(force: true);
    } catch (e) {
      if (!mounted) return;
      if (_currentStoredId != storedId) return;
      final fallbackShort = _localIdMap[storedId];
      if (fallbackShort != null) {
        setState(() {
          _currentId = fallbackShort;
          _messages.clear();
          _loading = false;
        });
        _restoreDraft();
        return;
      }
      // 恢复原会话高亮与消息，避免停留在失败会话的错误状态
      _currentStoredId = prevStoredId;
      setState(() {
        _loading = false;
        _error = '加载历史失败: ${e.toString()}';
      });
    }
  }

  Future<void> _createSession() async {
    _saveDraft();
    _draftTimer?.cancel();
    setState(() {
      _error = null;
      _drawerOpen = false;
      _loading = true;
      _streaming = false;
      _busy = false;
      _queue.clear();
      _stickToBottom = true;
      _lastExtText = '';
      _lastExtTs = 0;
    });
    try {
      final data = await WsClient.instance.rpc('session.create');
      if (!mounted) return;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final shortId = _strField(map, ['session_id', 'sessionId', 'id']);
      final storedId = _strField(map, ['session_key', 'stored_session_id']);
      final effectiveStored = storedId.isNotEmpty ? storedId : shortId;
      final list = await WsClient.instance.rpc('session.list');
      if (!mounted) return;
      final fresh = toSessions(list);
      final found = fresh.where((s) => s.storedId == effectiveStored).toList();
      final locals = _sessions.where((s) => s.local && !fresh.any((f) => f.storedId == s.storedId)).toList();
      setState(() {
        _sessions = [
          ...locals,
          if (found.isEmpty && effectiveStored.isNotEmpty)
            Session(effectiveStored, '新会话', local: true)
          else
            ...fresh,
        ];
        _currentStoredId = found.isNotEmpty ? found.first.storedId : (effectiveStored.isNotEmpty ? effectiveStored : null);
        _currentId = shortId.isNotEmpty ? shortId : _currentStoredId;
        _messages.clear();
        _loading = false;
      });
      if (storedId.isNotEmpty && shortId.isNotEmpty) {
        _localIdMap[storedId] = shortId;
      }
      _restoreDraft();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = '创建会话失败: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _refreshSessions() {
    final sid = _currentStoredId;
    if (sid == null) return;
    WsClient.instance.rpc('session.list').then((data) {
      if (!mounted || _currentStoredId != sid) return;
      final fresh = toSessions(data);
      final locals = _sessions
          .where((s) => s.local && !fresh.any((f) => f.storedId == s.storedId))
          .toList();
      final next = [
        ...locals,
        ...fresh,
      ].map((s) {
        final override = _titleOverrides[s.storedId];
        return override != null ? Session(s.storedId, override, local: s.local) : s;
      }).toList();
      final cur = _sessions;
      var same = cur.length == next.length;
      if (same) {
        for (var i = 0; i < cur.length; i++) {
          if (cur[i].storedId != next[i].storedId ||
              cur[i].title != next[i].title ||
              cur[i].local != next[i].local) {
            same = false;
            break;
          }
        }
      }
      if (same) return; // 与当前一致：跳过，避免多余渲染
      setState(() => _sessions = next);
    }).catchError((_) {});
  }

  void _refreshCurrentSession() {
    final storedId = _currentStoredId;
    if (storedId == null || storedId.isEmpty) return;
    _resumeCurrent(storedId);
  }

  Future<void> _resumeCurrent(
    String storedId, {
    void Function(dynamic data, List<ChatMessage> list)? onData,
  }) async {
    try {
      final data = await WsClient.instance.rpc('session.resume', {'session_id': storedId});
      if (!mounted || _currentStoredId != storedId) return;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final newId = _strField(map, ['session_id', 'sessionId', 'resumed']);
      final msgs = toMessages(map != null ? (map['messages'] ?? data) : data);
      setState(() {
        if (newId.isNotEmpty && newId != _currentId) _currentId = newId;
        _messages.clear();
        _messages.addAll(msgs);
      });
      onData?.call(data, msgs);
    } catch (_) {
      // 刷新失败静默
    }
  }

  void _startExternalPoll(String storedId) {
    _stopExternalPoll();
    _pollCount = 0;
    _externalPollTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (_pollCount >= 12 || _currentStoredId != storedId) {
        _stopExternalPoll();
        return;
      }
      _pollCount++;
      _resumeCurrent(storedId, onData: (data, list) {
        final rawArr = _arrayOf(data, 'messages');
        if (rawArr.isEmpty) return;
        final lastRaw = rawArr.last;
        final last = list.isEmpty ? null : list.last;
        final streamingMarked = lastRaw is Map &&
            (lastRaw['streaming'] == true ||
                lastRaw['is_streaming'] == true ||
                lastRaw['isStreaming'] == true ||
                lastRaw['status'] == 'streaming');
        // 最后一条已是 assistant 且无流式标记：回复已落定，停止轮询
        if (last != null && last.role == 'assistant' && !streamingMarked) {
          _stopExternalPoll();
        }
      });
    });
  }

  void _stopExternalPoll() {
    _externalPollTimer?.cancel();
    _externalPollTimer = null;
  }

  void _stopExternalDelayed() {
    _externalDelayedTimer?.cancel();
    _externalDelayedTimer = null;
  }

  String _strField(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return '';
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }

  /* ============ 发送 ============ */

  void _send() {
    final text = _input.text.trim();
    if ((text.isEmpty && _pendingImages.isEmpty && _pendingFiles.isEmpty) ||
        _currentId == null ||
        _currentId!.isEmpty) {
      return;
    }
    setState(() => _error = null);

    final sentImages = List<String>.of(_pendingImages);
    final validFiles = _pendingFiles.where((p) => p.isNotEmpty).toList();
    if (validFiles.length != _pendingFiles.length) _toast('部分文件路径无效，已跳过');
    // 文件以 @file:<绝对路径> 引用拼进 submit text
    final fileRefs = validFiles.map((p) => '@file:$p').join('\n');
    final submitText = fileRefs.isNotEmpty
        ? (text.isNotEmpty ? '$text\n$fileRefs' : fileRefs)
        : text;

    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: submitText,
      images: sentImages,
      ts: DateTime.now(),
      local: true,
    );
    setState(() {
      _messages.add(userMsg);
      _pendingImages.clear();
      _pendingFiles.clear();
    });
    _clearDraft();
    _stickToBottom = true;

    if (_streaming || _busy) {
      // 流式中（或已有提交在途）：入队，等待当前回复结束后自动发送（FIFO）
      setState(() => _queue.add(userMsg));
    } else {
      setState(() => _streaming = true);
      _submitPrompt(userMsg, _currentId!);
    }
    _scrollToBottom(force: true);
  }

  Future<void> _submitPrompt(ChatMessage userMsg, String sid) async {
    setState(() => _busy = true);
    var failed = false;
    try {
      // 发送前逐张 image.attach（prompt.submit 的 image_paths 网关忽略）
      try {
        for (final path in userMsg.images) {
          await WsClient.instance.rpc('image.attach', {'session_id': sid, 'path': path});
        }
      } catch (e) {
        throw WsException('图片附加失败: ${e.toString()}');
      }
      await WsClient.instance.rpc('prompt.submit', {
        'session_id': sid,
        'text': userMsg.content,
      });
    } catch (e) {
      if (_currentId == sid) {
        failed = true;
        if (mounted) {
          setState(() {
            _messages.add(
              ChatMessage(
                id: 'err-${DateTime.now().millisecondsSinceEpoch}',
                role: 'system',
                content: '发送失败: ${e.toString()}',
                ts: DateTime.now(),
              ),
            );
          });
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (failed) {
        _settleReply();
      } else {
        // 成功 ack：接管队列（ack 晚于 message.complete 时在此补一次 flush，避免队列卡死）
        _flushQueue();
      }
    }
  }

  void _flushQueue() {
    if (_busy || _streaming) return;
    if (_queue.isEmpty) return;
    final sid = _currentId;
    if (sid == null || sid.isEmpty) {
      _queue.clear();
      return;
    }
    final next = _queue.removeAt(0);
    setState(() => _streaming = true);
    _submitPrompt(next, sid);
  }

  void _settleReply() {
    if (mounted) setState(() => _streaming = false);
    _flushQueue();
  }

  Future<void> _interrupt() async {
    if (_currentId == null || _currentId!.isEmpty) return;
    setState(() => _streaming = false);
    try {
      await WsClient.instance.rpc('session.interrupt', {'session_id': _currentId});
    } catch (_) {}
    final n = _queue.length;
    if (n > 0) _toast('已中断，继续发送 $n 条排队消息');
    _flushQueue();
  }

  /* ============ 消息操作（复制/重新生成/编辑/删除） ============ */

  Future<void> _copyMessage(ChatMessage msg) async {
    final text = parseFileRefs(msg.content).text;
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制');
  }

  Future<void> _regenerate(ChatMessage msg) async {
    final idx = _messages.indexOf(msg);
    if (idx < 0) return;
    if (_streaming && _currentId != null) {
      try {
        await WsClient.instance.rpc('session.interrupt', {'session_id': _currentId});
      } catch (_) {}
    }
    setState(() {
      _streaming = false;
      _queue.clear();
      _messages.removeRange(idx, _messages.length);
    });
    ChatMessage? userMsg;
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        userMsg = _messages[i];
        break;
      }
    }
    if (userMsg == null) {
      _toast('未找到可重发的消息');
      return;
    }
    final sid = _currentId;
    if (sid == null || sid.isEmpty) return;
    setState(() => _streaming = true);
    _submitPrompt(
      userMsg.copyWith(
        id: 'local-${DateTime.now().millisecondsSinceEpoch}',
        ts: DateTime.now(),
      ),
      sid,
    );
  }

  Future<void> _edit(ChatMessage msg) async {
    final idx = _messages.indexOf(msg);
    if (idx < 0) return;
    if (_streaming && _currentId != null) {
      try {
        await WsClient.instance.rpc('session.interrupt', {'session_id': _currentId});
      } catch (_) {}
    }
    final parsed = parseFileRefs(msg.content);
    setState(() {
      _streaming = false;
      _queue.clear();
      _messages.removeRange(idx, _messages.length);
      _pendingImages.clear();
      _pendingImages.addAll(msg.images);
      _pendingFiles.clear();
      _pendingFiles.addAll(parsed.files.map((f) => f.path));
    });
    _input.text = parsed.text;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _inputFocus.requestFocus();
  }

  Future<void> _deleteMessage(ChatMessage msg) async {
    final ok = await _confirm(
      '删除消息',
      '删除此消息仅从当前视图移除（本地），不会影响服务器数据。确定删除？',
    );
    if (!ok) return;
    setState(() => _messages.remove(msg));
  }

  void _showMessageActions(ChatMessage msg) {
    final c = context.c;
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
            if (msg.role == 'assistant')
              ListTile(
                leading: const Icon(Icons.refresh, size: 20),
                title: const Text('重新生成'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _regenerate(msg);
                },
              ),
            if (msg.role == 'user')
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('编辑'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _edit(msg);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, size: 20, color: c.danger),
              title: Text('删除', style: TextStyle(color: c.danger)),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteMessage(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  /* ============ 会话操作（重命名/删除） ============ */

  Future<void> _renameSession(Session s) async {
    final controller = TextEditingController(text: s.title);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话标题'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) return; // 空值视为取消
    setState(() {
      _titleOverrides[s.storedId] = trimmed;
      _sessions = _sessions
          .map((x) => x.storedId == s.storedId ? Session(x.storedId, trimmed, local: x.local) : x)
          .toList();
    });
  }

  Future<void> _deleteSession(Session s) async {
    final ok = await _confirm(
      '删除会话',
      '删除会话「${s.title}」仅从当前视图移除（本地），不会影响服务器数据。确定删除？',
    );
    if (!ok) return;
    setState(() {
      _sessions.removeWhere((x) => x.storedId == s.storedId);
    });
    await _removeDraftFor(s.storedId);
    _localIdMap.remove(s.storedId);
    if (_currentStoredId == s.storedId) {
      final rest = _sessions.where((x) => x.storedId != s.storedId).toList();
      if (rest.isNotEmpty) {
        _switchSession(rest.first.storedId);
      } else {
        setState(() {
          _currentStoredId = null;
          _currentId = null;
          _messages.clear();
        });
        _input.clear();
      }
    }
  }

  /* ============ 草稿 ============ */

  String? get _draftKey => _currentStoredId ?? _currentId;

  void _onInputChanged() {
    setState(() {});
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), _saveDraft);
  }

  Future<void> _saveDraft() async {
    final key = _draftKey;
    if (key == null || key.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final val = _input.text;
    if (val.isNotEmpty) {
      await sp.setString('chat_draft_$key', val);
    } else {
      await sp.remove('chat_draft_$key');
    }
  }

  Future<void> _clearDraft() async {
    _draftTimer?.cancel();
    _input.clear();
    final key = _draftKey;
    if (key == null || key.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    await sp.remove('chat_draft_$key');
  }

  Future<void> _restoreDraft() async {
    final key = _draftKey;
    if (key == null || key.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final val = sp.getString('chat_draft_$key');
    if (!mounted) return;
    _input.text = val ?? '';
  }

  Future<void> _removeDraftFor(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('chat_draft_$key');
  }

  /* ============ 上传 / 下载 ============ */

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
      'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif',
    }.contains(ext);
  }

  Future<void> _upload(String path, String name, {required bool isImage}) async {
    try {
      final serverPath = await Api.upload(File(path), name);
      if (!mounted) return;
      setState(() {
        if (isImage) {
          _pendingImages.add(serverPath);
        } else {
          _pendingFiles.add(serverPath);
        }
      });
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存: ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _showError('下载失败: ${e.toString()}');
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

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(message, style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _copySessionId() {
    Clipboard.setData(ClipboardData(text: _currentStoredId ?? _currentId ?? ''));
    _toast('已复制');
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
    final wsReady = _wsStatus == WsStatus.ready;
    final title = _currentSessionTitle();
    return Stack(
      children: [
        Column(
          children: [
            _buildTopBar(c: c, wsReady: wsReady, title: title),
            const SizedBox(height: 6),
            if (!wsReady) _buildWsBanner(c),
            Expanded(child: _buildMessageList(c)),
            if (_pendingImages.isNotEmpty || _pendingFiles.isNotEmpty)
              _buildPendingBar(c),
            if (_streaming && _queue.isNotEmpty) _buildQueueBar(c),
            if (_error != null) _buildErrorBar(c),
            _buildComposer(c),
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
    if (_currentStoredId == null) return '新会话';
    for (final s in _sessions) {
      if (s.storedId == _currentStoredId) {
        return _titleOverrides[s.storedId] ?? s.title;
      }
    }
    return _currentStoredId!;
  }

  Widget _buildWsBanner(AppColors c) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.accentBorder),
      ),
      child: Text(
        _everReady ? '连接已断开，正在重连…' : '正在连接服务器…',
        style: TextStyle(color: c.accent, fontSize: 12),
      ),
    );
  }

  Widget _buildTopBar({
    required AppColors c,
    required bool wsReady,
    required String title,
  }) {
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    StatusDot(up: wsReady, size: 6),
                    const SizedBox(width: 5),
                    Text(
                      wsReady ? '已连接' : '连接中…',
                      style: TextStyle(color: c.muted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_streaming)
            IconButton(
              onPressed: _interrupt,
              icon: Icon(Icons.stop_circle_outlined, color: c.danger),
              tooltip: '中断生成',
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
                  '会话',
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : () {
                  setState(() => _drawerOpen = false);
                  _createSession();
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('＋ 新建会话'),
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
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () {
                            setState(() => _drawerOpen = false);
                            _switchSession(s.storedId);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 13,
                            ),
                            child: Text(
                              _titleOverrides[s.storedId] ?? s.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: active ? c.accent : c.fg,
                                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.more_vert,
                          size: 18,
                          color: active ? c.accent : c.muted,
                        ),
                        onSelected: (v) {
                          if (v == 'rename') _renameSession(s);
                          if (v == 'delete') _deleteSession(s);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('重命名', style: TextStyle(fontSize: 13)),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              '删除',
                              style: TextStyle(fontSize: 13, color: c.danger),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(AppColors c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, color: c.accent, size: 30),
            const SizedBox(height: 14),
            Text(
              '开始和 Hermes 对话吧',
              style: TextStyle(color: c.muted, fontSize: 14),
            ),
          ],
        ),
      );
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
        itemBuilder: (_, i) =>
            _buildBubble(c, _messages[i], isLast: i == _messages.length - 1),
      ),
    );
  }

  Widget _buildBubble(AppColors c, ChatMessage m, {required bool isLast}) {
    final isUser = m.role == 'user';
    final isSystem = m.role == 'system';
    final showCursor = _streaming && isLast && !isUser;

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

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: c.border),
            ),
            child: Text(
              m.content,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.danger, fontSize: 12.5),
            ),
          ),
        ),
      );
    }

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
                          : _buildMarkdown(c, displayText, showCursor)
                    else if (showCursor)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: _TypingCursor(),
                      ),
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

  Widget _buildMarkdown(AppColors c, String text, bool showCursor) {
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
    return Stack(
      children: [
        MarkdownBody(
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
        ),
        if (showCursor)
          Positioned(
            right: -2,
            bottom: 0,
            child: _TypingCursor(),
          ),
      ],
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

  Widget _buildPendingBar(AppColors c) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _pendingImages.length; i++)
            _pendingChip(
              c,
              name: _basename(_pendingImages[i]),
              isImage: true,
              onDelete: () => setState(() => _pendingImages.removeAt(i)),
            ),
          for (var i = 0; i < _pendingFiles.length; i++)
            _pendingChip(
              c,
              name: _basename(_pendingFiles[i]),
              isImage: false,
              onDelete: () => setState(() => _pendingFiles.removeAt(i)),
            ),
        ],
      ),
    );
  }

  String _basename(String path) {
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  Widget _pendingChip(
    AppColors c, {
    required String name,
    required bool isImage,
    required VoidCallback onDelete,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isImage ? Icons.image_outlined : Icons.attach_file,
            size: 14,
            color: c.muted,
          ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.fg, fontSize: 12),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onDelete,
            child: Icon(Icons.close, size: 13, color: c.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueBar(AppColors c) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Text(
        '回复生成中 · 还有 ${_queue.length} 条消息排队',
        style: TextStyle(color: c.muted, fontSize: 12),
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

  Widget _buildComposer(AppColors c) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 10),
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: _pickImage,
            icon: Icon(Icons.image_outlined, color: c.muted, size: 22),
            tooltip: '图片',
          ),
          IconButton(
            onPressed: _pickFile,
            icon: Icon(Icons.attach_file, color: c.muted, size: 22),
            tooltip: '文件',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 4,
                style: TextStyle(color: c.fg, fontSize: 15),
                onChanged: (_) => _onInputChanged(),
                decoration: InputDecoration(
                  hintText: _streaming
                      ? '回复生成中，可继续输入（将排队发送）'
                      : '输入消息…',
                  filled: true,
                  fillColor: c.surface2,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _streaming ? _stopButton(c) : _sendButton(c),
        ],
      ),
    );
  }

  Widget _sendButton(AppColors c) {
    return GestureDetector(
      onTap: _send,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: c.fg,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Icon(Icons.arrow_upward_rounded, color: c.bg, size: 24),
        ),
      ),
    );
  }

  Widget _stopButton(AppColors c) {
    return GestureDetector(
      onTap: _interrupt,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: c.danger),
        ),
        child: Center(
          child: Icon(Icons.stop_rounded, color: c.danger, size: 24),
        ),
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
    final c = context.c;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.15, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 2.4,
        height: 16,
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
