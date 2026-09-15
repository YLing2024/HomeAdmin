import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'theme.dart';

/// 文件区：目录浏览 / 上传（带进度）/ 新建文件夹 / 重命名 / 删除 / 下载。
/// 路径均为相对文件区根目录的相对路径，根目录为 ''，越界由后端拦截。
/// 行为对齐 Web 端 Files.jsx（移动端不做拖拽上传）。

/// 目录条目（对齐后端 files 路由返回结构）
class _Entry {
  const _Entry(this.name, this.isDir, this.size, this.mtime);

  final String name;
  final bool isDir;
  final int size;
  final int mtime; // 毫秒时间戳，0 表示未知
}

/// 上传任务：串行执行，可取消 / 重试，带进度
class _Upload {
  _Upload({
    required this.id,
    required this.file,
    required this.name,
    required this.size,
    required this.dir,
  });

  final String id;
  final File file;
  final String name;
  final int size;
  final String dir; // 目标目录（相对路径）

  String status = 'waiting'; // waiting / uploading / done / error
  int loaded = 0;
  double percent = 0;
  double speed = 0; // B/s
  double eta = 0; // s
  String error = '';
  bool canceled = false;
  Completer<void>? abort;
}

class FilesPage extends StatefulWidget {
  const FilesPage({super.key, this.active = true});

  /// 是否处于可见 Tab（首次可见才请求，对齐 Web 懒加载）
  final bool active;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  static const String _root = '';

  String _path = _root;
  List<_Entry> _entries = [];
  bool _loading = false;
  bool _loadedOnce = false;
  String? _error;

  String _sortKey = 'name'; // name / size / time
  int _sortDir = 1;

  final List<_Upload> _uploads = [];
  final List<_Upload> _queue = [];
  bool _pumping = false;

