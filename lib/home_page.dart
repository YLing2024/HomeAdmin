import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'chat_page.dart';
import 'login_page.dart';
import 'system_page.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _restoreTab();
  }

  Future<void> _restoreTab() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getString('admin_tab');
    if (!mounted) return;
    setState(() => _tab = saved == 'system' ? 1 : 0);
  }

  Future<void> _selectTab(int i) async {
    setState(() => _tab = i);
    final sp = await SharedPreferences.getInstance();
    await sp.setString('admin_tab', i == 0 ? 'chat' : 'system');
  }

  Future<void> _logout() async {
    await forceLogout();
  }

  Future<void> _openChangePassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('密码已修改，请重新登录')));
      await forceLogout();
    }
  }

  @override
  Widget build(BuildContext context) {
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
                        gradient: kAmberGradient,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.admin_panel_settings,
                        color: Colors.black,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Admin',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _openChangePassword,
                      tooltip: '修改密码',
                      icon: const Icon(Icons.key_outlined, color: kMuted),
                    ),
                    IconButton(
                      onPressed: _logout,
                      tooltip: '退出登录',
                      icon: const Icon(Icons.logout, color: kMuted),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: _tab == 0
                      ? const ChatPage(key: ValueKey('chat'))
                      : const SystemPage(key: ValueKey('system')),
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
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: '系统',
          ),
        ],
      ),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final oldP = _old.text.trim();
    final newP = _new.text.trim();
    final confirm = _confirm.text.trim();
    if (oldP.isEmpty || newP.isEmpty) {
      _toast('请填写完整');
      return;
    }
    if (newP.length < 6) {
      _toast('新密码至少 6 位');
      return;
    }
    if (newP != confirm) {
      _toast('两次输入的新密码不一致');
      return;
    }
    setState(() => _busy = true);
    try {
      await Api.changePassword(oldP, newP);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.key_outlined, color: kAmber, size: 22),
          SizedBox(width: 8),
          Text('修改密码', style: TextStyle(fontSize: 17)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _old,
            obscureText: true,
            decoration: const InputDecoration(hintText: '旧密码'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _new,
            obscureText: true,
            decoration: const InputDecoration(hintText: '新密码（至少 6 位）'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            onSubmitted: (_) => _busy ? null : _submit(),
            decoration: const InputDecoration(hintText: '确认新密码'),
          ),
          const SizedBox(height: 6),
          const Row(
            children: [
              Icon(Icons.info_outline, size: 13, color: kMuted),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  '修改后所有会话将失效，需要重新登录',
                  style: TextStyle(color: kMuted, fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确定'),
        ),
      ],
    );
  }
}
