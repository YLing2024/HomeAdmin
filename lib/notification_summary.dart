import 'package:flutter/material.dart';

/// 列表用的通知正文摘要：最多 [maxLines] 行截断 + 省略号。
///
/// 摘要只截断**显示**，不改动底层数据（数据库与接口返回的仍是全文）；
/// 想看全文请点条目进详情页。详情页不经过本组件。
class NotificationBodySummary extends StatelessWidget {
  const NotificationBodySummary(
    this.body, {
    super.key,
    this.maxLines = 3,
    this.style,
  });

  final String body;
  final int maxLines;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) return const SizedBox.shrink();
    return Text(
      body,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}
