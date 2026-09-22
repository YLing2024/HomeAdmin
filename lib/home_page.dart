import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'blog_page.dart';
import 'command_palette.dart';
import 'debug_page.dart';
import 'files_page.dart';
import 'hermes_page.dart';
import 'login_page.dart';
import 'manage_page.dart';
import 'notification_service.dart';
import 'notification_store.dart';
import 'notifications_page.dart';
import 'reset_totp_page.dart';
import 'system_page.dart';
import 'terminal_page.dart';
import 'theme.dart';
import 'version_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  bool _cmdOpen = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _restoreTab();
    _initNotifications();
    // 全局 Ctrl/Cmd+K 命令面板（对齐 Web）
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// 主页挂载即恢复通知状态并确保前台服务在跑；由本地通知冷启动则直达通知页。
  Future<void> _initNotifications() async {
    onOpenNotifications = () {
      if (mounted) _selectTab(6);
    };
    final launched = await NotificationService.launchedFromNotification();
    await NotificationStore.syncFromService();
    await NotificationService.ensureStarted();
    if (launched && mounted) await _selectTab(6);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isK = event.logicalKey == LogicalKeyboardKey.keyK ||
        event.logicalKey == LogicalKeyboardKey.keyK;
    if (isK && (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed)) {
      _openCommandPalette();
      return true;
    }
    return false;
  }

  Future<void> _restoreTab() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getString('admin_tab');
    if (!mounted) return;
    // 顺序与 Web 对齐：系统 / 版本 / 博客 / 管理 / 终端 / 文件 / 通知 / 调试 / Hermes
    final map = {
      'system': 0,
      'version': 1,
      'blog': 2,
      'manage': 3,
      'terminal': 4,
      'files': 5,
      'notifications': 6,
      'debug': 7,
      'hermes': 8,
    };
    setState(() => _tab = map[saved] ?? 0);
  }

  Future<void> _selectTab(int i) async {
    if (!mounted) return;
    setState(() => _tab = i);
    final sp = await SharedPreferences.getInstance();
    const names = [
      'system',
      'version',
      'blog',
      'manage',
      'terminal',
      'files',
      'notifications',
      'debug',
      'hermes',
    ];
    await sp.setString('admin_tab', names[i]);
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _openCommandPalette() {
    if (_cmdOpen) return;
    setState(() => _cmdOpen = true);
    CommandPaletteDialog.show(
      context,
      onSwitchTab: (i) => _selectTab(i),
      onShowReset: () => showResetTotp(context),
      onLogout: _logout,
    ).whenComplete(() {
      if (mounted) setState(() => _cmdOpen = false);
    });
  }

  Future<void> _logout() async {
    await forceLogout();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      key: _scaffoldKey,
      body: GlowBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _openDrawer,
                      tooltip: '导航菜单',
                      // 未读 > 0 时在主界面即能看到角标（不必打开抽屉）
                      icon: ValueListenableBuilder<int>(
                        valueListenable: NotificationStore.unread,
                        builder: (context, unread, _) => unread > 0
                            ? Badge(
                                label: Text(unread > 99 ? '99+' : '$unread'),
                                backgroundColor: c.accent,
                                textColor: c.bg,
                                child: Icon(Icons.menu, color: c.muted),
                              )
                            : Icon(Icons.menu, color: c.muted),
                      ),
                    ),
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.fg,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.admin_panel_settings,
                        color: c.bg,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Admin',
                      style: TextStyle(
                        color: c.fg,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _openCommandPalette,
                      tooltip: '命令面板 (Ctrl+K)',
                      icon: Icon(Icons.search, color: c.muted),
                    ),
                    _UserMenu(
                      onToggleTheme: () => ThemePrefs.toggle(),
                      onShowReset: () => showResetTotp(context),
                      onLogout: _logout,
                    ),
                  ],
                ),
              ),
              Expanded(
                // IndexedStack：面板常驻挂载，切换不销毁各自状态
                child: IndexedStack(
                  index: _tab,
                  children: [
                    SystemPage(active: _tab == 0, key: const ValueKey('system')),
                    const VersionPage(key: ValueKey('version')),
                    const BlogPage(key: ValueKey('blog')),
                    const ManagePage(key: ValueKey('manage')),
                    TerminalPage(active: _tab == 4, key: const ValueKey('terminal')),
                    FilesPage(active: _tab == 5, key: const ValueKey('files')),
                    NotificationsPage(
                      active: _tab == 6,
                      key: const ValueKey('notifications'),
                    ),
                    DebugPage(active: _tab == 7, key: const ValueKey('debug')),
                    HermesPage(active: _tab == 8, key: const ValueKey('hermes')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      drawer: HomeDrawer(
        current: _tab,
        onSelect: _selectTab,
        onClose: () => _scaffoldKey.currentState?.closeDrawer(),
      ),
    );
  }
}

/// 侧栏导航条目（文字与顺序 = 原底部 NavigationBar，一字不改；仅末尾追加 Hermes）
class HomeNavItem {
  const HomeNavItem(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 抽屉条目顺序（与 `_restoreTab` / `_selectTab` / IndexedStack 下标一一对应）。
/// 末尾「Hermes」为追加项，其余顺序与语义一律不动。
const List<HomeNavItem> homeNavItems = [
  HomeNavItem('系统', Icons.monitor_heart_outlined, Icons.monitor_heart),
  HomeNavItem('版本', Icons.article_outlined, Icons.article),
  HomeNavItem('博客', Icons.edit_note, Icons.edit_note),
  HomeNavItem('管理', Icons.settings_outlined, Icons.settings),
  HomeNavItem('终端', Icons.terminal_outlined, Icons.terminal),
  HomeNavItem('文件', Icons.folder_outlined, Icons.folder),
  HomeNavItem('通知', Icons.notifications_outlined, Icons.notifications),
  HomeNavItem('调试', Icons.bug_report_outlined, Icons.bug_report),
  HomeNavItem('Hermes', Icons.hub_outlined, Icons.hub),
];

/// 左侧抽屉：纵向列出全部导航条目；选中项用琥珀色 + 轻微底色。
class HomeDrawer extends StatelessWidget {
  const HomeDrawer({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onClose,
  });

  final int current;
  final void Function(int index) onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Drawer(
      backgroundColor: c.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      // 直角 + 发丝线，沿用 theme.dart 的设计语言
      shape: RoundedRectangleBorder(side: BorderSide(color: c.border)),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.fg,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      Icons.admin_panel_settings,
                      color: c.bg,
                      size: 15,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Admin',
                    style: TextStyle(
                      color: c.fg,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: NotificationStore.unread,
                builder: (context, unread, _) => ListView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: [
                    for (var i = 0; i < homeNavItems.length; i++)
                      _DrawerNavTile(
                        item: homeNavItems[i],
                        selected: i == current,
                        // 仅「通知」项展示未读数字
                        badge: i == 6 ? unread : 0,
                        onTap: () {
                          // 先关闭抽屉，再切换面板
                          onClose();
                          onSelect(i);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerNavTile extends StatelessWidget {
  const _DrawerNavTile({
    required this.item,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  final HomeNavItem item;
  final bool selected;
  final VoidCallback onTap;

  /// >0 时在右侧显示未读数字（仅通知项使用）
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: Ink(
        height: 48,
        color: selected ? c.accentSoft : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(
              selected ? item.selectedIcon : item.icon,
              size: 20,
              color: selected ? c.accent : c.muted,
            ),
            const SizedBox(width: 14),
            Text(
              item.label,
              style: TextStyle(
                color: selected ? c.accent : c.muted,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: 0.5,
              ),
            ),
            const Spacer(),
            if (badge > 0)
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  border: Border.all(color: c.accentBorder),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: TextStyle(color: c.accent, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 用户菜单：主题切换 / 重置验证器 / 退出登录（对齐 Web user-dropdown）
class _UserMenu extends StatefulWidget {
  const _UserMenu({
    required this.onToggleTheme,
    required this.onShowReset,
    required this.onLogout,
  });

  final VoidCallback onToggleTheme;
  final VoidCallback onShowReset;
  final VoidCallback onLogout;

  @override
  State<_UserMenu> createState() => _UserMenuState();
}

class _UserMenuState extends State<_UserMenu> {
  bool _open = false;

  void _close() => setState(() => _open = false);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isDark = context.isDark;
    return PopupMenuButton<String>(
      offset: const Offset(0, 44),
      color: c.surface,
      onOpened: () => setState(() => _open = true),
      onCanceled: _close,
      onSelected: (v) {
        setState(() => _open = false);
        switch (v) {
          case 'theme':
            widget.onToggleTheme();
          case 'reset':
            widget.onShowReset();
          case 'logout':
            widget.onLogout();
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'theme',
          child: Row(
            children: [
              Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 18, color: c.muted),
              const SizedBox(width: 10),
              Text(isDark ? '浅色主题' : '深色主题', style: TextStyle(color: c.fg, fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'reset',
          child: Row(
            children: [
              Icon(Icons.qr_code, size: 18, color: c.muted),
              const SizedBox(width: 10),
              Text('重置验证器', style: TextStyle(color: c.fg, fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout, size: 18, color: c.danger),
              const SizedBox(width: 10),
              Text('退出登录', style: TextStyle(color: c.danger, fontSize: 13)),
            ],
          ),
        ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(
            color: _open ? c.accent : c.border,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.ok,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Admin',
              style: TextStyle(color: c.fg, fontSize: 13),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 16, color: c.muted),
          ],
        ),
      ),
    );
  }
}
