import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/notification_model.dart';

void main() {
  group('NotificationItem', () {
    test('解析基本字段，ts/readAt 为 epoch 秒', () {
      final item = NotificationItem.fromJson({
        'id': 7,
        'ts': 1700000000,
        'level': 'urgent',
        'source': 'admin-server',
        'title': '磁盘占用过高',
        'body': '根分区已用 92%',
        'link': 'https://example.com/disk',
        'readAt': null,
      });
      expect(item.id, 7);
      expect(item.ts, 1700000000);
      expect(item.level, 'urgent');
      expect(item.isUrgent, true);
      expect(item.isUnread, true);
      expect(item.body, '根分区已用 92%');
    });

    test('空字符串 body/link 归一为 null，兼容字符串数字', () {
      final item = NotificationItem.fromJson({
        'id': '8',
        'ts': '1700000001',
        'level': 'normal',
        'source': 'cron',
        'title': 't',
        'body': '',
        'link': '',
        'readAt': '1700000002',
      });
      expect(item.id, 8);
      expect(item.ts, 1700000001);
      expect(item.body, isNull);
      expect(item.link, isNull);
      expect(item.readAt, 1700000002);
      expect(item.isUnread, false);
      expect(item.isUrgent, false);
    });

    test('缺字段不抛，level 回退 normal', () {
      final item = NotificationItem.fromJson(const {});
      expect(item.id, 0);
      expect(item.ts, 0);
      expect(item.level, 'normal');
      expect(item.source, '');
      expect(item.title, '');
      expect(item.isUnread, true);
    });

    test('toJson 与 copyWith(readAt) 保持其它字段', () {
      final item = NotificationItem.fromJson({
        'id': 1,
        'ts': 1700000000,
        'level': 'normal',
        'source': 's',
        'title': 't',
        'body': 'b',
        'link': 'https://x',
        'readAt': null,
      });
      final read = item.copyWith(readAt: 1700000100);
      expect(read.readAt, 1700000100);
      expect(read.id, item.id);
      expect(read.body, 'b');
      expect(read.link, 'https://x');

      final json = read.toJson();
      expect(json['id'], 1);
      expect(json['readAt'], 1700000100);
      expect(json['link'], 'https://x');
    });
  });

  group('SseParser', () {
    test('忽略 retry 与注释帧，解析 event/data', () {
      final parser = SseParser();
      final frames = parser.feed(
        'retry: 5000\n\n: ping\n\nevent: heartbeat\ndata: {"ts":123}\n\n',
      );
      expect(frames.length, 1);
      expect(frames.first.event, 'heartbeat');
      expect(frames.first.json?['ts'], 123);
    });

    test('跨分块边界拼接（服务端分片到达）', () {
      final parser = SseParser();
      expect(parser.feed('event: notification\nda').length, 0);
      final frames = parser.feed(
        'ta: {"id":1}\n\nevent: heartbeat\ndata: {"ts":2}\n\n',
      );
      expect(frames.length, 2);
      expect(frames[0].event, 'notification');
      expect(frames[0].json?['id'], 1);
      expect(frames[1].event, 'heartbeat');
      expect(frames[1].json?['ts'], 2);
    });

    test('兼容 CRLF 换行', () {
      final parser = SseParser();
      final frames = parser.feed('event: heartbeat\r\ndata: {"ts":9}\r\n\r\n');
      expect(frames.length, 1);
      expect(frames.first.json?['ts'], 9);
    });

    test('data 非法 JSON 时 json 返回 null 而不抛', () {
      final parser = SseParser();
      final frames = parser.feed('event: notification\ndata: not-json\n\n');
      expect(frames.length, 1);
      expect(frames.first.json, isNull);
    });

    test('多行 data 以换行拼接', () {
      final frame = SseParser.parseFrame('event: x\ndata: a\ndata: b');
      expect(frame, isNotNull);
      expect(frame!.data, 'a\nb');
    });

    test('无 event 或空 data 的帧返回 null', () {
      expect(SseParser.parseFrame('data: {"ts":1}'), isNull);
      expect(SseParser.parseFrame('event: heartbeat'), isNull);
    });
  });

  group('重连退避与心跳超时', () {
    test('退避 1s→2s→…→上限 60s', () {
      expect(nextNotificationBackoff(const Duration(seconds: 1)).inSeconds, 2);
      expect(nextNotificationBackoff(const Duration(seconds: 2)).inSeconds, 4);
      expect(nextNotificationBackoff(const Duration(seconds: 40)).inSeconds, 60);
      expect(nextNotificationBackoff(const Duration(seconds: 60)).inSeconds, 60);
      expect(nextNotificationBackoff(Duration.zero).inSeconds, 2);
    });

    test('90 秒无事件判定连接已死', () {
      expect(notificationHeartbeatExpired(0, 1000), true);
      expect(notificationHeartbeatExpired(100, 150), false);
      expect(notificationHeartbeatExpired(100, 190), true);
      expect(notificationHeartbeatExpired(100, 200), true);
    });
  });

  group('通知级别', () {
    test('选项与后端 NOTIFICATION_LEVELS 一一对应', () {
      expect(kNotificationLevelOptions.map((e) => e.$1).toList(), [
        'urgent',
        'normal',
        'digest',
      ]);
    });

    test('级别中文名，未知回退「通知」', () {
      expect(notificationLevelLabel('urgent'), '紧急');
      expect(notificationLevelLabel('normal'), '常规');
      expect(notificationLevelLabel('digest'), '汇总');
      expect(notificationLevelLabel('other'), '通知');
    });
  });

  group('辅助函数', () {
    test('本地通知 id 收敛到 int31 正数', () {
      expect(notificationLocalId(1), 1);
      expect(notificationLocalId(0x80000001), 1);
      expect(notificationLocalId(0x7fffffff), 0x7fffffff);
    });

    test('相对时间文案（输入 epoch 秒）', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      expect(formatNotificationTime(null, now: now), '—');
      expect(formatNotificationTime(0, now: now), '—');
      expect(formatNotificationTime(1700000000 - 3, now: now), '刚刚');
      expect(formatNotificationTime(1700000000 - 30, now: now), '30 秒前');
      expect(formatNotificationTime(1700000000 - 120, now: now), '2 分钟前');
      expect(formatNotificationTime(1700000000 - 7200, now: now), '2 小时前');
      expect(formatNotificationTime(1700000000 - 172800, now: now), '2 天前');
      expect(
        formatNotificationTime(1700000000 - 86400 * 40, now: now),
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
      );
    });
  });
}
