import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_admin/system_page.dart';
import 'package:home_admin/theme.dart';
import 'package:home_admin/trend_granularity.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

TrendChart _chart({
  required TrendGranularity granularity,
  required List<Map<String, dynamic>> history,
  int? recordedMinutes,
}) {
  return TrendChart(
    title: '测试趋势',
    chartId: 'test',
    granularity: granularity,
    recordedMinutes: recordedMinutes,
    history: history,
    series: const [TrendSeries('cpu', 'CPU')],
    yMax: 100,
    yLabel: '%',
    fmtValue: (v) => '${v.toStringAsFixed(1)}%',
  );
}

List<Map<String, dynamic>> _points(int n) => [
      for (var i = 0; i < n; i++)
        {'ts': 1759000000000 + i * 60000, 'cpu': 10.0 + i},
    ];

void main() {
  testWidgets('秒档不足 2 点：仍是「数据采集中」占位（R5 未回归）', (tester) async {
    await tester.pumpWidget(
      _host(_chart(granularity: TrendGranularity.sec, history: _points(1))),
    );
    expect(find.text('数据采集中…（约 3 秒后显示趋势）'), findsOneWidget);
  });

  testWidgets('非秒档空数据：显示「数据积累中（已记录 N 分钟）」（R6）', (tester) async {
    await tester.pumpWidget(
      _host(_chart(
        granularity: TrendGranularity.min,
        history: const [],
        recordedMinutes: 12,
      )),
    );
    expect(find.text('数据积累中（已记录 12 分钟）'), findsOneWidget);
  });

  testWidgets('非秒档空数据且 meta 缺失：N 按 0（R6）', (tester) async {
    await tester.pumpWidget(
      _host(_chart(granularity: TrendGranularity.hour, history: const [])),
    );
    expect(find.text('数据积累中（已记录 0 分钟）'), findsOneWidget);
  });

  testWidgets('非秒档单点：可见并渲染（画点 + 参考线）（R6）', (tester) async {
    await tester.pumpWidget(
      _host(_chart(
        granularity: TrendGranularity.day,
        history: _points(1),
        recordedMinutes: 1,
      )),
    );
    expect(find.text('数据积累中（已记录 1 分钟）'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('非秒档多点：窗口内正常渲染，不出现采集/积累占位（R2/R6）', (tester) async {
    await tester.pumpWidget(
      _host(_chart(granularity: TrendGranularity.min, history: _points(120))),
    );
    expect(find.textContaining('数据采集中'), findsNothing);
    expect(find.textContaining('数据积累中'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('追加数据后跟随最新，不出现「回最新」按钮（跟随态）', (tester) async {
    await tester.pumpWidget(
      _host(_chart(granularity: TrendGranularity.sec, history: _points(10))),
    );
    expect(find.text('回最新'), findsNothing);
    await tester.pumpWidget(
      _host(_chart(granularity: TrendGranularity.sec, history: _points(80))),
    );
    await tester.pump();
    expect(find.text('回最新'), findsNothing);
  });
}
