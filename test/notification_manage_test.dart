import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/notification_manage.dart';

void main() {
  group('bulkDeleteBody', () {
    test('无筛选 = 全部删除（空对象）', () {
      expect(bulkDeleteBody(), <String, dynamic>{});
    });

    test('只带非空筛选，dryRun 可选', () {
      expect(
        bulkDeleteBody(level: 'urgent', source: 'admin', unreadOnly: true),
        {'level': 'urgent', 'source': 'admin', 'unreadOnly': true},
      );
      expect(
        bulkDeleteBody(readOnly: true, dryRun: true),
        {'readOnly': true, 'dryRun': true},
      );
    });

    test('空字符串筛选不下发', () {
      expect(bulkDeleteBody(level: '', source: '  '), <String, dynamic>{});
    });
  });

  group('describeBulkScope', () {
    test('无筛选为空串（即全部）', () {
      expect(describeBulkScope(), '');
    });

    test('拼出级别 / 来源 / 未读', () {
      expect(
        describeBulkScope(level: 'urgent', source: 'admin', unreadOnly: true),
        '（级别 紧急 · 来源 admin · 仅未读）',
      );
    });

    test('仅已读', () {
      expect(describeBulkScope(readOnly: true), '（仅已读）');
    });
  });

  group('notificationStatsLine', () {
    test('共 N 条 · 未读 M · 来源 K 个', () {
      expect(
        notificationStatsLine(total: 12, unread: 3, sourceCount: 4),
        '共 12 条 · 未读 3 · 来源 4 个',
      );
    });
  });

  group('topNotificationSources', () {
    test('只保留前 N 个并收敛类型', () {
      final out = topNotificationSources([
        {'source': 'a', 'count': 5},
        {'source': 'b', 'count': '3'},
        {'source': 'c', 'count': 2},
        {'source': 'd', 'count': 1},
        {'source': 'e', 'count': 0},
        {'source': 'f', 'count': 9},
      ]);
      expect(out.length, 5);
      expect(out.first, {'source': 'a', 'count': 5});
      expect(out[1], {'source': 'b', 'count': 3});
    });

    test('跳过无 source 的脏数据', () {
      final out = topNotificationSources([
        {'count': 5},
        'oops',
        {'source': 'ok', 'count': 1},
      ]);
      expect(out, [
        {'source': 'ok', 'count': 1},
      ]);
    });
  });

  group('notificationLevelLabel', () {
    test('已知级别中文名，未知回退「通知」', () {
      expect(notificationLevelLabel('urgent'), '紧急');
      expect(notificationLevelLabel('normal'), '常规');
      expect(notificationLevelLabel('digest'), '汇总');
      expect(notificationLevelLabel('other'), '通知');
    });
  });
}
