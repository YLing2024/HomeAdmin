import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/api.dart';

void main() {
  group('SystemMetrics.fromJson', () {
    test('解析 points 与 meta（点与 history 同构）', () {
      final m = SystemMetrics.fromJson({
        'points': [
          {'ts': 1759000000000, 'cpu': 12.5, 'mem_percent': 40},
          {'ts': 1759000060000, 'cpu': 13.0, 'mem_percent': 41},
        ],
        'meta': {
          'step': '1m',
          'range': '1d',
          'bucketCount': 1440,
          'recordedSeconds': 3600,
        },
      });
      expect(m.points.length, 2);
      expect(m.points.first['cpu'], 12.5);
      expect(m.meta['step'], '1m');
      expect(m.recordedSeconds, 3600);
    });

    test('points 缺失 / 非数组 / 元素非对象 → 空且不抛', () {
      expect(SystemMetrics.fromJson(const {}).points, isEmpty);
      expect(SystemMetrics.fromJson(const {'points': null}).points, isEmpty);
      expect(SystemMetrics.fromJson(const {'points': 'x'}).points, isEmpty);
      expect(
        SystemMetrics.fromJson(const {
          'points': [1, 'x', {'ts': 1}],
        }).points,
        [
          {'ts': 1},
        ],
      );
    });

    test('meta 缺失 / 非对象 → 空，recordedSeconds 为 null', () {
      expect(SystemMetrics.fromJson(const {}).meta, isEmpty);
      expect(SystemMetrics.fromJson(const {'meta': 'x'}).meta, isEmpty);
      expect(SystemMetrics.fromJson(const {}).recordedSeconds, isNull);
      expect(
        SystemMetrics.fromJson(const {
          'meta': {'recordedSeconds': 'not-a-number'},
        }).recordedSeconds,
        isNull,
      );
    });

    test('empty 常量可用于降级', () {
      expect(SystemMetrics.empty.points, isEmpty);
      expect(SystemMetrics.empty.meta, isEmpty);
      expect(SystemMetrics.empty.recordedSeconds, isNull);
    });
  });
}
