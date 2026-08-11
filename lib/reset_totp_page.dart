import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'login_page.dart';
import 'theme.dart';

/// TOTP 验证器重置（两阶段，对齐 Web 端 ResetTotp）：
/// 1. 确认 → 调 /api/admin/totp/reset 生成 pending secret（5 分钟有效，旧码不受影响）
/// 2. 展示 QR + otpauth URI → 输入新验证器生成的验证码 → /api/admin/totp/confirm 转正
Future<void> showResetTotp(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const ResetTotpDialog(),
  );
}

class ResetTotpDialog extends StatefulWidget {
  const ResetTotpDialog({super.key});

  @override
  State<ResetTotpDialog> createState() => _ResetTotpDialogState();
}

class _ResetTotpDialogState extends State<ResetTotpDialog> {
  String? _uri;
  String? _error;
  bool _loading = false;
  bool _copied = false;
  final _code = TextEditingController();
  final _focus = FocusNode();
  String? _success;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _startReset() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Api.totpReset();
      if (!mounted) return;
      setState(() => _uri = (data['otpauthUri'] as String?) ?? '');
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyUri() async {
    final uri = _uri;
    if (uri == null || uri.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: uri));
      if (!mounted) return;
      setState(() => _copied = true);
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) setState(() => _copied = false);
    } catch (_) {
      if (mounted) setState(() => _error = '复制失败，请手动复制 URI');
    }
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = '请输入 6 位数字验证码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Api.totpResetConfirm(code);
      if (!mounted) return;
      setState(() => _success = '验证器已重置');
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = '验证码错误，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _close() {
    if (_loading) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final uri = _uri;

    return AlertDialog(
      title: Text(
        uri == null ? '重置验证器' : '重置验证器 · 绑定新验证码',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: c.fg,
          letterSpacing: 0.5,
        ),
      ),
      content: SizedBox(
        width: 340,
        child: uri == null ? _buildConfirmStep(c) : _buildBindStep(c),
      ),
      actions: [
        if (uri == null)
          TextButton(
            onPressed: _loading ? null : _close,
            child: const Text('取消'),
          )
        else
          TextButton(
            onPressed: _loading ? null : _close,
            child: const Text('取消'),
          ),
        if (uri == null)
          TextButton(
            onPressed: _loading ? null : _startReset,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('确认重置'),
          )
        else
          TextButton(
            onPressed: _loading ? null : _confirm,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('提交'),
          ),
      ],
    );
  }

  Widget _buildConfirmStep(AppColors c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '确定重置验证器？当前验证码将立即失效。',
          style: TextStyle(color: c.fg, fontSize: 13, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildBindStep(AppColors c) {
    final uri = _uri;
    final uriText = uri ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '在身份验证器中添加下方条目，然后输入 App 生成的新验证码完成确认。',
          style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 14),
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: QrImageView(
              data: uriText,
              size: 180,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: c.bg,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            uriText.isNotEmpty ? uriText : '（未获取到 otpauth URI）',
            style: TextStyle(
              color: c.muted,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _copied || uriText.isEmpty ? null : _copyUri,
            icon: const Icon(Icons.copy, size: 14),
            label: Text(_copied ? '已复制' : '复制 URI'),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _code,
          focusNode: _focus,
          autofocus: true,
          enabled: !_loading,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onSubmitted: (_) => _loading ? null : _confirm(),
          decoration: const InputDecoration(hintText: '输入 App 新验证码'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        if (_success != null) ...[
          const SizedBox(height: 8),
          Text(_success!, style: TextStyle(color: c.ok, fontSize: 12)),
        ],
      ],
    );
  }
}
