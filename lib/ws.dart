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
  type; // message.start / message.delta / message.complete / message.error
  final String? sessionId;
  final Map<String, dynamic> payload;
  final Map<String, dynamic> params;

  WsEvent(this.type, this.sessionId, this.payload, this.params);
}

enum WsStatus { connecting, ready, disconnected }

/// WebSocket JSON-RPC 2.0 行帧客户端
///  - 请求:   { jsonrpc:'2.0', id, method, params }
///  - 响应:   { jsonrpc, id, result } / { jsonrpc, id, error }
///  - 事件:   { method:'event', params:{ type, session_id, payload } }
class WsClient {
  WsClient._();

  static final WsClient instance = WsClient._();

  static const _wsUrl = 'wss://zhangyunling.cn/api/admin/ws';

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final Map<int, Completer<dynamic>> _pending = {};
  int _nextId = 1;
  bool _closing = false;
  bool _reconnectScheduled = false;

  final _events = StreamController<WsEvent>.broadcast();
  Stream<WsEvent> get events => _events.stream;

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
    _sub?.cancel();
    _sub = null;
    final ch = _channel;
    _channel = null;
    try {
      await ch?.sink.close();
    } catch (_) {}
    status.value = WsStatus.disconnected;
  }

  void _onData(dynamic raw) {
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
        _events.add(WsEvent(type, sessionId, payload, params));
      }
      return;
    }

    final id = map['id'];
    if (id is int && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      final err = map['error'];
      if (err is Map) {
        c.completeError(WsException((err['message'] as String?) ?? 'RPC 错误'));
      } else {
        c.complete(map['result']);
      }
    }
  }

  void _onDone() {
    final closeCode = _channel?.closeCode;
    final hadChannel = _channel != null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
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

  void _scheduleReconnect() {
    if (_closing || _reconnectScheduled) return;
    _reconnectScheduled = true;
    Timer(const Duration(seconds: 2), () {
      _reconnectScheduled = false;
      if (_closing) return;
      connect().catchError((_) {});
    });
  }
}
