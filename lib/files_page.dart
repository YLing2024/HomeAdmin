import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /* ============ 临时链接（限时分享，对齐 Web FileShare.jsx） ============ */

  Future<void> _openShareCreate(_Entry e) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ShareCreateDialog(path: _targetOf(e), name: e.name),
    );
  }

  void _openShares() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _ShareManageSheet(),
    );
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
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _actionBtn(c, Icons.create_new_folder_outlined, '新建文件夹', _openMkdir),
                    _actionBtn(c, Icons.upload_file_outlined, '选择文件', _pickFiles),
                    _actionBtn(c, Icons.link_outlined, '临时链接', _openShares),
                  ],
                ),
              ),
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
        } else if (v == 'share') {
          _openShareCreate(e);
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
        if (!e.isDir)
          const PopupMenuItem(
            value: 'share',
            height: 40,
            child: Text('链接', style: TextStyle(fontSize: 13)),
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

/* ============ 临时链接：预设 / 文案 / 状态色 ============ */

/// 预设有效期：hours 为 0 表示永久，为 null 表示自定义时刻
const List<({String key, String label, int? hours})> _sharePresets = [
  (key: '1h', label: '1 小时', hours: 1),
  (key: '24h', label: '24 小时', hours: 24),
  (key: '7d', label: '7 天', hours: 168),
  (key: '30d', label: '30 天', hours: 720),
  (key: 'forever', label: '永久', hours: 0),
  (key: 'custom', label: '自定义', hours: null),
];

String _pad2(int n) => n.toString().padLeft(2, '0');

String _shareFmtTime(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_pad2(d.month)}-${_pad2(d.day)} '
      '${_pad2(d.hour)}:${_pad2(d.minute)}';
}

/// 毫秒时长 → 「x 天 x 小时 / x 小时 x 分 / x 分」
String _humanDuration(int ms) {
  final min = ms ~/ 60000;
  final days = min ~/ 1440;
  final hours = (min % 1440) ~/ 60;
  final mins = min % 60;
  if (days > 0) return '$days 天 $hours 小时';
  if (hours > 0) return '$hours 小时 $mins 分';
  return '${mins < 1 ? 1 : mins} 分';
}

int? _expiresMs(Map<String, dynamic> s) {
  final e = s['expiresAt'];
  return e is num ? e.toInt() : null;
}

bool _isPermanent(Map<String, dynamic> s) {
  final e = _expiresMs(s);
  return e != null && e == 0;
}

String _idOf(Map<String, dynamic> s) => (s['id'] ?? '').toString();

String _displayName(Map<String, dynamic> s) {
  final rel = (s['relPath'] ?? '').toString();
  if (rel.isEmpty) return _idOf(s);
  final i = rel.lastIndexOf('/');
  return i < 0 ? rel : rel.substring(i + 1);
}

/// 列表里的有效期文案：永久 / 剩余 x / 已过期 / 已撤销
String _shareExpiryText(Map<String, dynamic> s) {
  if ((s['status'] ?? '').toString() == 'revoked') return '已撤销';
  if (_isPermanent(s)) return '永久';
  final remaining = s['remainingMs'];
  if (remaining is num && remaining > 0) {
    return '剩余 ${_humanDuration(remaining.toInt())}';
  }
  return '已过期';
}

({String text, Color color}) _shareStatusMeta(AppColors c, String status) {
  switch (status) {
    case 'active':
      return (text: '有效', color: c.ok);
    case 'expired':
      return (text: '已过期', color: c.warn);
    case 'revoked':
      return (text: '已撤销', color: c.danger);
    default:
      return (text: status.isEmpty ? '未知' : status, color: c.muted);
  }
}

String _msgOf(Object e) => e is ApiException ? e.message : e.toString();

/// 二次确认弹窗；确认返回 true，取消 / 关闭返回 false
Future<bool> _confirmDialog(
  BuildContext context,
  String title,
  String message,
  String confirmLabel,
) async {
  final c = context.c;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: c.border),
      ),
      title: Text(
        title,
        style: TextStyle(color: c.fg, fontSize: 14, fontWeight: FontWeight.w600),
      ),
      content: Text(
        message,
        style: TextStyle(color: c.muted, fontSize: 13, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('取消', style: TextStyle(color: c.muted, fontSize: 13)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: c.bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: Text(confirmLabel, style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 弹窗外框：直角、发丝线、暖纸白 / 墨黑；窄屏不横向滚动
Widget _shareDialogFrame(AppColors c, List<Widget> children) {
  return Dialog(
    backgroundColor: c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(4),
      side: BorderSide(color: c.border),
    ),
    insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

Widget _shareFieldLabel(AppColors c, String text) => Text(
      text,
      style: TextStyle(color: c.muted, fontSize: 11, letterSpacing: 1.2),
    );

Widget _shareChip(
  AppColors c, {
  required String label,
  required bool selected,
  required VoidCallback? onTap,
}) {
  return ChoiceChip(
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    onSelected: onTap == null ? null : (_) => onTap(),
    labelStyle: TextStyle(
      fontSize: 12,
      color: selected ? c.accent : c.fg,
    ),
    selectedColor: c.accentSoft,
    backgroundColor: c.surface2,
    side: BorderSide(color: selected ? c.accentBorder : c.border),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  );
}

/// 日期 + 时间选择（分钟精度）；返回本地时间，取消返回 null
Future<DateTime?> _pickShareMoment(
  BuildContext context, {
  required DateTime initial,
}) async {
  final now = DateTime.now();
  final base = initial.isBefore(now) ? now : initial;
  final date = await showDatePicker(
    context: context,
    initialDate: base,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: DateTime(now.year + 10),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(base),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/* ---------------- 创建：预设有效期 + 自定义时刻 ---------------- */

class _ShareCreateDialog extends StatefulWidget {
  const _ShareCreateDialog({required this.path, required this.name});

  /// 文件区相对路径（提交给后端）
  final String path;

  /// 展示用文件名
  final String name;

  @override
  State<_ShareCreateDialog> createState() => _ShareCreateDialogState();
}

class _ShareCreateDialogState extends State<_ShareCreateDialog> {
  String _preset = '24h';
  DateTime? _customAt;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _busy = false;
  bool _copied = false;
  String _error = '';
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _customAt = DateTime.now().add(const Duration(hours: 24));
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCustom() async {
    final at = _customAt ?? DateTime.now().add(const Duration(hours: 24));
    final picked = await _pickShareMoment(context, initial: at);
    if (picked == null || !mounted) return;
    setState(() {
      _customAt = picked;
      _error = '';
    });
  }

  Future<void> _submit() async {
    if (_busy || _result != null) return;
    setState(() => _error = '');
    int? ttlHours;
    int? expiresAt;
    if (_preset == 'forever') {
      expiresAt = 0;
    } else if (_preset == 'custom') {
      final at = _customAt;
      if (at == null) {
        setState(() => _error = '请选择过期时间');
        return;
      }
      if (!at.isAfter(DateTime.now())) {
        setState(() => _error = '过期时间须晚于当前时间');
        return;
      }
      expiresAt = at.millisecondsSinceEpoch;
    } else {
      ttlHours = _sharePresets.firstWhere((p) => p.key == _preset).hours;
    }
    setState(() => _busy = true);
    try {
      final rec = await Api.fileShareCreate(
        path: widget.path,
        ttlHours: ttlHours,
        expiresAt: expiresAt,
        note: _noteCtrl.text,
      );
      if (!mounted) return;
      final url = (rec['url'] ?? '').toString();
      setState(() {
        _busy = false;
        if (url.isEmpty) {
          _error = '创建成功，但未返回链接';
        } else {
          _result = rec;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _msgOf(e);
      });
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制链接')),
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return _shareDialogFrame(c, [
      Text(
        '创建临时链接',
        style: TextStyle(color: c.fg, fontSize: 14, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      Text(
        widget.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: c.muted, fontSize: 12),
      ),
      const SizedBox(height: 14),
      if (_result != null) ..._resultView(c, _result!) else ..._formView(c),
    ]);
  }

  List<Widget> _formView(AppColors c) {
    return [
      _shareFieldLabel(c, '有效期'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in _sharePresets)
            _shareChip(
              c,
              label: p.label,
              selected: _preset == p.key,
              onTap: _busy ? null : () => setState(() => _preset = p.key),
            ),
        ],
      ),
      if (_preset == 'custom') ...[
        const SizedBox(height: 12),
        _shareFieldLabel(c, '过期时间'),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                _customAt == null
                    ? '未选择'
                    : _shareFmtTime(_customAt!.millisecondsSinceEpoch),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.fg, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _pickCustom,
              child: const Text('选择时间', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      Text(
        _preset == 'forever'
            ? '永久有效，不会自动过期，只能手动撤销。'
            : '到期后链接自动失效。',
        style: TextStyle(color: c.muted, fontSize: 11.5),
      ),
      const SizedBox(height: 12),
      _shareFieldLabel(c, '备注'),
      const SizedBox(height: 6),
      TextField(
        controller: _noteCtrl,
        enabled: !_busy,
        maxLength: 80,
        style: TextStyle(color: c.fg, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: '选填',
          hintStyle: TextStyle(color: c.muted, fontSize: 13),
          counterStyle: TextStyle(color: c.muted, fontSize: 10),
        ),
      ),
      if (_error.isNotEmpty) ...[
        Text(_error, style: TextStyle(color: c.danger, fontSize: 12)),
      ],
      const SizedBox(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text('取消', style: TextStyle(color: c.muted, fontSize: 13)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: c.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text(
              _busy ? '创建中…' : '创建链接',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _resultView(AppColors c, Map<String, dynamic> rec) {
    final url = (rec['url'] ?? '').toString();
    final expiresAt = _expiresMs(rec);
    return [
      _shareFieldLabel(c, '链接'),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: c.surface2,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: SelectableText(
          url,
          style: TextStyle(color: c.fg, fontSize: 12, fontFamily: 'monospace'),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        (expiresAt != null && expiresAt == 0)
            ? '永久有效，不会自动过期，只能手动撤销。'
            : '有效期至 ${_shareFmtTime(expiresAt ?? 0)}',
        style: TextStyle(color: c.muted, fontSize: 11.5),
      ),
      const SizedBox(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('完成', style: TextStyle(color: c.muted, fontSize: 13)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: () => _copy(url),
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: c.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text(
              _copied ? '已复制' : '复制链接',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    ];
  }
}

/* ---------------- 改期：改过期时刻本身（转永久 = expiresAt 0） ---------------- */

class _ShareScheduleDialog extends StatefulWidget {
  const _ShareScheduleDialog({required this.share});

  final Map<String, dynamic> share;

  @override
  State<_ShareScheduleDialog> createState() => _ShareScheduleDialogState();
}

class _ShareScheduleDialogState extends State<_ShareScheduleDialog> {
  late final bool _permanentAtOpen;
  String _mode = 'finite'; // finite / permanent
  DateTime? _at;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _permanentAtOpen = _isPermanent(widget.share);
    _mode = _permanentAtOpen ? 'permanent' : 'finite';
    final cur = _expiresMs(widget.share);
    _at = (cur != null && cur > 0)
        ? DateTime.fromMillisecondsSinceEpoch(cur)
        : null;
  }

  Future<void> _pick() async {
    final at = _at ?? DateTime.now().add(const Duration(hours: 24));
    final picked = await _pickShareMoment(context, initial: at);
    if (picked == null || !mounted) return;
    setState(() {
      _at = picked;
      _error = '';
    });
  }

  String _hint() {
    if (_mode == 'permanent') {
      return _permanentAtOpen
          ? '当前为永久有效，不会自动过期。'
          : '转为永久后不再自动过期，需手动撤销；之后可随时再指定过期时间。';
    }
    final at = _at;
    if (at == null) {
      return _permanentAtOpen ? '当前为永久有效：选择过期时间即转为限时。' : '';
    }
    final diff = at.difference(DateTime.now()).inMilliseconds;
    if (diff <= 0) return '该时刻已过去，请选择未来时间';
    final tip = '距现在约 ${_humanDuration(diff)}';
    final cur = _expiresMs(widget.share) ?? 0;
    if (!_permanentAtOpen && cur > 0 && at.millisecondsSinceEpoch < cur) {
      return '$tip（比当前到期时间早，将缩短有效期）';
    }
    return tip;
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _error = '');
    if (_mode == 'permanent') {
      final ok = await _confirmDialog(
        context,
        '转为永久',
        '转为永久有效后不再自动过期，只能手动撤销。确认？',
        '转为永久',
      );
      if (!ok || !mounted) return;
      await _submitBody(0);
      return;
    }
    final at = _at;
    if (at == null) {
      setState(() => _error = '请选择过期时间');
      return;
    }
    final ms = at.millisecondsSinceEpoch;
    if (!at.isAfter(DateTime.now())) {
      setState(() => _error = '过期时间须晚于当前时间');
      return;
    }
    final cur = _expiresMs(widget.share) ?? 0;
    if (!_permanentAtOpen && cur > 0 && ms < cur) {
      final ok = await _confirmDialog(
        context,
        '缩短有效期',
        '新的过期时间早于当前，将缩短有效期。确认？',
        '确定',
      );
      if (!ok || !mounted) return;
    }
    await _submitBody(ms);
  }

  Future<void> _submitBody(int expiresAt) async {
    setState(() => _busy = true);
    try {
      final rec = await Api.fileShareUpdate(_idOf(widget.share), expiresAt: expiresAt);
      if (!mounted) return;
      Navigator.of(context).pop(rec);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _msgOf(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return _shareDialogFrame(c, [
      Text(
        '改期',
        style: TextStyle(color: c.fg, fontSize: 14, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      Text(
        _displayName(widget.share),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: c.muted, fontSize: 12),
      ),
      const SizedBox(height: 14),
      if (!_permanentAtOpen) ...[
        _shareFieldLabel(c, '方式'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            _shareChip(
              c,
              label: '指定时刻',
              selected: _mode == 'finite',
              onTap: _busy ? null : () => setState(() => _mode = 'finite'),
            ),
            _shareChip(
              c,
              label: '转为永久',
              selected: _mode == 'permanent',
              onTap: _busy
                  ? null
                  : () => setState(() => _mode = 'permanent'),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (_mode == 'finite') ...[
        _shareFieldLabel(c, '过期时间'),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                _at == null
                    ? '未选择'
                    : _shareFmtTime(_at!.millisecondsSinceEpoch),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.fg, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _pick,
              child: const Text('选择时间', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ],
      if (_hint().isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(_hint(), style: TextStyle(color: c.muted, fontSize: 11.5)),
      ],
      if (_error.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(_error, style: TextStyle(color: c.danger, fontSize: 12)),
      ],
      const SizedBox(height: 14),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text('取消', style: TextStyle(color: c.muted, fontSize: 13)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: c.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text(
              _busy ? '提交中…' : '确定',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    ]);
  }
}

/* ---------------- 管理面板：列表 / 复制 / 改期 / 撤销 / 删除 ---------------- */

class _ShareManageSheet extends StatefulWidget {
  const _ShareManageSheet();

  @override
  State<_ShareManageSheet> createState() => _ShareManageSheetState();
}

class _ShareManageSheetState extends State<_ShareManageSheet> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _error = '';
  String _busyId = '';
  String _copiedId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final list = await Api.fileShares();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _msgOf(e);
        _items = [];
        _loading = false;
      });
    }
  }

  void _apply(Map<String, dynamic> rec) {
    final id = rec['id'];
    if (id == null) return;
    setState(() {
      _items = [
        for (final s in _items) s['id'] == id ? rec : s,
      ];
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _copy(Map<String, dynamic> s) async {
    final url = (s['url'] ?? '').toString();
    if (url.isEmpty) {
      _snack('该记录没有链接');
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    final id = _idOf(s);
    setState(() => _copiedId = id);
    _snack('已复制链接');
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && _copiedId == id) setState(() => _copiedId = '');
    });
  }

  Future<void> _edit(Map<String, dynamic> s) async {
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ShareScheduleDialog(share: s),
    );
    if (updated == null || !mounted) return;
    _apply(updated);
  }

  Future<void> _revoke(Map<String, dynamic> s) async {
    final ok = await _confirmDialog(
      context,
      '撤销链接',
      '撤销「${_displayName(s)}」的临时链接？撤销后不可恢复。',
      '撤销',
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = _idOf(s));
    try {
      final rec = await Api.fileShareUpdate(_idOf(s), revoked: true);
      if (!mounted) return;
      _apply(rec);
    } catch (e) {
      _snack(_msgOf(e));
    } finally {
      if (mounted) setState(() => _busyId = '');
    }
  }

  Future<void> _remove(Map<String, dynamic> s) async {
    final ok = await _confirmDialog(
      context,
      '删除记录',
      '删除「${_displayName(s)}」的链接记录？磁盘文件不受影响。',
      '删除',
    );
    if (!ok || !mounted) return;
    final id = _idOf(s);
    setState(() => _busyId = id);
    try {
      await Api.fileShareDelete(id);
      if (!mounted) return;
      setState(() => _items = _items.where((x) => x['id'] != s['id']).toList());
    } catch (e) {
      _snack(_msgOf(e));
    } finally {
      if (mounted) setState(() => _busyId = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '临时链接',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _loading ? null : _load,
                child: Text('刷新', style: TextStyle(color: c.accent, fontSize: 12)),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                visualDensity: VisualDensity.compact,
                tooltip: '关闭',
                icon: Icon(Icons.close, size: 18, color: c.muted),
              ),
            ],
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(_error, style: TextStyle(color: c.danger, fontSize: 12)),
          ],
          const SizedBox(height: 6),
          Flexible(child: _buildBody(c)),
        ],
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    if (_loading && _items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: c.accent,
      backgroundColor: c.surface,
      child: _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 48),
                Center(
                  child: Text(
                    '暂无临时链接',
                    style: TextStyle(color: c.muted, fontSize: 13),
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: _items.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
              itemBuilder: (_, i) => _item(c, _items[i]),
            ),
    );
  }

  Widget _item(AppColors c, Map<String, dynamic> s) {
    final id = _idOf(s);
    final status = (s['status'] ?? '').toString();
    final meta = _shareStatusMeta(c, status);
    final name = _displayName(s);
    final relPath = (s['relPath'] ?? '').toString();
    final note = (s['note'] ?? '').toString();
    final downloads = s['downloads'];
    final count = downloads is num ? downloads.toInt() : 0;
    final created = s['createdAt'];
    final createdMs = created is num ? created.toInt() : 0;
    final fileExists = s['fileExists'] != false;
    final busy = _busyId == id;
    final copied = _copiedId == id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.fg, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: meta.color,
                ),
              ),
              const SizedBox(width: 5),
              Text(meta.text, style: TextStyle(color: meta.color, fontSize: 11.5)),
            ],
          ),
          if (relPath.isNotEmpty && relPath != name) ...[
            const SizedBox(height: 2),
            Text(
              relPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.muted,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '有效期 ${_shareExpiryText(s)} · 下载 $count 次 · 创建 ${_shareFmtTime(createdMs)}',
            style: TextStyle(color: c.muted, fontSize: 11),
          ),
          if (!fileExists) ...[
            const SizedBox(height: 2),
            Text('文件已删除', style: TextStyle(color: c.danger, fontSize: 11)),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '备注 $note',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 2),
          Wrap(
            spacing: 2,
            runSpacing: 0,
            children: [
              _op(
                c,
                copied ? '已复制' : '复制链接',
                onTap: () => _copy(s),
              ),
              if (status == 'active')
                _op(c, '改期', onTap: busy ? null : () => _edit(s)),
              if (status == 'active')
                _op(c, '撤销', danger: true, onTap: busy ? null : () => _revoke(s)),
              _op(c, '删除记录', danger: true, onTap: busy ? null : () => _remove(s)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _op(
    AppColors c,
    String label, {
    bool danger = false,
    VoidCallback? onTap,
  }) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: danger ? c.danger : c.accent,
      ),
      child: Text(label, style: const TextStyle(fontSize: 11.5)),
    );
  }
}
