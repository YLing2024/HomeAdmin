// MEDIA: 标签解析（移植自 Web 端 mediaTags.js，保持行为一致）
//
// 官方在回复文本里输出 `MEDIA:<path>` 表示附带图片/文件；TUI 网关（WS）不处理该标签，
// 原样保留在 message.complete 的 text 里，由前端自行解析展示：
//  - 提取标签（可选引号/反引号/强调包裹，路径支持 / 与 ~/ 开头）；
//  - 从文本中移除标签（清洗），只显示普通 markdown；
//  - 代码块 / 行内代码内的 MEDIA: 示例不解析（受保护片段跳过）。
library;

/// 图片扩展名：渲染为缩略图 + lightbox
const Set<String> kMediaImageExts = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic', 'heif', 'avif', 'tiff',
};

/// 其他文件扩展名：渲染为文件卡片
const Set<String> kMediaFileExts = {
  'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp',
  'mp3', 'm2a', 'wav', 'ogg', 'opus', 'm4a', 'flac',
  'pdf', 'docx', 'doc', 'odt', 'rtf', 'txt', 'md', 'epub',
  'xlsx', 'xls', 'ods', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml',
  'kmz', 'kml', 'geojson', 'gpx',
  'pptx', 'ppt', 'odp', 'key',
  'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'apk', 'ipa',
  'html', 'htm',
};

const Set<String> kMediaAllExts = {...kMediaImageExts, ...kMediaFileExts};

final String _mediaExtAlt = (kMediaAllExts.toList()..sort((a, b) => b.length.compareTo(a.length))).join('|');

// 仿官方 MEDIA_TAG_CLEANUP_RE：可选引号/反引号/强调包裹，路径支持 / ~/ 盘符开头。
// 路径到空白/标点边界，扩展名必须在白名单内；未知扩展名标签原样留在文本里。
final RegExp _mediaTagRe = RegExp(
  r'''[`"'*_]{0,3}MEDIA:\s*(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:EXT_ALT))(?=[\s`"'*_,;:)\]}\[]|MEDIA:|\.(?:\s|$)|[。，、；：！？（）「」『』《》〈〉“”‘’·…]|$)[`"'*_]{0,3}\.?'''
      .replaceAll('EXT_ALT', _mediaExtAlt),
  caseSensitive: false,
);

/// 掩码定位 fenced 代码块 + 行内代码的 [start, end) 区间（保持原文本偏移）。
/// tag 参数支持 MEDIA:/@file: 等标签复用同一套保护机制。
List<List<int>> findProtectedRanges(String text, [String tag = 'MEDIA:']) {
  final ranges = <List<int>>[];
  final lines = text.split('\n');
  var pos = 0;
  final fenceRe = RegExp(r'^\s*(`{3,}|~{3,})');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final fence = fenceRe.firstMatch(line);
    if (fence != null) {
      final ch = fence.group(1)![0];
      final min = fence.group(1)!.length;
      final closeRe = RegExp('^\\s*$ch{$min,}');
      var j = i + 1;
      while (j < lines.length && !closeRe.hasMatch(lines[j])) {
        j++;
      }
      final last = j >= lines.length ? lines.length - 1 : j;
      var end = pos;
      for (var k = i; k <= last; k++) {
        end += lines[k].length + 1;
      }
      ranges.add([pos, end]);
      for (var k = i; k <= last; k++) {
        pos += lines[k].length + 1;
      }
      i = last;
    } else {
      pos += line.length + 1;
    }
  }
  // 行内代码：整体为 `TAG:path`（反引号包裹标签）或 TAG: 后的反引号路径引用
  // 不算受保护片段，其余行内代码 span（含 TAG: 示例的更大代码片段）一律保护。
  final tagEsc = RegExp.escape(tag);
  final pathQuoteRe = RegExp(tagEsc + r'\s*$');
  final wrappedTagRe = RegExp('^$tagEsc', caseSensitive: false);
  final inlineRe = RegExp(r'`([^`\n]+)`');
  for (final mm in inlineRe.allMatches(text)) {
    final prefix = text.substring(0, mm.start);
    final inner = mm.group(1)!.trim();
    final isPathQuote = pathQuoteRe.hasMatch(prefix);
    final isWrappedTag = wrappedTagRe.hasMatch(inner);
    if (isPathQuote || isWrappedTag) continue;
    ranges.add([mm.start, mm.end]);
  }
  return ranges;
}

/// 归一化路径：剥掉引号/反引号包裹与首尾标点（同官方 _normalize_media_tag_path）
String normalizeMediaPath(String raw) {
  var p = raw.trim();
  if (p.length >= 2 && p[0] == p[p.length - 1] && '`"\' '.contains(p[0])) {
    p = p.substring(1, p.length - 1).trim();
  }
  return p
      .replaceFirst(RegExp(r'''^[`"']+'''), '')
      .replaceFirst(RegExp(r'''[`"',.;:)}\]]+$'''), '');
}

/// 解析出的媒体项
class MediaTag {
  final String path;
  final String ext;
  final bool isImage;
  const MediaTag(this.path, this.ext, {required this.isImage});
}

class MediaParseResult {
  final String text;
  final List<MediaTag> media;
  const MediaParseResult(this.text, this.media);
}

/// 提取并清洗 MEDIA 标签
MediaParseResult parseMediaTags(String text) {
  if (text.isEmpty || !RegExp(r'MEDIA:', caseSensitive: false).hasMatch(text)) {
    return MediaParseResult(text, const []);
  }
  final protectedRanges = findProtectedRanges(text);
  bool isProtected(int start, int end) =>
      protectedRanges.any((r) => start < r[1] && end > r[0]);

  final found = <_FoundTag>[];
  for (final m in _mediaTagRe.allMatches(text)) {
    final path = normalizeMediaPath(m.group(1) ?? '');
    if (path.isEmpty) continue;
    final extMatch = RegExp(r'\.([a-z0-9]+)$', caseSensitive: false).firstMatch(path);
    final ext = extMatch != null ? extMatch.group(1)!.toLowerCase() : '';
    if (!kMediaAllExts.contains(ext)) continue;
    final start = m.start;
    final end = m.end;
    if (isProtected(start, end)) continue;
    found.add(_FoundTag(path, ext, start, end, isImage: kMediaImageExts.contains(ext)));
  }
  if (found.isEmpty) return MediaParseResult(text, const []);
  var clean = text;
  for (var i = found.length - 1; i >= 0; i--) {
    clean = clean.substring(0, found[i].start) + clean.substring(found[i].end);
  }
  return MediaParseResult(
    clean,
    found.map((f) => MediaTag(f.path, f.ext, isImage: f.isImage)).toList(),
  );
}

class _FoundTag {
  final String path;
  final String ext;
  final int start;
  final int end;
  final bool isImage;
  const _FoundTag(this.path, this.ext, this.start, this.end, {required this.isImage});
}
