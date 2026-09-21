import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/api.dart';
import 'package:home_admin/debug_tools.dart';

void main() {
  group('buildNotificationPayload', () {
    test('必填字段齐全，来源固定 admin-debug', () {
      final p = buildNotificationPayload(level: 'normal', title: ' 测试 ');
      expect(p, {
        'level': 'normal',
        'source': 'admin-debug',
        'title': '测试',
      });
    });

    test('可选字段非空才下发并去空白', () {
      final p = buildNotificationPayload(
        level: 'urgent',
        title: '标题',
        body: '  正文  ',
        link: '',
        dedupKey: ' k1 ',
      );
      expect(p['body'], '正文');
      expect(p['dedupKey'], 'k1');
      expect(p.containsKey('link'), false);
    });

    test('纯空白可选字段不下发', () {
      final p = buildNotificationPayload(
        level: 'digest',
        title: 'x',
        body: '   ',
        link: '  ',
        dedupKey: ' ',
      );
      expect(p.containsKey('body'), false);
      expect(p.containsKey('link'), false);
      expect(p.containsKey('dedupKey'), false);
    });
  });

  group('notificationExampleJson', () {
    test('是合法 JSON、来源为 admin-debug 且带缩进', () {
      final text = notificationExampleJson();
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      expect(decoded['source'], 'admin-debug');
      expect(decoded['level'], 'normal');
      expect(decoded['title'], '测试通知');
      expect(text.contains('\n'), true);
    });
  });

  group('notificationConnectionLabel', () {
    test('服务未运行 → 未启动', () {
      expect(
        notificationConnectionLabel(
          running: false,
          lastHeartbeatEpochSeconds: 0,
          nowEpochSeconds: 1000,
        ),
        '未启动',
      );
    });

    test('运行中且心跳新鲜（< 90s）→ 已连接', () {
      expect(
        notificationConnectionLabel(
          running: true,
          lastHeartbeatEpochSeconds: 1000,
          nowEpochSeconds: 1010,
        ),
        '已连接',
      );
    });

    test('运行中心跳超时 → 重连中', () {
      expect(
        notificationConnectionLabel(
          running: true,
          lastHeartbeatEpochSeconds: 1000,
          nowEpochSeconds: 1100,
        ),
        '重连中',
      );
    });

    test('运行中从未收到心跳 → 重连中', () {
      expect(
        notificationConnectionLabel(
          running: true,
          lastHeartbeatEpochSeconds: 0,
          nowEpochSeconds: 1100,
        ),
        '重连中',
      );
    });
  });

  group('truncateDebugText', () {
    test('超长截断并追加省略号', () {
      final out = truncateDebugText('a' * 700);
      expect(out.length, kDebugResponseTruncate + 1);
      expect(out.endsWith('…'), true);
    });

    test('未超长原样返回', () {
      expect(truncateDebugText('ok'), 'ok');
      expect(truncateDebugText('a' * kDebugResponseTruncate).length,
          kDebugResponseTruncate);
    });
  });

  group('notificationEndpoint', () {
    test('用 kApiBase 拼出，不硬编码域名', () {
      expect(notificationEndpoint(), '$kApiBase/api/admin/notifications');
    });
  });
}
