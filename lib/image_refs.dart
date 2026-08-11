// @image: 引用解析（Hermes 历史持久化格式，移植自 Web 端 imageRefs.js）
//
// 带图 user 消息落库为文本引用 `@image:/abs/path`，session.resume 返回的消息 text
// 字段内含该引用，且没有独立的 images 字段。
//  - 从文本中提取路径（可选引号/反引号包裹，路径支持 / ~/ 盘符开头）；
//  - 从文本中移除引用，不显示 @image: 字样；
//  - 按出现顺序去重返回路径数组，供消息 images 字段渲染。
library;

// @image: 后到行尾/空白/标点的路径；兼容引号包裹（`path` / "path" / 'path'）。
final RegExp _imageRefRe = RegExp(
  r'''([`"'*_]{0,3})@image:\s*(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|(?:~/|/|[A-Za-z]:[\\/])[^\s`"',;:)\]}>、，。；：！？（）「」『』《》〈〉“”‘’·…]+)[`"'*_]{0,3}''',
  caseSensitive: false,
);

/// 归一化路径：剥掉引号/反引号包裹与首尾标点
String normalizeImageRefPath(String raw) {
  var p = raw.trim();
  if (p.length >= 2 && p[0] == p[p.length - 1] && '`"\' '.contains(p[0])) {
    p = p.substring(1, p.length - 1).trim();
  }
  return p
      .replaceFirst(RegExp(r'''^[`"']+'''), '')
      .replaceFirst(RegExp(r'''[`"',.;:)}\]]+$'''), '');
}

class ImageRefParseResult {
  final String text;
  final List<String> images;
  const ImageRefParseResult(this.text, this.images);
}

/// 解析文本中的 @image:<路径> 引用
ImageRefParseResult parseImageRefs(String text) {
  if (text.isEmpty || !RegExp(r'@image:', caseSensitive: false).hasMatch(text)) {
    return ImageRefParseResult(text, const []);
  }
  final found = <({String path, int start, int end})>[];
  for (final m in _imageRefRe.allMatches(text)) {
    final path = normalizeImageRefPath(m.group(2) ?? '');
    if (path.isEmpty) continue;
    found.add((path: path, start: m.start, end: m.end));
  }
  if (found.isEmpty) return ImageRefParseResult(text, const []);
  final images = <String>[];
  final seen = <String>{};
  var clean = text;
  for (var i = found.length - 1; i >= 0; i--) {
    final f = found[i];
    if (!seen.contains(f.path)) {
      seen.add(f.path);
      images.insert(0, f.path);
    }
    clean = clean.substring(0, f.start) + clean.substring(f.end);
  }
  return ImageRefParseResult(clean, images);
}
