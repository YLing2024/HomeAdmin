import 'dart:math' as math;

/// 趋势粒度档位：秒 / 分钟 / 小时 / 天。
///
/// 权威实现是 `admin-web/src/components/System.jsx`（`GRANULARITY_OPTIONS` /
/// `GRANULARITY_QUERY` / `formatTick` / `clampOffset`）。这里只放**纯逻辑**，
/// 便于单测；UI 与取数留在 `system_page.dart` / `api.dart`。
enum TrendGranularity { sec, min, hour, day }

const Map<TrendGranularity, String> _granularityIds = {
  TrendGranularity.sec: 'sec',
  TrendGranularity.min: 'min',
  TrendGranularity.hour: 'hour',
  TrendGranularity.day: 'day',
};

/// 档位 id（与 Web 的 sessionStorage 取值同名，便于两边对照）。
String trendGranularityId(TrendGranularity g) => _granularityIds[g]!;

/// 档位显示名（中文，与 Web 分段按钮一致）。
String trendGranularityLabel(TrendGranularity g) {
  switch (g) {
    case TrendGranularity.sec:
      return '秒';
    case TrendGranularity.min:
      return '分钟';
    case TrendGranularity.hour:
      return '小时';
    case TrendGranularity.day:
      return '天';
  }
}

/// 非秒档位的聚合取数参数与刷新间隔（对齐 Web `GRANULARITY_QUERY`）。
class TrendQuery {
  const TrendQuery({
    required this.range,
    required this.step,
    required this.refresh,
  });

  /// `range` 白名单值：1h | 6h | 1d | 7d | 30d
  final String range;

  /// `step` 白名单值：1m | 5m | 1h | 1d
  final String step;

  /// 轮询刷新间隔。
  final Duration refresh;
}

const TrendQuery trendMinQuery =
    TrendQuery(range: '1d', step: '1m', refresh: Duration(seconds: 30));
const TrendQuery trendHourQuery =
    TrendQuery(range: '7d', step: '1h', refresh: Duration(seconds: 300));
const TrendQuery trendDayQuery =
    TrendQuery(range: '30d', step: '1d', refresh: Duration(seconds: 1800));

/// 档位 → 聚合取数配置；「秒」档沿用 SSE 实时流，无聚合配置（返回 null）。
TrendQuery? trendQueryOf(TrendGranularity g) {
  switch (g) {
    case TrendGranularity.sec:
      return null;
    case TrendGranularity.min:
      return trendMinQuery;
    case TrendGranularity.hour:
      return trendHourQuery;
    case TrendGranularity.day:
      return trendDayQuery;
  }
}

/// 可视窗口点数：秒档 30（现有行为），非秒档 60（对齐 Web WINDOW / WINDOW_WIDE）。
int trendWindow(TrendGranularity g) =>
    g == TrendGranularity.sec ? 30 : 60;

/// 窗口切片结果。
class TrendSlice {
  const TrendSlice({
    required this.start,
    required this.end,
    required this.offset,
  });

  /// 切片起点下标（含）。
  final int start;

  /// 切片终点下标（不含）。
  final int end;

  /// 边界修正后的有效 offset；跟随态即最大可平移位置。
  final int offset;
}

/// 计算窗口内数据的下标区间，语义与 Web `clampOffset` + `slice(offset, offset + win)` 一致。
///
/// - 空数组 → `(0, 0)`；
/// - 单点 → `(0, 1)`（非秒档据此画点 + 参考线）；
/// - 跟随态 → 对齐末尾；非跟随 → 仅越界时收敛，不回弹。
TrendSlice computeTrendSlice({
  required int len,
  required int window,
  required int offset,
  required bool follow,
}) {
  final maxOffset = math.max(0, len - window);
  final effective = (follow ? maxOffset : offset).clamp(0, maxOffset);
  final end = math.min(len, effective + window);
  return TrendSlice(start: effective, end: end, offset: effective);
}

/// X 轴标签下标：首 / 1/3 / 2/3 / 尾（去重升序），对齐 Web `labelIdx`。
List<int> trendTickIndices(int count) {
  if (count <= 0) return const [];
  if (count == 1) return const [0];
  return <int>{0, (count - 1) ~/ 3, (2 * (count - 1)) ~/ 3, count - 1}.toList()
    ..sort();
}

String _p2(int n) => n.toString().padLeft(2, '0');

/// X 轴刻度格式化（本地时区），对齐 Web `formatTick`：
/// 秒 `HH:mm:ss`、分钟 `HH:mm`、小时 `MM-DD HH:00`、天 `MM-DD`。
String formatTrendTick(Object? ts, TrendGranularity granularity) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts is num ? ts.toInt() : 0);
  switch (granularity) {
    case TrendGranularity.sec:
      return '${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}';
    case TrendGranularity.min:
      return '${_p2(t.hour)}:${_p2(t.minute)}';
    case TrendGranularity.hour:
      return '${_p2(t.month)}-${_p2(t.day)} ${_p2(t.hour)}:00';
    case TrendGranularity.day:
      return '${_p2(t.month)}-${_p2(t.day)}';
  }
}

/// `meta.recordedSeconds` → 已记录分钟数（向下取整）；缺失 / 非数字 / 负数按 0。
int? trendRecordedMinutes(Object? recordedSeconds) {
  if (recordedSeconds is! num) return null;
  final seconds = recordedSeconds.toInt();
  if (seconds <= 0) return 0;
  return seconds ~/ 60;
}

/// 非秒档空数据占位文案（对齐 Web）：`N` 为已记录分钟数，缺失按 0。
String trendAccumulatingText(int? recordedMinutes) =>
    '数据积累中（已记录 ${recordedMinutes ?? 0} 分钟）';
