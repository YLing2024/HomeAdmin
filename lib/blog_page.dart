import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'login_page.dart';
import 'theme.dart';

/// 博客管理页（对齐 Web 端 BlogAdmin）：
/// 文章/合集双视图 CRUD、Markdown 编辑+预览、插图、草稿自动保存
class BlogPage extends StatefulWidget {
  const BlogPage({super.key});

  @override
  State<BlogPage> createState() => _BlogPageState();
}

class _BlogPageState extends State<BlogPage> {
  String _view = 'posts'; // posts | collections
  List<Map<String, dynamic>> _posts = [];
  List<Map<String, dynamic>> _collections = [];
  bool _loading = true;
  String? _error;

  // 编辑器状态：null=列表，'new'=新建，Map=编辑
  dynamic _editing;
  dynamic _editingCollection;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final posts = await Api.blogPosts();
      var cols = <Map<String, dynamic>>[];
      try {
        final c = await Api.blogCollections();
        cols = c.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
      } catch (_) {
        // 合集加载失败不阻塞文章列表
      }
      if (!mounted) return;
      setState(() {
        _posts = posts.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        _collections = cols;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _reloadAll() async {
    try {
      final posts = await Api.blogPosts();
      List<Map<String, dynamic>> cols = [];
      try {
        final c = await Api.blogCollections();
        cols = c.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _posts = posts.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        _collections = cols;
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
    if (_editingCollection != null) {
      return _CollectionEditor(
        collection: _editingCollection is Map
            ? _editingCollection as Map<String, dynamic>
            : null,
        onBack: () => setState(() => _editingCollection = null),
        onSaved: () {
          setState(() => _editingCollection = null);
          _reloadAll();
        },
      );
    }
    if (_editing != null) {
      final post = _editing is Map
          ? _editing as Map<String, dynamic>
          : null;
      return _PostEditor(
        post: post,
        collections: _collections,
        onBack: () => setState(() => _editing = null),
        onSaved: () {
          setState(() => _editing = null);
          _reloadAll();
        },
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '博客管理',
                    style: TextStyle(
                      color: c.fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _tabBtn(c, '文章', 'posts'),
                      const SizedBox(width: 18),
                      _tabBtn(c, '合集', 'collections'),
                    ],
                  ),
                ],
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onPressed: _loading
                  ? null
                  : () {
                      if (_view == 'posts') {
                        setState(() => _editing = 'new');
                      } else {
                        setState(() => _editingCollection = 'new');
                      }
                    },
              child: Text(_view == 'posts' ? '＋ 新建文章' : '＋ 新建合集'),
            ),
          ],
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
          ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 100),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_view == 'posts')
          _postsList(c)
        else
          _collectionsList(c),
      ],
    );
  }

  Widget _tabBtn(AppColors c, String label, String view) {
    final active = _view == view;
    return InkWell(
      onTap: () => setState(() => _view = view),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? c.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? c.accent : c.muted,
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /* ============ 文章列表 ============ */

  Widget _postsList(AppColors c) {
    if (_posts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Center(
          child: Text(
            '暂无文章，点击右上角「新建文章」开始创作',
            style: TextStyle(color: c.muted, fontSize: 13),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final p in _posts) _postRow(c, p),
      ],
    );
  }

  Widget _postRow(AppColors c, Map<String, dynamic> p) {
    final title = (p['title'] ?? '-').toString();
    final published = p['published'] == true;
    final tags = p['tags'] is List ? p['tags'] as List : const [];
    final updated = (p['updated_at'] ?? p['created_at'] ?? '').toString();
    final collection = p['collection'] is Map
        ? (p['collection'] as Map)['name']?.toString()
        : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (collection != null) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(color: c.accentBorder),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '合集：$collection',
                            style: TextStyle(color: c.accent, fontSize: 11),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: published ? c.ok : c.border,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    published ? '已发布' : '草稿',
                    style: TextStyle(
                      color: published ? c.ok : c.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (tags.isNotEmpty) ...[
              // 不换行，超宽时横向滚动（对齐 Web blog-tags: flex-wrap: nowrap）
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: tags
                      .whereType<String>()
                      .map(
                        (t) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: c.surface2,
                              border: Border.all(color: c.border),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              t,
                              style: TextStyle(color: c.muted, fontSize: 11),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    updated,
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                ),
                _linkBtn(c, '编辑', () {
                  setState(() => _editing = p);
                }),
                const SizedBox(width: 14),
                _linkBtn(c, '删除', () => _deletePost(p), danger: true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deletePost(Map<String, dynamic> p) async {
    final ok = await _confirm(
      context,
      '删除文章',
      '确定删除「${p['title']}」？此操作不可恢复。',
    );
    if (!ok) return;
    try {
      await Api.blogDeletePost(p['id'] as int);
      await _reloadAll();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _toastError(e.toString());
    }
  }

  /* ============ 合集列表 ============ */

  Widget _collectionsList(AppColors c) {
    if (_collections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Center(
          child: Text(
            '暂无合集，点击右上角「新建合集」开始创建',
            style: TextStyle(color: c.muted, fontSize: 13),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final col in _collections) _collectionRow(c, col),
      ],
    );
  }

  Widget _collectionRow(AppColors c, Map<String, dynamic> col) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (col['name'] ?? '-').toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.fg,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            (col['description'] ?? '—').toString(),
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${col['post_count'] ?? 0} 篇文章',
                  style: TextStyle(color: c.muted, fontSize: 11),
                ),
              ),
              _linkBtn(c, '编辑', () {
                setState(() => _editingCollection = col);
              }),
              const SizedBox(width: 14),
              _linkBtn(c, '删除', () => _deleteCollection(col), danger: true),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _deleteCollection(Map<String, dynamic> col) async {
    final ok1 = await _confirm(
      context,
      '删除合集',
      '确定删除合集「${col['name']}」？',
    );
    if (!ok1 || !mounted) return;
    final ok2 = await _confirm(
      context,
      '再次确认',
      '再次确认：删除合集「${col['name']}」将解除该合集下所有文章的关联，此操作不可恢复。',
    );
    if (!ok2) return;
    try {
      await Api.blogDeleteCollection(col['id'] as int);
      await _reloadAll();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) _toastError(e.toString());
    }
  }

  /* ============ 通用 ============ */

  Widget _linkBtn(AppColors c, String label, VoidCallback onTap, {bool danger = false}) {
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: danger ? c.danger : c.accent,
          fontSize: 12,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  void _toastError(String msg) {
    if (!mounted) return;
    final c = context.c;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(color: c.danger)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static Future<bool> _confirm(
    BuildContext context,
    String title,
    String message,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(message, style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

/* ============ 文章编辑器 ============ */

class _PostEditor extends StatefulWidget {
  const _PostEditor({
    required this.post,
    required this.collections,
    required this.onBack,
    required this.onSaved,
  });

  final Map<String, dynamic>? post;
  final List<Map<String, dynamic>> collections;
  final VoidCallback onBack;
  final VoidCallback onSaved;

  @override
  State<_PostEditor> createState() => _PostEditorState();
}

class _PostEditorState extends State<_PostEditor> {
  late final TextEditingController _title;
  late final TextEditingController _slug;
  late final TextEditingController _tags;
  late final TextEditingController _excerpt;
  late final TextEditingController _content;
  int? _collectionId;
  bool _published = false;
  bool _preview = false;
  bool _saving = false;
  String? _error;
  String? _notice;
  Timer? _draftTimer;
  Timer? _noticeTimer;
  bool _userEdited = false; // 打开编辑器后用户是否已输入（对齐 Web：恢复不覆盖已输入内容）

  bool get _isNew => widget.post == null;
  String get _draftKey => 'blog_draft_${_isNew ? 'new' : widget.post!['id']}';

  @override
  void initState() {
    super.initState();
    final p = widget.post;
    _title = TextEditingController(text: p?['title']?.toString() ?? '');
    _slug = TextEditingController(text: p?['slug']?.toString() ?? '');
    _tags = TextEditingController(text: (p?['tags'] as List?)?.join(', ') ?? '');
    _excerpt = TextEditingController(text: p?['excerpt']?.toString() ?? '');
    _content = TextEditingController(text: p?['content']?.toString() ?? '');
    final col = p?['collection'];
    _collectionId = col is Map ? col['id'] as int? : null;
    _published = p?['published'] == true;
    _restoreDraft();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _noticeTimer?.cancel();
    _saveDraft();
    _title.dispose();
    _slug.dispose();
    _tags.dispose();
    _excerpt.dispose();
    _content.dispose();
    super.dispose();
  }

  // 防抖自动保存（独立于恢复：随输入触发，恢复只在 initState 执行一次）
  void _markChanged() {
    _userEdited = true;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1500), _saveDraft);
  }

  Future<void> _restoreDraft() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_draftKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final saved = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (!mounted) return;
      // 读取草稿期间用户可能已开始输入（SharedPreferences 首次加载有延迟）：
      // 已有输入则放弃恢复，避免旧草稿覆盖输入内容
      if (_userEdited) return;
      setState(() {
        _title.text = saved['title']?.toString() ?? _title.text;
        _slug.text = saved['slug']?.toString() ?? _slug.text;
        _tags.text = saved['tags']?.toString() ?? _tags.text;
        _excerpt.text = saved['excerpt']?.toString() ?? _excerpt.text;
        _content.text = saved['content']?.toString() ?? _content.text;
        _collectionId = saved['collection_id'];
        _published = saved['published'] == true;
      });
      _notice = '已恢复未保存的草稿';
      _noticeTimer = Timer(const Duration(milliseconds: 3000), () {
        if (mounted) setState(() => _notice = null);
      });
    } catch (_) {
      // 损坏的草稿 JSON 静默忽略
    }
  }

  Future<void> _saveDraft() async {
    // 先同步快照字段值再异步等待，dispose 时保存不会读到已释放的控制器
    final data = jsonEncode({
      'title': _title.text,
      'slug': _slug.text,
      'tags': _tags.text,
      'excerpt': _excerpt.text,
      'content': _content.text,
      'collection_id': _collectionId,
      'published': _published,
    });
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_draftKey, data);
  }

  Future<void> _clearDraft() async {
    _draftTimer?.cancel();
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_draftKey);
  }

  Future<void> _submit(bool publish) async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    final tags = _tags.text
        .split(RegExp(r'[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final body = {
      'title': title,
      'slug': _slug.text.trim(),
      'tags': tags,
      'excerpt': _excerpt.text.trim(),
      'content': _content.text,
      'published': publish,
      'collection_id': _collectionId,
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isNew) {
        await Api.blogCreatePost(body);
      } else {
        await Api.blogUpdatePost(widget.post!['id'] as int, body);
      }
      await _clearDraft();
      if (!mounted) return;
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _insertImage() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final url = await Api.blogUploadImage(File(picked.path), picked.name);
      if (!mounted) return;
      final mdText = '![](https://zhangyunling.cn$url)';
      final sel = _content.selection;
      final start = sel.isValid ? sel.start : _content.text.length;
      final end = sel.isValid ? sel.end : _content.text.length;
      final next = _content.text.replaceRange(start, end, mdText);
      _content.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + mdText.length),
      );
      setState(() => _notice = '图片已插入');
      _noticeTimer?.cancel();
      _noticeTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _notice = null);
      });
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = '图片上传失败: ${e.toString()}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            InkWell(
              onTap: _saving ? null : widget.onBack,
              child: Row(
                children: [
                  Icon(Icons.arrow_back, size: 18, color: c.accent),
                  const SizedBox(width: 4),
                  Text(
                    '返回列表',
                    style: TextStyle(color: c.accent, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Text(
              _isNew ? '新建文章' : '编辑文章',
              style: TextStyle(
                color: c.fg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            const SizedBox(width: 80),
          ],
        ),
        const SizedBox(height: 16),
        _field(c, '标题 *', TextField(
          controller: _title,
          autofocus: _isNew,
          onChanged: (_) => _markChanged(),
          decoration: const InputDecoration(hintText: '文章标题'),
        )),
        const SizedBox(height: 12),
        _field(c, 'SLUG', TextField(
          controller: _slug,
          onChanged: (_) => _markChanged(),
          decoration: const InputDecoration(hintText: '留空自动生成（如 my-first-post）'),
        )),
        const SizedBox(height: 12),
        _field(c, '标签', TextField(
          controller: _tags,
          onChanged: (_) => _markChanged(),
          decoration: const InputDecoration(hintText: '逗号分隔，如：前端, 生活'),
        )),
        const SizedBox(height: 12),
        _field(c, '摘要', TextField(
          controller: _excerpt,
          maxLines: 2,
          onChanged: (_) => _markChanged(),
          decoration: const InputDecoration(hintText: '列表页显示的摘要'),
        )),
        const SizedBox(height: 12),
        _field(c, '合集', InputDecorator(
          decoration: const InputDecoration(),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int?>(
              value: _collectionId,
              isExpanded: true,
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('无合集'),
                ),
                ...widget.collections.map(
                  (col) => DropdownMenuItem<int?>(
                    value: col['id'] as int,
                    child: Text(
                      (col['name'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) {
                setState(() => _collectionId = v);
                _markChanged();
              },
            ),
          ),
        )),
        const SizedBox(height: 16),
        Row(
          children: [
            _toolBtn(c, '插图', _insertImage, icon: Icons.image_outlined),
            const SizedBox(width: 8),
            if (_notice != null)
              Expanded(
                child: Text(
                  _notice!,
                  style: TextStyle(color: c.accent, fontSize: 12),
                ),
              ),
            const Spacer(),
            _toolBtn(
              c,
              _preview ? '编辑' : '预览',
              () => setState(() => _preview = !_preview),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_preview)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
            ),
            child: MarkdownBody(
              data: _content.text,
              selectable: true,
              softLineBreak: true,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(color: c.fg, fontSize: 15, height: 1.7),
                code: TextStyle(
                  color: c.accent,
                  fontSize: 13,
                  backgroundColor: c.codeBg,
                  fontFamily: 'monospace',
                ),
                codeblockDecoration: BoxDecoration(
                  color: c.codeBg,
                  border: Border.all(color: c.border),
                ),
                codeblockPadding: const EdgeInsets.all(10),
                tableBorder: TableBorder.all(color: c.border),
                tableHead: TextStyle(
                  color: c.fg,
                  fontWeight: FontWeight.w600,
                ),
                h2: TextStyle(
                  color: c.fg,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
        else
          TextField(
            controller: _content,
            minLines: 10,
            maxLines: 16,
            onChanged: (_) => _markChanged(),
            style: TextStyle(
              color: c.fg,
              fontSize: 13,
              fontFamily: 'monospace',
              height: 1.6,
            ),
            decoration: const InputDecoration(
              hintText: '支持 Markdown 语法',
              alignLabelWithHint: true,
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Checkbox(
              value: _published,
              onChanged: _saving
                  ? null
                  : (v) {
                      setState(() => _published = v ?? false);
                      _markChanged();
                    },
              activeColor: c.accent,
            ),
            Expanded(
              child: Text(
                '发布状态（勾选为已发布，否则保存为草稿）',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _saving ? null : widget.onBack,
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _saving ? null : () => _submit(_published),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 22),
              ),
              onPressed: _saving ? null : () => _submit(true),
              child: const Text('发布'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field(AppColors c, String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _toolBtn(AppColors c, String label, VoidCallback onTap, {IconData? icon}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface2,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: c.muted),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/* ============ 合集编辑器 ============ */

class _CollectionEditor extends StatefulWidget {
  const _CollectionEditor({
    required this.collection,
    required this.onBack,
    required this.onSaved,
  });

  final Map<String, dynamic>? collection;
  final VoidCallback onBack;
  final VoidCallback onSaved;

  @override
  State<_CollectionEditor> createState() => _CollectionEditorState();
}

class _CollectionEditorState extends State<_CollectionEditor> {
  late final TextEditingController _name;
  late final TextEditingController _slug;
  late final TextEditingController _desc;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.collection == null;

  @override
  void initState() {
    super.initState();
    final c = widget.collection;
    _name = TextEditingController(text: c?['name']?.toString() ?? '');
    _slug = TextEditingController(text: c?['slug']?.toString() ?? '');
    _desc = TextEditingController(text: c?['description']?.toString() ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '合集名称不能为空');
      return;
    }
    final body = {
      'name': name,
      'slug': _slug.text.trim(),
      'description': _desc.text.trim(),
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isNew) {
        await Api.blogCreateCollection(body);
      } else {
        await Api.blogUpdateCollection(widget.collection!['id'] as int, body);
      }
      if (!mounted) return;
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      final handled = await handleAuthError(context, e);
      if (!handled && mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            InkWell(
              onTap: _saving ? null : widget.onBack,
              child: Row(
                children: [
                  Icon(Icons.arrow_back, size: 18, color: c.accent),
                  const SizedBox(width: 4),
                  Text(
                    '返回',
                    style: TextStyle(color: c.accent, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Text(
              _isNew ? '新建合集' : '编辑合集',
              style: TextStyle(
                color: c.fg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            const SizedBox(width: 40),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '名称 *',
          style: TextStyle(
            color: c.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _name,
          autofocus: _isNew,
          decoration: const InputDecoration(hintText: '合集名称'),
        ),
        const SizedBox(height: 12),
        Text(
          'SLUG',
          style: TextStyle(
            color: c.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _slug,
          decoration: const InputDecoration(hintText: '留空自动生成'),
        ),
        const SizedBox(height: 12),
        Text(
          '描述',
          style: TextStyle(
            color: c.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _desc,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '合集简介（列表页展示）'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _saving ? null : widget.onBack,
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 22),
              ),
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ],
    );
  }
}
