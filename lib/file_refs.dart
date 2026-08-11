// @file: 引用解析（文件附件历史持久化格式，移植自 Web 端 fileRefs.js）
//
// 发送文件时前端把服务器绝对路径拼进 prompt text：`@file:/abs/path`（多个换行分隔），
// agent 的文件工具据此读取服务器文件；user 消息 text 按原样落库，resume 时含该引用。
//  - 从文本中提取路径（可选引号/反引号包裹，路径支持 / ~/ 盘符开头）；
//  - 从文本中移除引用，不显示 @file: 字样；
//  - 代码块 / 行内代码内的 @file: 示例不解析（受保护片段跳过，与 MEDIA 一致）；
//  - 按出现顺序去重返回文件数组。
library;

import 'media_tags.dart';

// @file: 后到行尾/空白/标点的路径；兼容引号包裹（`path` / "path" / 'path'）。
final RegExp _fileRefRe = RegExp(
  r'''([`"'*_]{0,3})@file:\s*(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|(?:~/|/|[A-Za-z]:[\\/])[^\s`"',;:)\]}>、，。；：！？（）「」『』《》〈〉“”‘’·…]+)[`"'*_]{0,3}''',
  caseSensitive: false,
);

/// 归一化路径：剥掉引号/反引号包裹与首尾标点
String normalizeFileRefPath(String raw) {
  var p = raw.trim();
  if (p.length >= 2 && p[0] == p[p.length - 1] && '`"\' '.contains(p[0])) {
    p = p.substring(1, p.length - 1).trim();
  }
  return p
      .replaceFirst(RegExp(r'''^[`"']+'''), '')
      .replaceFirst(RegExp(r'''[`"',.;:)}\]]+$'''), '');
}

/// 提取路径扩展名（无则返回空串，走通用附件图标）
String extOf(String path) {
  final m = RegExp(r'\.([a-z0-9]+)$', caseSensitive: false).firstMatch(path);
  return m != null ? m.group(1)!.toLowerCase() : '';
}

class FileRef {
  final String path;
  final String ext;
  const FileRef(this.path, this.ext);
}

class FileRefParseResult {
  final String text;
  final List<FileRef> files;
  const FileRefParseResult(this.text, this.files);
}

/// 解析文本中的 @file:<路径> 引用
FileRefParseResult parseFileRefs(String text) {
  if (text.isEmpty || !RegExp(r'@file:', caseSensitive: false).hasMatch(text)) {
    return FileRefParseResult(text, const []);
  }
  final protectedRanges = findProtectedRanges(text, '@file:');
  bool isProtected(int start, int end) =>
      protectedRanges.any((r) => start < r[1] && end > r[0]);

  final found = <({String path, String ext, int start, int end})>[];
  for (final m in _fileRefRe.allMatches(text)) {
    final path = normalizeFileRefPath(m.group(2) ?? '');
    if (path.isEmpty) continue;
    final start = m.start;
    final end = m.end;
    if (isProtected(start, end)) continue;
    found.add((path: path, ext: extOf(path), start: start, end: end));
  }
  if (found.isEmpty) return FileRefParseResult(text, const []);
  final files = <FileRef>[];
  final seen = <String>{};
  var clean = text;
  for (var i = found.length - 1; i >= 0; i--) {
    final f = found[i];
    if (!seen.contains(f.path)) {
      seen.add(f.path);
      files.insert(0, FileRef(f.path, f.ext));
    }
    clean = clean.substring(0, f.start) + clean.substring(f.end);
  }
  return FileRefParseResult(clean, files);
}
