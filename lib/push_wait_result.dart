import 'dart:async';

import 'package:flutter/material.dart';

import 'notification_push.dart';
import 'notification_store.dart';
import 'theme.dart';

/// 发通知后的推送等待控制器：把纯状态机 [PushWaitTracker] 接到
/// [NotificationStore] 的推送事件与 10 秒超时定时器上。
///
/// 发送方（通知管理页 / 调试页）在 POST 成功后 begin 一次；
/// 期间不做任何本地插入、不刷新未读/统计，只等服务器 SSE 推送。
class PushWaitController extends ChangeNotifier {
  PushWaitState? _state;
  PushWaitTracker? _tracker;
  Timer? _timer;
  VoidCallback? _onPush;

  PushWaitState? get state => _state;

  /// 开始等待；[startedAtMillis] 传「点击发送」时刻以计端到端耗时。
  void begin(PushTarget target, {required int startedAtMillis}) {
    clear();
    final tracker = PushWaitTracker(target, startedAtMillis: startedAtMillis);
    tracker.markWaiting();
    _tracker = tracker;

    // 推送可能已在 POST 响应前到达：先查历史，命中直接算收到。
    if (tracker.absorbHistory(NotificationStore.recentPushes)) {
      _state = tracker.state;
      notifyListeners();
      return;
    }

    void onPush() {
      final current = _tracker;
      if (current == null) return;
      // 每次推送到达都重扫历史，避免连续推送时漏掉目标。
      if (current.absorbHistory(NotificationStore.recentPushes)) {
        _state = current.state;
        _detach();
        _cancelTimer();
        notifyListeners();
      }
    }

    _onPush = onPush;
    NotificationStore.incoming.addListener(onPush);
    _timer = Timer(kPushWaitTimeout, () {
      final current = _tracker;
      if (current == null) return;
      current.markTimeout();
      _state = current.state;
      _detach();
      notifyListeners();
    });
    _state = tracker.state;
    notifyListeners();
  }

  /// 清空等待状态（不通知监听者；由调用方按需 notifyListeners）。
  void clear() {
    _detach();
    _cancelTimer();
    _tracker = null;
    _state = null;
  }

  /// 复位到无结果（下一次发送前调用）。
  void reset() {
    clear();
    notifyListeners();
  }

  void _detach() {
    final listener = _onPush;
    if (listener != null) {
      NotificationStore.incoming.removeListener(listener);
      _onPush = null;
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _detach();
    _cancelTimer();
    super.dispose();
  }
}

/// 推送等待结果行（调试页 / 通知管理页共用）：
///   等待 → 已提交到服务器，等待推送…（带转圈）
///   到达 → ✓ 已收到服务器推送（x.xs）
///   超时 → ✗ 10 秒内未收到推送 —— 实时通道可能断了（附「重新拉取列表」）
/// 结果由父组件保留，直到下一次发送才清空。
class PushWaitResult extends StatelessWidget {
  const PushWaitResult({
    super.key,
    required this.state,
    required this.onRepull,
    this.repulled = false,
  });

  final PushWaitState? state;
  final VoidCallback onRepull;

  /// 超时后是否已点过「重新拉取列表」。
  final bool repulled;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s == null) return const SizedBox.shrink();
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.isWaiting)
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.muted,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '已提交到服务器，等待推送…',
                  style: TextStyle(color: c.fg, fontSize: 13),
                ),
              ],
            )
          else if (s.isReceived)
            Text(
              '✓ 已收到服务器推送（${formatPushElapsed(s.elapsedMs)}）',
              style: TextStyle(
                color: c.ok,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '✗ 10 秒内未收到推送 —— 实时通道可能断了',
                        style: TextStyle(
                          color: c.danger,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: onRepull,
                      child: Text(
                        '重新拉取列表',
                        style: TextStyle(color: c.accent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
                if (repulled)
                  Text(
                    '已重新拉取列表',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
