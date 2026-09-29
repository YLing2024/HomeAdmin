import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/trend_granularity.dart';

void main() {
  group('档位映射（对齐 Web GRANULARITY_QUERY / WINDOW）', () {
    test('四档 → (range, step, 刷新间隔)', () {
      expect(trendQueryOf(TrendGranularity.sec), isNull);
      expect(
        [trendMinQuery.range, trendMinQuery.step, trendMinQuery.refresh],
        ['1d', '1m', const Duration(seconds: 30)],
      );
      expect(
        [trendHourQuery.range, trendHourQuery.step, trendHourQuery.refresh],
        ['7d', '1h', const Duration(seconds: 300)],
      );
      expect(
        [trendDayQuery.range, trendDayQuery.step, trendDayQuery.refresh],
        ['30d', '1d', const Duration(seconds: 1800)],
      );
      expect(trendQueryOf(TrendGranularity.min), same(trendMinQuery));
      expect(trendQueryOf(TrendGranularity.hour), same(trendHourQuery));
      expect(trendQueryOf(TrendGranularity.day), same(trendDayQuery));
    });

    test('窗口：秒 30，非秒 60', () {
      expect(trendWindow(TrendGranularity.sec), 30);
      expect(trendWindow(TrendGranularity.min), 60);
      expect(trendWindow(TrendGranularity.hour), 60);
      expect(trendWindow(TrendGranularity.day), 60);
    });

    test('id 与显示名', () {
      expect(trendGranularityId(TrendGranularity.sec), 'sec');
      expect(trendGranularityId(TrendGranularity.min), 'min');
      expect(trendGranularityId(TrendGranularity.hour), 'hour');
      expect(trendGranularityId(TrendGranularity.day), 'day');
      expect(
        TrendGranularity.values.map(trendGranularityLabel).toList(),
        ['秒', '分钟', '小时', '天'],
      );
    });
  });

  group('非法档位回退为秒', () {
    test('null / 空串 / 未知 / 大小写不符 / 旧值均回退 sec', () {
      expect(parseTrendGranularity(null), TrendGranularity.sec);
      expect(parseTrendGranularity(''), TrendGranularity.sec);
      expect(parseTrendGranularity('SEC'), TrendGranularity.sec);
      expect(parseTrendGranularity('5m'), TrendGranularity.sec);
      expect(parseTrendGranularity('week'), TrendGranularity.sec);
      expect(parseTrendGranularity(1), TrendGranularity.sec);
    });

    test('四个合法 id 原样解析', () {
      expect(parseTrendGranularity('sec'), TrendGranularity.sec);
      expect(parseTrendGranularity('min'), TrendGranularity.min);
      expect(parseTrendGranularity('hour'), TrendGranularity.hour);
      expect(parseTrendGranularity('day'), TrendGranularity.day);
    });
  });

  group('X 轴刻度格式化', () {
    final ts = DateTime(2026, 9, 29, 14, 5, 7).millisecondsSinceEpoch;

    test('秒 HH:mm:ss', () {
      expect(formatTrendTick(ts, TrendGranularity.sec), '14:05:07');
    });

    test('分钟 HH:mm', () {
      expect(formatTrendTick(ts, TrendGranularity.min), '14:05');
    });

    test('小时 MM-DD HH:00', () {
      expect(formatTrendTick(ts, TrendGranularity.hour), '09-29 14:00');
    });

    test('天 MM-DD', () {
      expect(formatTrendTick(ts, TrendGranularity.day), '09-29');
    });

    test('非数字时间戳按 0（epoch 本地时间）不抛异常', () {
      expect(formatTrendTick(null, TrendGranularity.min), isA<String>());
      expect(formatTrendTick('bad', TrendGranularity.day), isA<String>());
    });
  });

  group('窗口与 offset 计算', () {
    test('空数组：0..0，offset 归零', () {
      final s = computeTrendSlice(
        len: 0,
        window: 60,
        offset: 5,
        follow: false,
      );
      expect([s.start, s.end, s.offset], [0, 0, 0]);
    });

    test('单点：窗口内可见（0..1），非秒档据此画点', () {
      final s = computeTrendSlice(
        len: 1,
        window: 60,
        offset: 0,
        follow: false,
      );
      expect([s.start, s.end], [0, 1]);
      expect(s.end - s.start, 1);
    });

    test('数据不足一窗：全量并归零 offset', () {
      final s = computeTrendSlice(
        len: 10,
        window: 60,
        offset: 7,
        follow: false,
      );
      expect([s.start, s.end, s.offset], [0, 10, 0]);
    });

    test('跟随态：对齐末尾（秒档 30 点）', () {
      final s = computeTrendSlice(
        len: 100,
        window: 30,
        offset: 0,
        follow: true,
      );
      expect([s.start, s.end, s.offset], [70, 100, 70]);
    });

    test('非跟随：保留位置不跳动', () {
      final s = computeTrendSlice(
        len: 100,
        window: 60,
        offset: 20,
        follow: false,
      );
      expect([s.start, s.end, s.offset], [20, 80, 20]);
    });

    test('非跟随且越界：收敛到最大 offset，不回弹末尾', () {
      final s = computeTrendSlice(
        len: 100,
        window: 60,
        offset: 999,
        follow: false,
      );
      expect(s.offset, 40);
      expect([s.start, s.end], [40, 100]);
    });

    test('负数 offset 收敛到 0', () {
      final s = computeTrendSlice(
        len: 100,
        window: 60,
        offset: -5,
        follow: false,
      );
      expect([s.start, s.end, s.offset], [0, 60, 0]);
    });
  });

  group('X 轴标签下标', () {
    test('空 / 单点 / 多点', () {
      expect(trendTickIndices(0), isEmpty);
      expect(trendTickIndices(1), [0]);
      expect(trendTickIndices(2), [0, 1]);
      expect(trendTickIndices(60), [0, 19, 39, 59]);
    });
  });

  group('meta.recordedSeconds → 已记录分钟数', () {
    test('向下取整', () {
      expect(trendRecordedMinutes(0), 0);
      expect(trendRecordedMinutes(59), 0);
      expect(trendRecordedMinutes(60), 1);
      expect(trendRecordedMinutes(3599), 59);
      expect(trendRecordedMinutes(3600), 60);
      expect(trendRecordedMinutes(123.9), 2);
    });

    test('缺失 / 非数字返回 null；负数按 0', () {
      expect(trendRecordedMinutes(null), isNull);
      expect(trendRecordedMinutes('60'), isNull);
      expect(trendRecordedMinutes(-5), 0);
    });
  });

  group('空态文案', () {
    test('带分钟数', () {
      expect(trendAccumulatingText(12), '数据积累中（已记录 12 分钟）');
    });

    test('分钟数缺失按 0', () {
      expect(trendAccumulatingText(null), '数据积累中（已记录 0 分钟）');
    });
  });
}
