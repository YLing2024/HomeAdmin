import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/file_refs.dart';
import 'package:home_admin/image_refs.dart';
import 'package:home_admin/media_tags.dart';

void main() {
  group('parseMediaTags', () {
    test('提取图片标签并清洗文本', () {
      final r = parseMediaTags('看图：MEDIA:/root/pic.png 后面还有文字');
      expect(r.text, '看图： 后面还有文字');
      expect(r.media.length, 1);
      expect(r.media.first.path, '/root/pic.png');
      expect(r.media.first.isImage, true);
    });

    test('支持 ~/ 开头与引号包裹', () {
      final r = parseMediaTags('附件：MEDIA:`~/docs/a.tar.gz` 完');
      expect(r.media.length, 1);
      expect(r.media.first.path, '~/docs/a.tar.gz');
      expect(r.media.first.isImage, false);
      expect(r.text, '附件： 完');
    });

    test('支持反引号包裹与全角标点边界', () {
      final r = parseMediaTags('MEDIA:`/a/b.mp4`，继续');
      expect(r.media.length, 1);
      expect(r.media.first.path, '/a/b.mp4');
      expect(r.media.first.isImage, false);
    });

    test('未知扩展名标签原样保留', () {
      final r = parseMediaTags('MEDIA:/tmp/file.xyzabc');
      expect(r.media.length, 0);
      expect(r.text, 'MEDIA:/tmp/file.xyzabc');
    });

    test('代码块内的 MEDIA 示例不解析', () {
      final r = parseMediaTags('```\nMEDIA:/a/b.png 示例\n```\n正文');
      expect(r.media.length, 0);
    });

    test('行内代码内的 MEDIA 示例不解析（非包裹位置）', () {
      final r = parseMediaTags('用 `请看 MEDIA:/a/b.png 例子` 语法');
      expect(r.media.length, 0);
    });

    test('反引号直接包裹整个 MEDIA: 标签可解析', () {
      final r = parseMediaTags('`MEDIA:/a/b.png`');
      expect(r.media.length, 1);
      expect(r.media.first.path, '/a/b.png');
    });

    test('MEDIA: 后跟反引号路径引用可解析', () {
      final r = parseMediaTags('MEDIA:`/a/b.png`');
      expect(r.media.length, 1);
      expect(r.media.first.path, '/a/b.png');
    });

    test('tar.gz 优先于 tar 截断', () {
      final r = parseMediaTags('MEDIA:/a/archive.tar.gz');
      expect(r.media.length, 1);
      expect(r.media.first.path, '/a/archive.tar.gz');
      expect(r.media.first.ext, 'gz');
    });

    test('多个标签全部提取', () {
      final r = parseMediaTags('图1：MEDIA:/a.png 图2：MEDIA:/b.jpg 文：MEDIA:/c.pdf');
      expect(r.media.length, 3);
      expect(r.text, '图1： 图2： 文：');
    });
  });

  group('parseFileRefs', () {
    test('提取并去重（与 Web 一致：保留最后一次出现的顺序）', () {
      final r = parseFileRefs('看文件 @file:/tmp/a.txt 和 @file:/tmp/b.pdf 再 @file:/tmp/a.txt');
      expect(r.files.length, 2);
      expect(r.files[0].path, '/tmp/b.pdf');
      expect(r.files[1].path, '/tmp/a.txt');
      expect(r.text, '看文件  和  再 ');
    });

    test('引号包裹与 ~/ 路径', () {
      final r = parseFileRefs('附件：@file:`~/x/y.tar.gz` 完毕');
      expect(r.files.length, 1);
      expect(r.files[0].path, '~/x/y.tar.gz');
      expect(r.text, '附件： 完毕');
    });

    test('代码块内不解析', () {
      final r = parseFileRefs('```\n@file:/tmp/a.txt\n```');
      expect(r.files.length, 0);
    });
  });

  group('parseImageRefs', () {
    test('提取并去重，移除引用', () {
      final r = parseImageRefs('照片 @image:/a/b.png 再来 @image:/a/b.png');
      expect(r.images.length, 1);
      expect(r.images.first, '/a/b.png');
      expect(r.text, '照片  再来 ');
    });

    test('反引号包裹', () {
      final r = parseImageRefs('@image:`/a/c.webp`');
      expect(r.images, ['/a/c.webp']);
      expect(r.text, '');
    });
  });

  group('normalizeMediaPath', () {
    test('剥引号与首尾 ASCII 标点', () {
      expect(normalizeMediaPath('`/a/b.png`'), '/a/b.png');
      expect(normalizeMediaPath('"/a/b.png"'), '/a/b.png');
      expect(normalizeMediaPath("/a/b.png',"), '/a/b.png');
      // 全角标点不在剥除集合内（与 Web 一致）
      expect(normalizeMediaPath('/a/b.png。'), '/a/b.png。');
    });
  });
}
