import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/notification_model.dart';
import 'package:home_admin/notification_type_filter.dart';

/// 通知类别（type）泛化：类别由服务端定义，客户端不内置清单。
void main() {
  group('NotificationType 解析', () {
    test('解析 key/label 与 enabled=1', () {
      final t = NotificationType.fromJson(const {
        'key': 'watchdog',
        'label': '看门狗',
        'description': '看门狗告警',
        'defaultLevel': 'urgent',
        'sort': 10,
        'enabled': 1,
        'count': 3,
        'unread': 1,
      });
      expect(t.key, 'watchdog');
      expect(t.label, '看门狗');
      expect(t.defaultLevel, 'urgent');
      expect(t.sort, 10);
      expect(t.enabled, true);
      expect(t.count, 3);
      expect(t.unread, 1);
      expect(t.displayLabel, '看门狗');
    });

    test('enabled 兼容 0 / false / 字符串，缺省视为启用', () {
      expect(
        NotificationType.fromJson(const {'key': 'a', 'enabled': 0}).enabled,
        false,
      );
      expect(
        NotificationType.fromJson(const {'key': 'a', 'enabled': false}).enabled,
        false,
      );
      expect(
        NotificationType.fromJson(const {'key': 'a', 'enabled': '0'}).enabled,
        false,
      );
      expect(
        NotificationType.fromJson(const {'key': 'a'}).enabled,
        true,
      );
    });

    test('label 为空回退 key', () {
      final t = NotificationType.fromJson(const {'key': 'cron'});
      expect(t.displayLabel, 'cron');
    });
  });

  group('筛选选项：只来自服务端，客户端不写死类别', () {
    test('enabled 的类别按服务端顺序进入下拉，停用被排除', () {
      final options = notificationTypeFilterOptions(const [
        NotificationType(key: 'watchdog', label: '看门狗'),
        NotificationType(key: 'monitor', label: '站点监控'),
        NotificationType(key: 'old', label: '已停用', enabled: false),
      ]);
      expect(options, [
        ('', '全部类别'),
        ('watchdog', '看门狗'),
        ('monitor', '站点监控'),
      ]);
      expect(options.any((o) => o.$1 == 'old'), false);
    });

    test('服务端新类别（未在客户端出现过的 newbie-probe）自动出现', () {
      // 桩数据：模拟服务端写入 type=newbie-probe 后自动注册、接口返回。
      final serverTypes = [
        NotificationType.fromJson(const {
          'key': 'newbie-probe',
          'label': '新兵探针',
          'enabled': 1,
        }),
      ];
      final options = notificationTypeFilterOptions(serverTypes);
      expect(options.contains(('newbie-probe', '新兵探针')), true);
    });

    test('类别接口失败（空列表）→ 只剩「全部类别」', () {
      expect(notificationTypeFilterOptions(const []), [('', '全部类别')]);
    });
  });

  group('类别展示名：服务端 label 优先，取不到回退原始 key', () {
    test('命中 label', () {
      expect(
        notificationTypeLabel('watchdog', const [
          NotificationType(key: 'watchdog', label: '看门狗'),
        ]),
        '看门狗',
      );
    });

    test('未命中或 label 为空回退 key；停用类别仍能显示名字', () {
      expect(notificationTypeLabel('ghost', const []), 'ghost');
      expect(
        notificationTypeLabel('cron', const [
          NotificationType(key: 'cron', label: ''),
        ]),
        'cron',
      );
      expect(
        notificationTypeLabel('old', const [
          NotificationType(key: 'old', label: '旧类别', enabled: false),
        ]),
        '旧类别',
      );
    });

    test('NotificationItem.category：无 type 时回退 source（兼容老数据）', () {
      final legacy = NotificationItem.fromJson(const {
        'id': 1,
        'source': 'admin-server',
        'title': 't',
      });
      expect(legacy.type, '');
      expect(legacy.category, 'admin-server');

      final typed = NotificationItem.fromJson(const {
        'id': 2,
        'source': 'admin-server',
        'type': 'watchdog',
        'title': 't',
      });
      expect(typed.category, 'watchdog');
    });
  });

  group('NotificationTypeFilter（widget）', () {
    Widget wrap(List<NotificationType> types, {ValueChanged<String>? onChanged}) {
      return MaterialApp(
        home: Scaffold(
          body: NotificationTypeFilter(
            types: types,
            value: '',
            onChanged: onChanged ?? (_) {},
          ),
        ),
      );
    }

    testWidgets('用服务端返回的假类别动态渲染选项', (tester) async {
      await tester.pumpWidget(wrap(const [
        NotificationType(key: 'newbie-probe', label: '新兵探针'),
      ]));
      expect(find.text('全部类别'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('新兵探针'), findsOneWidget);
    });

    testWidgets('选中类别回调返回服务端 key', (tester) async {
      String selected = '';
      await tester.pumpWidget(wrap(
        const [NotificationType(key: 'monitor', label: '站点监控')],
        onChanged: (v) => selected = v,
      ));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('站点监控').last);
      await tester.pumpAndSettle();
      expect(selected, 'monitor');
    });

    testWidgets('停用类别不进筛选器', (tester) async {
      await tester.pumpWidget(wrap(const [
        NotificationType(key: 'old', label: '已停用', enabled: false),
      ]));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('已停用'), findsNothing);
    });

    testWidgets('接口失败（空列表）降级为只有「全部类别」', (tester) async {
      await tester.pumpWidget(wrap(const []));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      // 菜单里只有「全部类别」一项（选中态 + 菜单项各一处）
      expect(find.text('全部类别'), findsNWidgets(2));
    });
  });
}
