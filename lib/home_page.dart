import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'blog_page.dart';
import 'command_palette.dart';
import 'files_page.dart';
import 'login_page.dart';
import 'manage_page.dart';
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

  @override
  void initState() {
    super.initState();
    _restoreTab();
    // 全局 Ctrl/Cmd+K 命令面板（对齐 Web）
    HardwareKeyboard.instance.addHandler(_onKey);
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
    // 顺序与 Web 对齐：系统 / 版本 / 博客 / 管理 / 终端 / 文件
    final map = {
      'system': 0,
      'version': 1,
      'blog': 2,
      'manage': 3,
      'terminal': 4,
      'files': 5,
    };
    setState(() => _tab = map[saved] ?? 0);
  }

  Future<void> _selectTab(int i) async {
    setState(() => _tab = i);
    final sp = await SharedPreferences.getInstance();
    const names = ['system', 'version', 'blog', 'manage', 'terminal', 'files'];
    await sp.setString('admin_tab', names[i]);
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
      body: GlowBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
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
                // IndexedStack：六个面板常驻挂载，切换不销毁各自状态
                child: IndexedStack(
                  index: _tab,
                  children: [
                    SystemPage(active: _tab == 0, key: const ValueKey('system')),
                    const VersionPage(key: ValueKey('version')),
                    const BlogPage(key: ValueKey('blog')),
                    const ManagePage(key: ValueKey('manage')),
                    TerminalPage(active: _tab == 4, key: const ValueKey('terminal')),
                    FilesPage(active: _tab == 5, key: const ValueKey('files')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: '系统',
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            selectedIcon: Icon(Icons.article),
            label: '版本',
          ),
          NavigationDestination(
            icon: Icon(Icons.edit_note),
            selectedIcon: Icon(Icons.edit_note),
            label: '博客',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '管理',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: '终端',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '文件',
          ),
        ],
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
