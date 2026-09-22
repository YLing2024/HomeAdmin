import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/notification_detail_page.dart';
import 'package:home_admin/notification_model.dart';
import 'package:home_admin/notification_summary.dart';

/// >200 字正文，含换行——用于「列表摘要截断 vs 详情页全文」的对比断言。
final String longBody = List.generate(
  30,
  (i) => '第 ${i + 1} 行：这是一条用于验证详情页完整显示的通知正文，'
      '含中文与标点，用于超过两百字的对比断言。',
).join('\n');

NotificationItem _item({
  int id = 1,
  String level = 'urgent',
  String source = 'admin-server',
  String type = 'watchdog',
  String title = '磁盘占用过高',
  String? body,
  String? link,
  int? readAt,
  int ts = 1700000000,
}) {
  return NotificationItem(
    id: id,
    ts: ts,
    level: level,
    source: source,
    title: title,
    type: type,
    body: body,
    link: link,
    readAt: readAt,
  );
}

const List<NotificationType> _types = [
  NotificationType(key: 'watchdog', label: '看门狗'),
];

/// 从一个宿主页面 push 详情页，便于捕获 pop 回来的 [NotificationDetailAction]。
Future<void> _pumpHost(
  WidgetTester tester,
  NotificationDetailPage page,
  void Function(NotificationDetailAction?) onPopped,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () {
              Navigator.of(context)
                  .push<NotificationDetailAction>(
                    MaterialPageRoute(builder: (_) => page),
                  )
                  .then(onPopped);
            },
            child: const Text('打开详情'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('formatNotificationFullTime', () {
    test('epoch 秒 → 本地 YYYY-MM-DD HH:mm:ss', () {
      final epoch =
          DateTime(2026, 9, 22, 8, 5, 7).millisecondsSinceEpoch ~/ 1000;
      expect(formatNotificationFullTime(epoch), '2026-09-22 08:05:07');
    });

    test('无效输入回退 —', () {
      expect(formatNotificationFullTime(null), '—');
      expect(formatNotificationFullTime(0), '—');
    });
  });

  group('列表摘要 vs 详情页全文（>200 字）', () {
    testWidgets('列表摘要 3 行截断 + 省略号；详情页无截断、保留换行', (tester) async {
      expect(longBody.length, greaterThan(200));

      // 列表摘要：数据仍是全文，但视觉上截断到 3 行。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NotificationBodySummary(longBody)),
        ),
      );
      final summary = tester.widget<Text>(
        find.descendant(
          of: find.byType(NotificationBodySummary),
          matching: find.byType(Text),
        ),
      );
      expect(summary.data, longBody);
      expect(summary.maxLines, 3);
      expect(summary.overflow, TextOverflow.ellipsis);

      // 详情页：同一份正文完整渲染，不设 maxLines。
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationDetailPage(
            item: _item(body: longBody),
            types: _types,
            onMarkRead: (_) async => true,
            onDelete: (_) async => true,
          ),
        ),
      );
      final detail = tester.widget<Text>(
        find.byKey(kNotificationDetailBodyKey),
      );
      expect(detail.data, longBody);
      expect(detail.data!.contains('\n'), true);
      expect(detail.maxLines, isNull);
    });
  });

  group('详情页渲染', () {
    testWidgets('显示类别 label / 级别 / 来源 / 完整时间 / 链接', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationDetailPage(
            item: _item(
              body: longBody,
              link: 'https://example.com/detail',
            ),
            types: _types,
            onMarkRead: (_) async => true,
            onDelete: (_) async => true,
            onOpenLink: (_) async => true,
          ),
        ),
      );

      expect(find.text('通知详情'), findsOneWidget);
      expect(find.text('看门狗'), findsNWidgets(2)); // 顶部类别 + 元信息
      expect(find.text('紧急'), findsWidgets); // 级别 badge + 元信息
      expect(find.text('admin-server'), findsOneWidget);
      expect(
        find.text(formatNotificationFullTime(1700000000)),
        findsOneWidget,
      );
      expect(find.text('https://example.com/detail'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '打开链接'), findsOneWidget);
    });

    testWidgets('已读条目不提供「标记已读」', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationDetailPage(
            item: _item(readAt: 1700000100),
            types: _types,
            onMarkRead: (_) async => true,
            onDelete: (_) async => true,
          ),
        ),
      );
      expect(find.text('已读'), findsOneWidget);
      expect(find.text('标记已读'), findsNothing);
    });
  });

  group('详情页操作', () {
    testWidgets('标记已读：调用回调并带结果返回列表', (tester) async {
      final calls = <NotificationItem>[];
      NotificationDetailAction? popped;
      await _pumpHost(
        tester,
        NotificationDetailPage(
          item: _item(body: '正文'),
          types: _types,
          onMarkRead: (it) async {
            calls.add(it);
            return true;
          },
          onDelete: (_) async => false,
        ),
        (v) => popped = v,
      );

      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.text('通知详情'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, '标记已读'));
      await tester.pumpAndSettle();

      expect(calls.length, 1);
      expect(calls.single.id, 1);
      expect(find.text('通知详情'), findsNothing);
      expect(popped, NotificationDetailAction.markedRead);
    });

    testWidgets('删除：取消不调用；确认后调用并返回', (tester) async {
      var deleted = 0;
      NotificationDetailAction? popped;
      await _pumpHost(
        tester,
        NotificationDetailPage(
          item: _item(body: '正文'),
          types: _types,
          onMarkRead: (_) async => false,
          onDelete: (_) async {
            deleted += 1;
            return true;
          },
        ),
        (v) => popped = v,
      );

      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();

      // 第一次：打开二次确认后取消 → 不删、留在详情页。
      await tester.tap(find.widgetWithText(OutlinedButton, '删除'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(deleted, 0);
      expect(find.text('通知详情'), findsOneWidget);

      // 第二次：确认删除 → 调用回调并返回列表。
      await tester.tap(find.widgetWithText(OutlinedButton, '删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(deleted, 1);
      expect(find.text('通知详情'), findsNothing);
      expect(popped, NotificationDetailAction.deleted);
    });

    testWidgets('回调失败时留在详情页', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationDetailPage(
            item: _item(body: '正文'),
            types: _types,
            onMarkRead: (_) async => false,
            onDelete: (_) async => false,
          ),
        ),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, '标记已读'));
      await tester.pumpAndSettle();

      expect(find.text('通知详情'), findsOneWidget);
      expect(find.text('标记已读失败'), findsOneWidget); // toast
    });
  });
}
