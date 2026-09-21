import 'dart:math' as math;

import 'notification_model.dart';

/// 发通知后的「服务器推送等待」逻辑（纯函数 + 纯状态机，便于单测）。
///
/// 铁律（2026-09-21 需求）：新通知只能由服务器 SSE 推送进入列表；发送方
/// （通知管理页 / 调试页）在 POST 成功后一律不得本地插入、不得主动重拉来让这条
/// 出现——那会掩盖实时通道已断的事实。本文件只负责「观察推送是否到达」，
/// 与 admin-web `notificationPush.js` 同语义。
///
/// 为什么要历史缓冲：服务端先 broadcast 再回 HTTP 响应，SSE 帧完全可能在 POST
/// 的 await 恢复之前就已到达；等待开始时先查「本次发送之后」到达的推送，
/// 避免正常路径被误判为超时。

/// 等待服务器推送的最长时间；超过即判定实时通道可能断了。
const Duration kPushWaitTimeout = Duration(seconds: 10);

/// 最近推送缓冲窗口 / 上限（只用于等待匹配，与列表无关）。
const int kPushHistoryWindowMs = 15000;
const int kPushHistoryMax = 50;

/// 一条已到达的服务器推送（带到达时刻，毫秒）。
class NotificationPushRecord {
  const NotificationPushRecord({required this.item, required this.atMillis});

  final NotificationItem item;
  final int atMillis;
}

/// 等待匹配目标：优先按 POST 返回的 id 匹配，无 id 时退化为标题 + 来源
/// （SSE item 视图不含 dedupKey，故不参与匹配）。
class PushTarget {
  const PushTarget({
    this.id,
    this.title = '',
    this.source = '',
  });

  final int? id;
  final String title;
  final String source;
}

/// 判定一条推送是否为本次发送的目标（与 admin-web `pushMatches` 同语义）。
bool pushMatches(NotificationItem item, PushTarget target) {
  final id = target.id;
  if (id != null && id > 0) return item.id == id;
  if (target.title.isEmpty) return false;
  return item.title == target.title &&
      (target.source.isEmpty || item.source == target.source);
}

/// 等待阶段：等待中 / 已收到 / 超时。
enum PushPhase { waiting, received, timeout }

/// 一次等待的可展示状态。
class PushWaitState {
  const PushWaitState(this.phase, {this.elapsedMs});

  final PushPhase phase;

  /// 从「点击发送」到收到推送的耗时（仅 received 有值，毫秒）。
  final int? elapsedMs;

  bool get isWaiting => phase == PushPhase.waiting;
  bool get isReceived => phase == PushPhase.received;
  bool get isTimeout => phase == PushPhase.timeout;
}

/// 纯状态机：不持有 Timer、不依赖 Flutter，可单测。
class PushWaitTracker {
  PushWaitTracker(this.target, {required this.startedAtMillis});

  final PushTarget target;

  /// 「点击发送」时刻（毫秒），耗时以此为起点，端到端。
  final int startedAtMillis;

  PushWaitState _state = const PushWaitState(PushPhase.waiting);
  bool _done = false;

  PushWaitState get state => _state;

  /// 开始一轮新的等待。
  void markWaiting() {
    _state = const PushWaitState(PushPhase.waiting);
    _done = false;
  }

  /// 在推送历史里找本次目标：命中则置为 received（返回 true）。
  /// 可反复调用（POST 返回后一次，之后每收到推送一次），保证不漏。
  bool absorbHistory(Iterable<NotificationPushRecord> history) {
    if (_done) return _state.isReceived;
    NotificationPushRecord? earliest;
    for (final record in history) {
      if (record.atMillis < startedAtMillis) continue;
      if (!pushMatches(record.item, target)) continue;
      if (earliest == null || record.atMillis < earliest.atMillis) {
        earliest = record;
      }
    }
    if (earliest == null) return false;
    _state = PushWaitState(
      PushPhase.received,
      elapsedMs: math.max(0, earliest.atMillis - startedAtMillis),
    );
    _done = true;
    return true;
  }

  /// 超时：置为 timeout（不覆盖已收到的结果）。
  void markTimeout() {
    if (_done) return;
    _state = const PushWaitState(PushPhase.timeout);
    _done = true;
  }
}

/// 推送等待耗时文案（保留一位小数，如 `0.4s`）。
String formatPushElapsed(int? elapsedMs) {
  final ms = elapsedMs ?? 0;
  return '${(ms / 1000).toStringAsFixed(1)}s';
}
