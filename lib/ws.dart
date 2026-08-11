import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'api.dart';

class WsException implements Exception {
  final String message;
  WsException(this.message);
  @override
  String toString() => message;
}

/// 网关事件：{ method:'event', params:{ type, session_id, payload } }
class WsEvent {
  final String
  type; // gateway.ready / message.start / message.delta / message.complete / message.error / sessions.changed / admin.external_message
  final String? sessionId;
  final Map<String, dynamic> payload;
  final Map<String, dynamic> params;

  WsEvent(this.type, this.sessionId, this.payload, this.params);
}

enum WsStatus { connecting, ready, disconnected }

/// WebSocket JSON-RPC 2.0 客户端（对齐 Web 端 ws.js）
///  - 心跳保活：每 25s 发 JSON-RPC ping，10s 无回包或距上次收到帧超 60s 判定死亡重连
///  - 指数退避重连：2s → 4s → 8s → 16s → 30s 封顶
///  - 事件缓冲：无订阅者时缓存（最多 500），订阅时回放
///  - 服务端 4001 关闭 = 凭证失效 → 通知全局登出
class WsClient {
  WsClient._();

  static final WsClient instance = WsClient._();

  static const _wsUrl = 'wss://zhangyunling.cn/api/admin/ws';

  static const _heartbeatInterval = Duration(seconds: 25);
  static const _heartbeatTimeout = Duration(seconds: 10);
  static const _staleLimit = Duration(seconds: 60);
  static const _reconnectBase = Duration(seconds: 2);
  static const _reconnectMax = Duration(seconds: 30);

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final Map<int, Completer<dynamic>> _pending = {};
  final List<WsEvent> _buffer = [];
  int _nextId = 1;
  bool _closing = false;
  bool _reconnectScheduled = false;
  Duration _reconnectDelay = _reconnectBase;

  Timer? _heartbeatTimer;
  Timer? _pingTimer;
  DateTime _lastMessageAt = DateTime.now();

  final _events = StreamController<WsEvent>.broadcast();
  Stream<WsEvent> get events => _events.stream;
  bool get _hasListeners => _events.hasListener;

  /// 鉴权失效回调（服务端以 4001 关闭时），由 main 注册为全局登出
  Future<void> Function()? onAuthRequired;

  final ValueNotifier<WsStatus> status = ValueNotifier<WsStatus>(
    WsStatus.disconnected,
  );

  bool get isConnected => _channel != null;

  /// 建立连接（幂等）。失败抛 WsException。
  Future<void> connect() async {
    if (_channel != null) return;
    _closing = false;
    status.value = WsStatus.connecting;

    final uri = Uri.parse('$_wsUrl?token=${Uri.encodeComponent(Api.token)}');
    final channel = IOWebSocketChannel.connect(
      uri,
      connectTimeout: const Duration(seconds: 15),
    );
    try {
      await channel.ready;
    } catch (e) {
      status.value = WsStatus.disconnected;
      _scheduleReconnect();
      throw WsException('WebSocket 连接失败');
    }
    if (_closing) {
      channel.sink.close();
      return;
    }
    _channel = channel;
    _lastMessageAt = DateTime.now();
    _startHeartbeat();
    _sub = channel.stream.listen(
      _onData,
      onDone: _onDone,
      onError: (_) => _onDone(),
    );
    status.value = WsStatus.ready;
  }

  /// JSON-RPC 请求，返回 result
  Future<dynamic> rpc(String method, [Map<String, dynamic>? params]) async {
    if (_channel == null) await connect();
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;

    final frame = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params ?? {},
    };
    _channel!.sink.add(jsonEncode(frame));

