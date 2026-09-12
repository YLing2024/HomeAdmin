import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/* ============ 命令注册表（对齐 Web 端 commandActions.js） ============ */

final Map<String, void Function()> _actions = {};

/// 注册命令动作，返回注销函数
void Function() registerAction(String name, void Function() fn) {
  _actions[name] = fn;
  return () => _actions.remove(name);
}

/// 执行命令动作（未注册则忽略）
void runAction(String name) {
  _actions[name]?.call();
}

/// 命令面板条目
class PaletteItem {
  final String id;
  final String label;
  final String hint;
  final void Function() run;
  const PaletteItem(this.id, this.label, this.hint, this.run);
}

/// 命令面板（对齐 Web 端 CommandPalette：Ctrl+K 唤起，↑↓ 选择，Enter 执行）
class CommandPaletteDialog extends StatefulWidget {
  const CommandPaletteDialog({
    super.key,
    required this.onSwitchTab,
    required this.onShowReset,
    required this.onLogout,
  });

  final void Function(int tab) onSwitchTab;
  final void Function() onShowReset;
  final void Function() onLogout;

  static Future<void> show(
    BuildContext context, {
    required void Function(int tab) onSwitchTab,
    required void Function() onShowReset,
    required void Function() onLogout,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => CommandPaletteDialog(
        onSwitchTab: onSwitchTab,
        onShowReset: onShowReset,
        onLogout: onLogout,
      ),
    );
  }

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final FocusNode _focus = FocusNode();
  int _sel = 0;
  final ScrollController _scroll = ScrollController();
  late final List<PaletteItem> _items = _buildItems();

  List<PaletteItem> _buildItems() {
    return [
      PaletteItem('system', '跳到系统页', '打开系统监控', () => widget.onSwitchTab(1)),
      PaletteItem('version', '跳到版本页', '查看软件版本', () => widget.onSwitchTab(2)),
      PaletteItem('blog', '跳到博客页', '管理博客文章', () => widget.onSwitchTab(3)),
      PaletteItem('manage', '跳到管理页', '设备与接口令牌', () => widget.onSwitchTab(4)),
      PaletteItem('terminal', '打开终端', '服务器 Web 终端', () => widget.onSwitchTab(5)),
      PaletteItem('browse', '跳到浏览页', '查看历史会话', () => widget.onSwitchTab(0)),
      PaletteItem('pwd', '重置验证器', '更换 TOTP 验证器', widget.onShowReset),
      PaletteItem('logout', '退出登录', '安全退出', widget.onLogout),
    ];
  }

  void _run(PaletteItem item) {
    Navigator.of(context).pop();
    // 先关闭再执行，避免键盘/弹层冲突（与 Web 一致）
    WidgetsBinding.instance.addPostFrameCallback((_) => item.run());
  }

  void _move(int delta) {
    setState(() {
      _sel = (_sel + delta + _items.length) % _items.length;
    });
    _scrollSelectedIntoView();
  }

  void _scrollSelectedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      const itemExtent = 44.0;
      final target = _sel * itemExtent;
      if (target < _scroll.offset) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      } else if (target + itemExtent > _scroll.offset + _scroll.position.viewportDimension) {
        _scroll.animateTo(
          target + itemExtent - _scroll.position.viewportDimension,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (isEnter) {
      _run(_items[_sel]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: 24,
        vertical: MediaQuery.sizeOf(context).height * 0.12,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 420),
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    Text(
                      '命令面板',
                      style: TextStyle(
                        color: c.fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.8,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.border),
                        color: c.surface2,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Ctrl + K',
                        style: TextStyle(
                          color: c.muted,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemExtent: 44,
                  itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final item = _items[i];
                    final selected = i == _sel;
                    return InkWell(
                      onTap: () => _run(item),
                      onHover: (_) => setState(() => _sel = i),
                      child: Container(
                        color: selected ? c.surface2 : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  color: selected ? c.accent : c.fg,
                                  fontSize: 13,
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ),
                            Text(
                              item.hint,
                              style: TextStyle(color: c.muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  '↑↓ 选择 · Enter 执行 · Esc 关闭',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
