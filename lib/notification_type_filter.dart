import 'package:flutter/material.dart';

import 'notification_model.dart';
import 'theme.dart';

/// 通知类别筛选下拉：选项**完全来自服务端**（[types]），客户端不内置任何类别。
///
/// - 只展示 enabled 的类别（由 [notificationTypeFilterOptions] 过滤）；
/// - 接口失败时传空 [types] → 只剩「全部类别」，筛选器降级但不阻塞列表；
/// - 选中值为类别 key，空串表示「全部」。
class NotificationTypeFilter extends StatelessWidget {
  const NotificationTypeFilter({
    super.key,
    required this.types,
    required this.value,
    required this.onChanged,
    this.width = 132,
  });

  /// 服务端返回的全部类别（含已停用，用于历史通知显示名字时另查）。
  final List<NotificationType> types;

  /// 当前选中类别 key；空串为「全部」。
  final String value;

  final ValueChanged<String> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final options = notificationTypeFilterOptions(types);
    // 选中值不在选项里（类别被停用 / 接口失败后值丢失）→ 落回「全部」，
    // 否则 DropdownButton 会因 value 无对应 item 抛断言。
    final safeValue = options.any((o) => o.$1 == value) ? value : '';
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safeValue,
          isExpanded: true,
          isDense: true,
          dropdownColor: c.surface,
          style: TextStyle(color: c.fg, fontSize: 13),
          icon: Icon(Icons.arrow_drop_down, size: 18, color: c.muted),
          items: [
            for (final (v, label) in options)
              DropdownMenuItem(
                value: v,
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }
}
