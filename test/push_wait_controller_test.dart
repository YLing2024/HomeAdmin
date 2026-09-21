import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/notification_model.dart';
import 'package:home_admin/notification_push.dart';
import 'package:home_admin/notification_store.dart';
import 'package:home_admin/push_wait_result.dart';

/// 这些用例直接驱动**生产代码** [PushWaitController] + [NotificationStore] 的推送总线，
/// 模拟前台服务 isolate 经 `sendDataToMain` 送达的服务器推送，覆盖正常 / 断开两条路径。
NotificationItem _item(int id, {String title = '测试通知'}) {
  return NotificationItem(
    id: id,
    ts: 1700000000,
    level: 'normal',
    source: 'admin',
    title: title,
  );
}

Map<String, dynamic> _pushData(int id, {String title = '测试通知', int unread = 1}) {
  return {
    'type': 'notification',
    'item': _item(id, title: title).toJson(),
    'unread': unread,
    'ts': 1700000000,
  };
}

void main() {
  setUp(() {
    NotificationStore.recentPushes.clear();
    NotificationStore.incoming.value = null;
    NotificationStore.unread.value = 0;
  });

  testWidgets('正常路径：提交后 1 秒内收到推送 → received', (tester) async {
    final controller = PushWaitController();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    controller.begin(
      const PushTarget(id: 101, title: '测试通知', source: 'admin'),
      startedAtMillis: startedAt,
    );
    expect(controller.state?.isWaiting, true);

    // 前台服务 isolate 收到 SSE 推的这条，转发到主 isolate
    NotificationStore.applyTaskData(_pushData(101));
    await tester.pump();

    expect(controller.state?.isReceived, true);
    expect(controller.state!.elapsedMs! < 1000, true);
    expect(formatPushElapsed(controller.state!.elapsedMs), startsWith('0.'));
    controller.dispose();
  });

  testWidgets('竞态：推送早于 POST 响应到达（历史缓冲）也判定 received', (tester) async {
    // 先到推送，再调用 begin（对应「broadcast 早于 HTTP 响应」）
    NotificationStore.applyTaskData(_pushData(202));
    final controller = PushWaitController();
    controller.begin(
      const PushTarget(id: 202),
      startedAtMillis: DateTime.now().millisecondsSinceEpoch - 5,
    );
    expect(controller.state?.isReceived, true);
    controller.dispose();
  });

  testWidgets('断开路径：10 秒内无推送 → timeout（不乐观插入）', (tester) async {
    final controller = PushWaitController();
    controller.begin(
      const PushTarget(id: 303, title: '断链测试', source: 'admin'),
      startedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    expect(controller.state?.isWaiting, true);

    await tester.pump(kPushWaitTimeout);

    expect(controller.state?.isTimeout, true);
    expect(controller.state?.elapsedMs, null);
    controller.dispose();
  });

  testWidgets('断开路径：超时后才到达的推送不覆盖失败结果', (tester) async {
    final controller = PushWaitController();
    controller.begin(
      const PushTarget(id: 404),
      startedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await tester.pump(kPushWaitTimeout);
    expect(controller.state?.isTimeout, true);

    NotificationStore.applyTaskData(_pushData(404));
    await tester.pump();
    expect(controller.state?.isTimeout, true);
    controller.dispose();
  });
}