    final timer = Timer(const Duration(seconds: 60), () {
      _pending.remove(id);
      if (!completer.isCompleted) completer.completeError(WsException('请求超时'));
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  /// 主动关闭（退出登录时调用）
  Future<void> close() async {
    _closing = true;
    _reconnectScheduled = false;
    _stopHeartbeat();
    _sub?.cancel();
    _sub = null;
    final ch = _channel;
    _channel = null;
    try {
      await ch?.sink.close();
    } catch (_) {}
    status.value = WsStatus.disconnected;
  }

  /* ============ 心跳 ============ */

  void _startHeartbeat() {
    _stopHeartbeat();
    _lastMessageAt = DateTime.now();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _sendHeartbeat() {
    if (_channel == null) return;
    if (DateTime.now().difference(_lastMessageAt) > _staleLimit) {
      // 距上次收到任意帧已超限：半开连接，主动断开交给 onDone 重连
      _channel?.sink.close();
      return;
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _pingTimer?.cancel();
    _pingTimer = Timer(_heartbeatTimeout, () {
      // 心跳 RPC 超时无回包（网关对未知方法也会回 error，有回包即活着）→ 判定死亡
      _pending.remove(id);
      if (!completer.isCompleted) completer.completeError(WsException('心跳超时'));
      _channel?.sink.close();
    });
    try {
      _channel!.sink.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'ping',
        'params': const <String, dynamic>{},
      }));
    } catch (_) {
      _pending.remove(id);
      _pingTimer?.cancel();
    }
    completer.future.catchError((_) {}); // 心跳响应不向调用方抛出
  }

  /* ============ 重连 ============ */

  void _scheduleReconnect() {
    if (_closing || _reconnectScheduled) return;
    _reconnectScheduled = true;
    final delay = _reconnectDelay;
    _reconnectDelay = _reconnectDelay * 2 > _reconnectMax
        ? _reconnectMax
        : _reconnectDelay * 2;
    Timer(delay, () {
      _reconnectScheduled = false;
      if (_closing) return;
      connect().then((_) {
        _reconnectDelay = _reconnectBase; // 重连成功：退避重置
      }).catchError((_) {});
    });
  }

  /* ============ 消息处理 ============ */

  void _onData(dynamic raw) {
    _lastMessageAt = DateTime.now();
    dynamic msg;
    try {
      msg = jsonDecode(raw as String);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    final map = Map<String, dynamic>.from(msg);

    final method = map['method'];
    if (method != null) {
      if (method == 'event') {
        final p = map['params'];
        final params = (p is Map)
            ? Map<String, dynamic>.from(p)
            : <String, dynamic>{};
        final type = (params['type'] as String?) ?? '';
        final sessionId = params['session_id'] as String?;
        final pl = params['payload'];
        final payload = (pl is Map)
            ? Map<String, dynamic>.from(pl)
            : <String, dynamic>{};
        final ev = WsEvent(type, sessionId, payload, params);
        if (_hasListeners) {
          _events.add(ev);
        } else {
          _buffer.add(ev);
          if (_buffer.length > 500) _buffer.removeAt(0);
        }
      }
      return;
    }

    final id = map['id'];
    if (id is int && _pending.containsKey(id)) {
      _pingTimer?.cancel();
      final c = _pending.remove(id)!;
      final err = map['error'];
      if (err is Map) {
        c.completeError(WsException((err['message'] as String?) ?? 'RPC 错误'));
      } else {
        c.complete(map['result']);
      }
    }
  }

  /// 订阅事件流：先回放缓冲事件
  StreamSubscription<WsEvent> onEvent(void Function(WsEvent) fn) {
    final sub = _events.stream.listen(fn);
    if (_buffer.isNotEmpty) {
      final buf = List<WsEvent>.from(_buffer);
      _buffer.clear();
      for (final ev in buf) {
        fn(ev);
      }
    }
    return sub;
  }

  void _onDone() {
    final closeCode = _channel?.closeCode;
    final hadChannel = _channel != null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _stopHeartbeat();
    status.value = WsStatus.disconnected;

    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(WsException('连接已断开'));
    }
    _pending.clear();

    if (!_closing && hadChannel) {
      if (closeCode == 4001) {
        // 鉴权失败：停止重连，通知全局登出
        _closing = true;
        final cb = onAuthRequired;
        if (cb != null) unawaited(cb());
      } else {
        _scheduleReconnect();
      }
    }
  }
}
