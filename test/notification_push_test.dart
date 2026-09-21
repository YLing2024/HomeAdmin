import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/notification_feed.dart';
import 'package:home_admin/notification_model.dart';
import 'package:home_admin/notification_push.dart';

NotificationItem _item(
  int id, {
  String title = '测试通知',
  String source = 'admin',
  int ts = 1000,
  int? readAt,
}) {
  return NotificationItem(
    id: id,
    ts: ts,
    level: 'normal',
    source: source,
    title: title,
    readAt: readAt,
  );
}

void main() {
  group('pushMatches', () {
    test('优先按 id 匹配（标题不同也算命中）', () {
      final target = PushTarget(id: 7, title: '别的标题', source: 'admin');
      expect(pushMatches(_item(7, title: '实际标题'), target), true);
      expect(pushMatches(_item(8), target), false);
    });

    test('无 id 时退化为标题 + 来源', () {
      const target = PushTarget(title: '测试通知', source: 'admin');
      expect(pushMatches(_item(1, source: 'admin'), target), true);
      expect(pushMatches(_item(1, source: 'other'), target), false);
      expect(pushMatches(_item(1, title: '别的'), target), false);
    });

    test('无 id 且无标题时不匹配任何条目', () {
      expect(pushMatches(_item(1), const PushTarget()), false);
    });
  });

  group('PushWaitTracker', () {
    test('正常路径：开始后收到推送 → received 且耗时可算（< 1s）', () {
      final tracker = PushWaitTracker(
        const PushTarget(id: 42),
        startedAtMillis: 1000,
      )..markWaiting();
      expect(tracker.absorbHistory(const []), false);
      expect(tracker.state.isWaiting, true);

      final hit = tracker.absorbHistory([
        NotificationPushRecord(item: _item(42), atMillis: 1400),
      ]);
      expect(hit, true);
      expect(tracker.state.isReceived, true);
      expect(tracker.state.elapsedMs, 400);
      expect(formatPushElapsed(tracker.state.elapsedMs), '0.4s');
    });

    test('竞态补偿：推送在 POST 响应前到达（已进历史）也能命中', () {
      final tracker = PushWaitTracker(
        const PushTarget(id: 42),
        startedAtMillis: 1000,
      )..markWaiting();
      // 历史里有开始前的旧推送（应忽略）与开始后的目标推送（应命中）
      expect(
        tracker.absorbHistory([
          NotificationPushRecord(item: _item(42), atMillis: 900),
          NotificationPushRecord(item: _item(42), atMillis: 1200),
        ]),
        true,
      );
      expect(tracker.state.elapsedMs, 200);
    });

    test('断开路径：超时 → timeout，且后续到达不再改变结果', () {
      final tracker = PushWaitTracker(
        const PushTarget(id: 42),
        startedAtMillis: 1000,
      )..markWaiting();
      expect(tracker.absorbHistory(const []), false);
      tracker.markTimeout();
      expect(tracker.state.isTimeout, true);
      expect(tracker.state.elapsedMs, null);
      // 超时后才补到推送：不覆盖失败结果（诚实反映链路断过）
      expect(
        tracker.absorbHistory([
          NotificationPushRecord(item: _item(42), atMillis: 2000),
        ]),
        false,
      );
      expect(tracker.state.isTimeout, true);
    });

    test('已收到后超时定时器触发也不覆盖 received', () {
      final tracker = PushWaitTracker(
        const PushTarget(id: 42),
        startedAtMillis: 1000,
      )..markWaiting();
      tracker.absorbHistory([
        NotificationPushRecord(item: _item(42), atMillis: 1100),
      ]);
      tracker.markTimeout();
      expect(tracker.state.isReceived, true);
      expect(tracker.state.elapsedMs, 100);
    });

    test('不相关推送不命中，仍保持 waiting', () {
      final tracker = PushWaitTracker(
        const PushTarget(id: 42),
        startedAtMillis: 1000,
      )..markWaiting();
      expect(
        tracker.absorbHistory([
          NotificationPushRecord(item: _item(99), atMillis: 1200),
        ]),
        false,
      );
      expect(tracker.state.isWaiting, true);
    });
  });

  group('NotificationFeed（禁止乐观更新）', () {
    test('发送后未收到推送：列表保持为空、未读不 +1', () {
      final feed = NotificationFeed();
      // 模拟「POST 已成功、服务器已入库」但推送还没到：不做任何本地插入
      feed.replaceAll(const [], 0);
      expect(feed.items, isEmpty);
      expect(feed.unread, 0);
    });

    test('收到服务器推送：置顶插入并让未读 +1', () {
      final feed = NotificationFeed();
      expect(feed.applyPush(_item(1)), true);
      expect(feed.items.single.id, 1);
      expect(feed.unread, 1);
    });

    test('同 id 推送视为去重更新：不重复、不重复计数', () {
      final feed = NotificationFeed();
      feed.applyPush(_item(1));
      final changed = feed.applyPush(_item(1, title: '更新后的标题'));
      expect(changed, false);
      expect(feed.items.length, 1);
      expect(feed.items.single.title, '更新后的标题');
      expect(feed.unread, 1);
    });

    test('断开后「重新拉取」能从服务端恢复这条（证明写入成功）', () {
      final feed = NotificationFeed();
      feed.replaceAll(const [], 0);
      expect(feed.items, isEmpty);
      // 用户点「重新拉取列表」→ 服务端返回该条
      feed.replaceAll([_item(5)], 1);
      expect(feed.items.single.id, 5);
      expect(feed.unread, 1);
    });

    test('翻页追加按 id 去重', () {
      final feed = NotificationFeed(pageSize: 2);
      feed.replaceAll([_item(3), _item(2)], 2);
      feed.appendOlder([_item(2), _item(1)]);
      expect(feed.items.map((x) => x.id).toList(), [3, 2, 1]);
      expect(feed.hasMore, true);
    });

    test('单条已读 / 全部已读就地更新（允许的本地动作）', () {
      final feed = NotificationFeed();
      feed.replaceAll([_item(2), _item(1)], 2);
      feed.markRead(2, 1234);
      expect(feed.items.first.readAt, 1234);
      expect(feed.unread, 1);
      feed.markAllRead(2000);
      expect(feed.unread, 0);
      expect(feed.items.every((x) => !x.isUnread), true);
    });
  });
}
