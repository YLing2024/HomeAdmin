import 'notification_model.dart';

/// 通知列表的内存状态（纯逻辑，供通知展示页使用），便于单测。
///
/// 唯一的新增入口是 [applyPush]（服务器推送）与 [replaceAll] / [appendOlder]
/// （主动拉取）。**没有**「本地发送后插入」的入口——发送方禁止乐观更新。
class NotificationFeed {
  NotificationFeed({this.pageSize = 50});

  final int pageSize;
  final List<NotificationItem> items = [];

  /// 未读数；只随推送（[applyPush]）或主动拉取（[replaceAll]）变化。
  int unread = 0;
  bool hasMore = true;

  /// 主动拉取整页：替换列表并按服务端未读校正（服务端未给则本地统计）。
  void replaceAll(List<NotificationItem> list, int? serverUnread) {
    items
      ..clear()
      ..addAll(list);
    unread = serverUnread ?? items.where((x) => x.isUnread).length;
    hasMore = list.length >= pageSize;
  }

  /// 翻页追加（按 id 去重）。
  void appendOlder(List<NotificationItem> list) {
    for (final item in list) {
      if (items.every((x) => x.id != item.id)) items.add(item);
    }
    hasMore = list.length >= pageSize;
  }

  /// 服务器推送：置顶插入；同 id 视为同一条（去重更新，替换不重复计数）。
  /// 返回是否为新增条目。
  bool applyPush(NotificationItem item) {
    final index = items.indexWhere((x) => x.id == item.id);
    if (index != -1) {
      items[index] = item;
      return false;
    }
    items.insert(0, item);
    unread += 1;
    return true;
  }

  /// 标记单条已读（本地用户动作，允许就地更新）。
  void markRead(int id, int readAt) {
    final index = items.indexWhere((x) => x.id == id);
    if (index == -1 || !items[index].isUnread) return;
    items[index] = items[index].copyWith(readAt: readAt);
    if (unread > 0) unread -= 1;
  }

  /// 全部已读（本地用户动作，允许就地更新）。
  void markAllRead(int readAt) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].isUnread) items[i] = items[i].copyWith(readAt: readAt);
    }
    unread = 0;
  }
}