  // 弹窗状态机：mkdir / rename / delete 三种
  String? _dialogType;
  String _dialogTitle = '';
  String _dialogValue = '';
  String _dialogTarget = '';
  bool _dialogIsDir = false;
  bool _dialogBusy = false;
  String _dialogError = '';
  final TextEditingController _dialogCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _loadOnce();
    });
  }

  @override
  void didUpdateWidget(covariant FilesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _loadOnce();
  }

  @override
  void dispose() {
    _dialogCtrl.dispose();
    super.dispose();
  }

  void _loadOnce() {
    if (_loadedOnce) return;
    _loadedOnce = true;
    _load(_root);
  }

  /* ============ 数据加载 ============ */

  Future<void> _load(String p) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Api.fileList(p);
      if (!mounted) return;
      final raw = data['entries'];
      final list = <_Entry>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final name = (e['name'] ?? '').toString();
          if (name.isEmpty) continue;
          list.add(
            _Entry(
              name,
              (e['type'] ?? 'file') == 'dir',
              e['size'] is num ? (e['size'] as num).toInt() : 0,
              e['mtime'] is num ? (e['mtime'] as num).toInt() : 0,
            ),
          );
        }
      }
      setState(() {
        _entries = list;
        _path = (data['path'] ?? p).toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _msg(e);
        _entries = [];
        _loading = false;
      });
    }
  }

  List<_Entry> get _shown {
    final list = [..._entries];
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1; // 目录恒在前
      int r;
      if (_sortKey == 'size') {
        r = a.size.compareTo(b.size);
      } else if (_sortKey == 'time') {
        r = a.mtime.compareTo(b.mtime);
      } else {
        r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return r * _sortDir;
    });
    return list;
  }

  void _toggleSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _sortDir = -_sortDir;
      } else {
        _sortKey = key;
        _sortDir = 1;
      }
    });
  }

  /* ============ 目录导航 ============ */

  void _enter(_Entry e) {
    _load(_path.isEmpty ? e.name : '$_path/${e.name}');
  }

  void _goParent() {
    if (_path.isEmpty) return;
    final i = _path.lastIndexOf('/');
    _load(i < 0 ? _root : _path.substring(0, i));
  }

  List<({String name, String path})> get _crumbs {
    if (_path.isEmpty) return const [];
    final out = <({String name, String path})>[];
    var cur = '';
    for (final part in _path.split('/')) {
      cur = cur.isEmpty ? part : '$cur/$part';
      out.add((name: part, path: cur));
    }
    return out;
  }

  String _targetOf(_Entry e) => _path.isEmpty ? e.name : '$_path/${e.name}';

  /* ============ 上传队列（串行，带进度） ============ */

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      _enqueue(result.files);
    } catch (e) {
      if (!mounted) return;
      _snack('选择文件失败：${_msg(e)}');
    }
  }

  void _enqueue(List<PlatformFile> picked) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final jobs = <_Upload>[];
    var i = 0;
    for (final f in picked) {
      final p = f.path;
      if (p == null || p.isEmpty) continue;
      jobs.add(
        _Upload(
          id: '$stamp-$i-${f.name}',
          file: File(p),
          name: f.name,
          size: f.size,
          dir: _path,
        ),
      );
      i += 1;
    }
    if (jobs.isEmpty) return;
    setState(() {
      _uploads.insertAll(0, jobs);
      if (_uploads.length > 40) _uploads.removeRange(40, _uploads.length);
    });
    _queue.addAll(jobs.reversed);
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (job.canceled) continue;
      await _runUpload(job);
    }
    _pumping = false;
    if (mounted) await _load(_path); // 全部结束刷新当前目录
  }

  Future<void> _runUpload(_Upload job) async {
    if (job.canceled || !mounted) return;
    final abort = Completer<void>();
    job.abort = abort;
    final t0 = DateTime.now();
    setState(() {
      job.status = 'uploading';
      job.loaded = 0;
      job.percent = 0;
      job.error = '';
    });
    try {
      await Api.fileUpload(
        job.file,
        job.name,
        job.dir,
        onProgress: (sent, total) {
          if (!mounted || job.canceled) return;
          final elapsed = DateTime.now().difference(t0).inMilliseconds / 1000;
          final speed = elapsed > 0.3 ? sent / elapsed : 0.0;
          setState(() {
            job.loaded = sent;
            job.percent = total > 0 ? sent / total * 100 : 0;
            job.speed = speed;
            job.eta = speed > 0 ? (total - sent) / speed : 0;
          });
        },
        abortTrigger: abort.future,
      );
      if (!mounted || job.canceled) return;
      setState(() {
        job.status = 'done';
        job.loaded = job.size;
        job.percent = 100;
        job.speed = 0;
        job.eta = 0;
      });
    } catch (e) {
      if (!mounted || job.canceled) return;
      setState(() {
        job.status = 'error';
        job.error = _msg(e);
      });
    }
  }

  void _cancelUpload(_Upload job) {
    job.canceled = true;
    job.abort?.complete();
    setState(() => _uploads.remove(job));
  }

  void _retryUpload(_Upload job) {
    if (job.status != 'error') return;
    setState(() {
      job.status = 'waiting';
      job.loaded = 0;
      job.percent = 0;
      job.speed = 0;
      job.eta = 0;
      job.error = '';
      job.canceled = false;
    });
    _queue.add(job);
    _pump();
  }

  void _clearFinished() {
    setState(
      () => _uploads.removeWhere((u) => u.status == 'done' || u.status == 'error'),
    );
  }

  /* ============ 下载 ============ */

  Future<void> _download(_Entry e) async {
    try {
      final ok = await launchUrl(
        Uri.parse(Api.fileDownloadUrl(_targetOf(e))),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) _snack('无法打开下载链接');
    } catch (e) {
      _snack('下载失败：${_msg(e)}');
    }
  }

  /* ============ 弹窗动作 ============ */

  void _openMkdir() {
    _dialogCtrl.text = '';
    setState(() {
      _dialogType = 'mkdir';
      _dialogTitle = '新建文件夹';
      _dialogValue = '';
      _dialogTarget = _path;
      _dialogIsDir = false;
      _dialogError = '';
    });
  }

  void _openRename(_Entry e) {
    _dialogCtrl.text = e.name;
    _dialogCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: e.name.length,
    );
    setState(() {
      _dialogType = 'rename';
      _dialogTitle = '重命名';
      _dialogValue = e.name;
      _dialogTarget = _targetOf(e);
      _dialogIsDir = e.isDir;
      _dialogError = '';
    });
  }

  void _openDelete(_Entry e) {
    setState(() {
      _dialogType = 'delete';
      _dialogTitle = '删除';
      _dialogValue = e.name;
      _dialogTarget = _targetOf(e);
      _dialogIsDir = e.isDir;
      _dialogError = '';
    });
  }

  void _closeDialog() {
    setState(() {
      _dialogType = null;
      _dialogError = '';
      _dialogBusy = false;
    });
  }

  Future<void> _submitDialog() async {
    final type = _dialogType;
    if (type == null || _dialogBusy) return;
    final value = _dialogCtrl.text.trim();
    if (type != 'delete' && value.isEmpty) return;
    setState(() {
      _dialogBusy = true;
      _dialogError = '';
    });
    try {
      if (type == 'mkdir') {
        await Api.fileMkdir(_dialogTarget, value);
      } else if (type == 'rename') {
        await Api.fileRename(_dialogTarget, value);
      } else {
        await Api.fileDelete(_dialogTarget);
      }
      if (!mounted) return;
      setState(() {
        _dialogBusy = false;
        _dialogType = null;
      });
      await _load(_path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dialogBusy = false;
        _dialogError = _msg(e);
      });
    }
  }

  /* ============ 格式化 ============ */

  String _fmtSize(int n) {
    if (n < 1024) return '$n B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = n / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i += 1;
    }
    return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p2(d.month)}-${p2(d.day)} ${p2(d.hour)}:${p2(d.minute)}';
  }

  String _fmtDuration(double sec) {
    if (!sec.isFinite || sec <= 0) return '';
    if (sec < 60) return '${sec.ceil()} 秒';
    return '${sec ~/ 60} 分 ${(sec % 60).ceil()} 秒';
  }

  /// 上传行状态文案：进度只反映 HTTP 段，落盘那几秒停在 99% 需明确提示。
  String _uploadMeta(_Upload u) {
    if (u.status == 'error') return u.error.isEmpty ? '失败' : u.error;
    if (u.status == 'done') return '${_fmtSize(u.size)} · 完成';
    if (u.status == 'waiting') return '${_fmtSize(u.size)} · 等待中';
    if (u.percent >= 99) return '${_fmtSize(u.size)} · 写入服务器…';
    final parts = <String>[
      '${_fmtSize(u.loaded)} / ${_fmtSize(u.size)}',
      '${u.percent.toStringAsFixed(0)}%',
    ];
    if (u.speed > 0) parts.add('${_fmtSize(u.speed.round())}/s');
    if (u.eta > 0) parts.add('剩余 ${_fmtDuration(u.eta)}');
    return parts.join(' · ');
  }

  String _msg(Object e) => e is ApiException ? e.message : e.toString();

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /* ============ 构建 ============ */

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(
      children: [
        Column(
          children: [
            _buildHeader(c),
            if (_uploads.isNotEmpty) _buildUploads(c),
            Expanded(child: _buildListPanel(c)),
          ],
        ),
        if (_dialogType != null) _buildDialog(c),
      ],
    );
  }

  Widget _buildHeader(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Spacer(),
              Text(
                '文件',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              InkWell(
                onTap: _path.isEmpty ? null : _goParent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.arrow_upward,
                        size: 14,
                        color: _path.isEmpty ? c.border : c.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '上级',
                        style: TextStyle(
                          fontSize: 12,
                          color: _path.isEmpty ? c.muted : c.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _buildCrumbs(c)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _actionBtn(c, Icons.create_new_folder_outlined, '新建文件夹', _openMkdir),
              const SizedBox(width: 8),
              _actionBtn(c, Icons.upload_file_outlined, '选择文件', _pickFiles),
              const Spacer(),
              IconButton(
                onPressed: _loading ? null : () => _load(_path),
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.refresh, size: 20, color: c.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCrumbs(AppColors c) {
    final crumbs = _crumbs;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          InkWell(
            onTap: _path.isEmpty ? null : () => _load(_root),
            child: Text(
              '根目录',
              style: TextStyle(fontSize: 12, color: _path.isEmpty ? c.fg : c.muted),
            ),
          ),
          for (final crumb in crumbs) ...[
            Text('/', style: TextStyle(fontSize: 12, color: c.muted)),
            InkWell(
              onTap: crumb.path == _path ? null : () => _load(crumb.path),
              child: Text(
                crumb.name,
                style: TextStyle(
                  fontSize: 12,
                  color: crumb.path == _path ? c.fg : c.muted,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _actionBtn(
    AppColors c,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: c.accent),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: c.fg)),
          ],
        ),
      ),
    );
  }

  Widget _buildUploads(AppColors c) {
    final active = _uploads
        .where((u) => u.status == 'uploading' || u.status == 'waiting')
        .length;
    final failed = _uploads.where((u) => u.status == 'error').length;
    final head = active > 0 ? '上传中 · 剩余 $active' : '上传完成';
    final shown = _uploads.length > 6 ? 6 : _uploads.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$head${failed > 0 ? ' · 失败 $failed' : ''}',
                    style: TextStyle(color: c.fg, fontSize: 12),
                  ),
                ),
                InkWell(
                  onTap: _clearFinished,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      '清除已完成',
                      style: TextStyle(color: c.muted, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: shown,
              itemBuilder: (_, i) => _uploadRow(c, _uploads[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _uploadRow(AppColors c, _Upload u) {
    final error = u.status == 'error';
    final bar = u.status == 'done'
        ? 1.0
        : u.status == 'waiting'
            ? 0.0
            : (u.percent / 100).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  u.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.fg, fontSize: 12),
                ),
              ),
              if (error)
                _linkBtn(c, '重试', c.accent, () => _retryUpload(u))
              else if (u.status == 'uploading' || u.status == 'waiting')
                _linkBtn(c, '取消', c.muted, () => _cancelUpload(u))
              else
                const SizedBox(width: 4),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _uploadMeta(u),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: error ? c.danger : c.muted,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: bar,
              minHeight: 3,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation<Color>(
                error ? c.danger : c.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkBtn(AppColors c, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(label, style: TextStyle(color: color, fontSize: 11)),
      ),
    );
  }

  Widget _buildListPanel(AppColors c) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          _buildSortHeader(c),
          const Divider(height: 1),
          Expanded(child: _buildList(c)),
        ],
      ),
    );
  }

  Widget _buildSortHeader(AppColors c) {
    Widget col(String key, String label, {double? width, TextAlign align = TextAlign.left}) {
      final active = _sortKey == key;
      final arrow = active ? (_sortDir > 0 ? ' ↑' : ' ↓') : '';
      final child = Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          '$label$arrow',
          textAlign: align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: active ? c.accent : c.muted,
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
      final tap = InkWell(onTap: () => _toggleSort(key), child: child);
      return width == null ? Expanded(child: tap) : SizedBox(width: width, child: tap);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          const SizedBox(width: 25),
          col('name', '名称'),
          col('size', '大小', width: 64, align: TextAlign.right),
          col('time', '修改时间', width: 96, align: TextAlign.right),
          const SizedBox(width: 34),
        ],
      ),
    );
  }

  Widget _buildList(AppColors c) {
    if (_loading && _entries.isEmpty) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(color: c.accent, strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.danger, fontSize: 13),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () => _load(_path),
                child: Text(
                  '重试',
                  style: TextStyle(color: c.accent, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          '空目录',
          style: TextStyle(color: c.muted, fontSize: 13),
        ),
      );
    }
    final shown = _shown;
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: shown.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
      itemBuilder: (_, i) => _row(c, shown[i]),
    );
  }

  Widget _row(AppColors c, _Entry e) {
    return InkWell(
      onTap: e.isDir ? () => _enter(e) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Icon(
              e.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
              size: 17,
              color: e.isDir ? c.accent : c.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.fg, fontSize: 13),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                e.isDir ? '—' : _fmtSize(e.size),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.muted,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            SizedBox(
              width: 96,
              child: Text(
                _fmtTime(e.mtime),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.muted,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            SizedBox(width: 34, child: _rowMenu(c, e)),
          ],
        ),
      ),
    );
  }

  Widget _rowMenu(AppColors c, _Entry e) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 18, color: c.muted),
      color: c.surface,
      tooltip: '',
      onSelected: (v) {
        if (v == 'download') {
          _download(e);
        } else if (v == 'rename') {
          _openRename(e);
        } else if (v == 'delete') {
          _openDelete(e);
        }
      },
      itemBuilder: (_) => [
        if (!e.isDir)
          const PopupMenuItem(
            value: 'download',
            height: 40,
            child: Text('下载', style: TextStyle(fontSize: 13)),
          ),
        const PopupMenuItem(
          value: 'rename',
          height: 40,
          child: Text('重命名', style: TextStyle(fontSize: 13)),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 40,
          child: Text('删除', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildDialog(AppColors c) {
    final isDelete = _dialogType == 'delete';
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          if (!_dialogBusy) _closeDialog();
        },
        child: Container(
          color: c.overlay,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _dialogTitle,
                    style: TextStyle(
                      color: c.fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isDelete)
                    Text(
                      '确定删除「$_dialogValue」？'
                      '${_dialogIsDir ? '该目录及其全部内容都会被删除，' : ''}'
                      '此操作不可撤销。',
                      style: TextStyle(color: c.muted, fontSize: 13, height: 1.6),
                    )
                  else
                    TextField(
                      controller: _dialogCtrl,
                      autofocus: true,
                      style: TextStyle(color: c.fg, fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _dialogType == 'mkdir' ? '文件夹名称' : '新名称',
                        hintStyle: TextStyle(color: c.muted, fontSize: 13),
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submitDialog(),
                    ),
                  if (_dialogError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _dialogError,
                      style: TextStyle(color: c.danger, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _dialogBusy ? null : _closeDialog,
                        child: Text(
                          '取消',
                          style: TextStyle(color: c.muted, fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        onPressed: (_dialogBusy ||
                                (!isDelete && _dialogCtrl.text.trim().isEmpty))
                            ? null
                            : _submitDialog,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.accent,
                          foregroundColor: c.bg,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        child: Text(
                          _dialogBusy ? '处理中…' : (isDelete ? '删除' : '确定'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
