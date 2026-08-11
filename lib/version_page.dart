import 'package:flutter/material.dart';

import 'api.dart';
import 'login_page.dart';
import 'theme.dart';

/// 软件版本页（对齐 Web 端 VersionPanel）：
/// 进入页面加载一次，不做轮询（避免重复执行 alist version 等重命令）
class VersionPage extends StatefulWidget {
  const VersionPage({super.key});

  @override
  State<VersionPage> createState() => _VersionPageState();
}

class _VersionPageState extends State<VersionPage> {
  List<Map<String, dynamic>>? _list;
  String? _error;
  bool _fetched = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    if (_fetched) return;
    _fetched = true;
    try {
      final list = await Api.versions();
      if (!mounted) return;
      setState(() {
        _list = list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final list = _list;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '软件版本',
          style: TextStyle(
            color: c.fg,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '本地当前版本（进入页面时采集一次）',
          style: TextStyle(color: c.muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: c.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: c.danger, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else if (list == null)
          const Padding(
            padding: EdgeInsets.only(top: 100),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 80),
            child: Center(
              child: Text('暂无版本数据', style: TextStyle(color: c.muted)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                _listHead(c),
                for (final v in list) _row(c, v),
              ],
            ),
          ),
      ],
    );
  }

  Widget _listHead(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: c.surface2, border: Border.all(color: c.border)),
      child: Row(
        children: [
          Expanded(
            child: _label(c, '软件'),
          ),
          _catCell(c, '类别'),
          SizedBox(
            width: 90,
            child: Align(
              alignment: Alignment.centerRight,
              child: _label(c, '版本'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(AppColors c, String text) => Text(
    text,
    style: TextStyle(
      color: c.muted,
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    ),
  );

  Widget _catCell(AppColors c, String text) => SizedBox(
    width: 60,
    child: Align(
      alignment: Alignment.center,
      child: Text(
        text,
        style: TextStyle(
          color: c.muted,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    ),
  );

  Widget _row(AppColors c, Map<String, dynamic> v) {
    final name = (v['name'] ?? '-').toString();
    final category = (v['category'] ?? '-').toString();
    final version = (v['version'] ?? '-').toString();
    final ok = v['ok'] != false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.fg,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Align(
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.muted, fontSize: 10, letterSpacing: 0.4),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              version,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: ok ? c.fg : c.danger,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
