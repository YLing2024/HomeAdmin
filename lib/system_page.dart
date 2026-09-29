import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';
import 'trend_granularity.dart';

class SystemPage extends StatefulWidget {
  const SystemPage({super.key, this.active = true});

  /// 是否处于可见 Tab：SSE 仅在激活时建连，切走立即断开（对齐 Web System.jsx）
  final bool active;

  @override
  State<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends State<SystemPage> {
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _processes = [];
  List<Map<String, dynamic>> _services = [];
  double? _totalCpu; // 全部进程 CPU 合计（SSE services.total_cpu）
  String? _error;
  DateTime? _updated; // 最近一次快照时间（对齐 Web「更新于」）
  String _procSort = 'mem';

  // 趋势粒度：App 会话内记忆（State 随 IndexedStack 常驻），退出 App 回默认「秒」（对齐 Web sessionStorage）
  TrendGranularity _granularity = TrendGranularity.sec;
  List<Map<String, dynamic>> _granPoints = []; // 非秒档最近一帧（请求失败保留，不清空）
  int? _granRecordedMinutes; // 非秒档 meta.recordedSeconds 的分钟数（空态文案用）
  final Map<TrendGranularity, List<Map<String, dynamic>>> _granCache = {}; // 各档独立缓存
  final Map<TrendGranularity, int> _granMetaMinutes = {}; // 各档 meta 分钟数缓存
  Timer? _granTimer;

  SystemStreamHandle? _stream;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _connect();
      _syncGranularityPolling();
    }
  }

  @override
  void didUpdateWidget(covariant SystemPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _connect(); // 切回系统 Tab：重新建连
      _syncGranularityPolling();
    } else if (!widget.active && oldWidget.active) {
      _disconnect(); // 切走：立即断开，零残留
      _syncGranularityPolling(); // 同时停掉非秒档轮询
    }
  }

  @override
  void dispose() {
    _disconnect();
    _granTimer?.cancel();
    super.dispose();
  }

  void _disconnect() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _stream?.cancel();
    _stream = null;
  }

  void _connect() {
    _disconnect();
    _stream = Api.systemStream(
      onSnapshot: _onSnapshot,
      onError: (err) {
        if (!mounted) return;
        setState(() => _error = '连接已断开，正在重连…');
      },
      onDone: _scheduleReconnect,
    );
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    // 连接断开（或流结束）且 Tab 仍激活：5s 后自动重试
    if (!widget.active) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && widget.active) _connect();
    });
  }

  void _onSnapshot(Map<String, dynamic> snapshot) {
    if (!mounted) return;
    final system = snapshot['system'];
    final hist = snapshot['history'];
    final servicesRaw = snapshot['services'];
    final services = servicesRaw is Map ? servicesRaw : <String, dynamic>{};
    setState(() {
      _data = (system is Map) ? Map<String, dynamic>.from(system) : null;
      _history = (hist is List)
          ? hist.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
          : [];
      final s = services['services'];
      final p = services['processes'];
      _services = (s is List)
          ? s.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
          : [];
      _processes = (p is List)
          ? p.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
          : [];
      _totalCpu = services['total_cpu'] is num
          ? (services['total_cpu'] as num).toDouble()
          : null;
      _updated = DateTime.now();
      _error = null;
    });
  }

  /* ============ 格式化 ============ */

  String _fmtBytes(num? b) {
    if (b == null) return '—';
    final v = b.toDouble();
    if (v >= 1024 * 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} TB';
    }
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (v >= 1024 * 1024) {
      return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(1)} KB';
    return '${v.toStringAsFixed(1)} B';
  }

  String _fmtMB(num? mb) {
    if (mb == null) return '—';
    final v = mb.toDouble();
    return v == v.roundToDouble() ? '${v.toInt()} MB' : '${v.toStringAsFixed(1)} MB';
  }

  String _fmtRate(num? r) {
    if (r == null) return '—';
    return '${_fmtBytes(r)}/s';
  }

  String _fmtUptime(num? sec) {
    if (sec == null) return '刚刚';
    final s = sec.toInt();
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final parts = <String>[
      if (d > 0) '$d 天',
      if (h > 0) '$h 小时',
      if (m > 0) '$m 分钟',
    ];
    return parts.isEmpty ? '刚刚' : parts.join(' ');
  }

  String _fmtLoad(dynamic load) {
    if (load is List) {
      return load
          .whereType<num>()
          .map((x) => x.toStringAsFixed(2))
          .join(' / ');
    }
    if (load is String) return load;
    return '—';
  }

  double _pct(dynamic v) => v is num ? v.toDouble() : 0.0;
  num _num(dynamic v) => v is num ? v : 0;

  String _fmtClock(DateTime t) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}';
  }

  /// 手动刷新：重连 SSE 立即拉取最新快照；非秒档同时重拉聚合数据
  Future<void> _reconnect() async {
    _connect();
    _syncGranularityPolling();
  }

  /* ============ 趋势粒度（对齐 Web System.jsx） ============ */

  /// 切档：立即改档并按新档取数（秒档无轮询，用 SSE）。
  void _selectGranularity(TrendGranularity g) {
    if (g == _granularity) return;
    setState(() => _granularity = g);
    _syncGranularityPolling();
  }

  /// 按当前档位重设取数：秒档停轮询；非秒档先渲染该档缓存再立即拉一次，
  /// 之后按档位间隔轮询（30s / 300s / 1800s）。切走 Tab 时不请求。
  void _syncGranularityPolling() {
    _granTimer?.cancel();
    _granTimer = null;
    final query = trendQueryOf(_granularity);
    if (!widget.active || query == null) return;
    final cached = _granCache[_granularity];
    if (cached != null) {
      // 切回已取过的档位：先渲染缓存，避免闪空（R4）
      _granPoints = cached;
      final minutes = _granMetaMinutes[_granularity];
      if (minutes != null) _granRecordedMinutes = minutes;
    }
    unawaited(_loadGranularity());
    _granTimer = Timer.periodic(
      query.refresh,
      (_) => unawaited(_loadGranularity()),
    );
  }

  /// 非秒档拉取聚合点。失败保留上一帧，不弹错、不阻断页面（R4 / R11）。
  Future<void> _loadGranularity() async {
    final g = _granularity;
    final query = trendQueryOf(g);
    if (query == null) return;
    try {
      final metrics = await Api.systemMetrics(
        range: query.range,
        step: query.step,
      );
      if (!mounted || _granularity != g) return;
      setState(() {
        _granPoints = metrics.points;
        _granCache[g] = metrics.points;
        final minutes = trendRecordedMinutes(metrics.recordedSeconds);
        if (minutes != null) {
          _granRecordedMinutes = minutes;
          _granMetaMinutes[g] = minutes;
        }
      });
    } catch (_) {
      // 保留上一帧，静默等下次刷新
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = _data;
    return RefreshIndicator(
      onRefresh: () async => _reconnect(),
      color: c.accent,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Spacer(),
              Text(
                '系统监控',
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
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.center,
            child: Text(
              _updated == null
                  ? '更新于 --'
                  : '更新于 ${_fmtClock(_updated!)}',
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
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
          if (data == null)
            const Padding(
              padding: EdgeInsets.only(top: 140),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            _metricGrid(data, c),
            const SizedBox(height: 12),
            _diskSection(data, c),
            if (_processes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _processBlock(c),
            ],
            const SizedBox(height: 12),
            _trendBlock(c),
          ],
        ],
      ),
    );
  }

  /* ============ 指标卡片 ============ */

  Widget _metricGrid(Map<String, dynamic> data, AppColors c) {
    final cpu = data['cpu'] is Map ? data['cpu'] as Map : const {};
    final mem = data['memory'] is Map ? data['memory'] as Map : const {};
    final net = data['network'] is Map ? data['network'] as Map : const {};
    final io = data['disk_io'] is Map ? data['disk_io'] as Map : const {};
    final procs = data['processes'] is Map ? data['processes'] as Map : const {};
    final cpuUsage = _pct(cpu['usage_percent']);
    final memPercent = _pct(mem['percent']);

    final cpuCard = PanelCard(
      title: 'CPU',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${cpuUsage.toStringAsFixed(1)}%',
            style: TextStyle(
              color: c.fg,
              fontSize: 38,
              fontWeight: FontWeight.w200,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          MetricBar(percent: cpuUsage),
          _coreGrid(cpu['per_core'], c),
          const SizedBox(height: 10),
          _kv(c, '型号', (cpu['model'] ?? '-').toString()),
          _kv(c, '核心数', (cpu['cores'] ?? '-').toString()),
          _kv(
            c,
            '进程',
            '${_num(procs['running'])} / ${_num(procs['total'])}',
          ),
          _kv(c, '负载 (1/5/15m)', _fmtLoad(cpu['loadavg'])),
        ],
      ),
    );

    final memCard = PanelCard(
      title: '内存',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${memPercent.toStringAsFixed(1)}%',
            style: TextStyle(
              color: c.fg,
              fontSize: 38,
              fontWeight: FontWeight.w200,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          MetricBar(percent: memPercent),
          const SizedBox(height: 10),
          _kv(c, '已用（不含缓存）', _fmtBytes(_num(mem['used']))),
          _kv(
            c,
            '可用',
            mem['available'] == null ? '—' : _fmtBytes(_num(mem['available'])),
          ),
          _kv(
            c,
            '其中缓存（可回收）',
            mem['buffCache'] == null ? '—' : _fmtBytes(_num(mem['buffCache'])),
          ),
          _kv(
            c,
            '剩余 / 总计',
            '${_fmtBytes(_num(mem['free']))} / ${_fmtBytes(_num(mem['total']))}',
          ),
        ],
      ),
    );

    // Swap 卡（对齐 Web）：无 swap 时显示 0% + 备注
    final swapTotal = _num(mem['swapTotal']);
    final hasSwap = swapTotal > 0;
    final zram =
        mem['zram'] is Map ? Map<String, dynamic>.from(mem['zram'] as Map) : null;
    final swapPercent = _pct(mem['swapPercent']);
    final swapCard = PanelCard(
      title: 'Swap',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasSwap ? '${swapPercent.toStringAsFixed(1)}%' : '0%',
            style: TextStyle(
              color: hasSwap ? c.fg : c.muted,
              fontSize: 38,
              fontWeight: FontWeight.w200,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          MetricBar(percent: hasSwap ? swapPercent : 0),
          const SizedBox(height: 10),
          if (hasSwap) ...[
            _kv(c, '已用', _fmtBytes(_num(mem['swapUsed']))),
            _kv(
              c,
              '剩余 / 总计',
              '${_fmtBytes(_num(mem['swapFree']))} / ${_fmtBytes(_num(mem['swapTotal']))}',
            ),
            _kv(
              c,
              zram == null ? 'zram' : 'zram (${zram['algorithm'] ?? 'lz4'})',
              zram == null
                  ? '无'
                  : '${_fmtBytes(_num(zram['used']))} / ${_fmtBytes(_num(zram['total']))}',
            ),
          ] else ...[
            _kv(c, 'zram', '无'),
            _kv(c, '备注', '本机未配置 swap'),
          ],
        ],
      ),
    );

    // PSI 压力卡（对齐 Web）：some/full avg10，压力越大越警示
    final psi = data['psi'] is Map ? data['psi'] as Map : const {};
    final psiCard = PanelCard(
      title: 'PSI 压力',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _psiRow(c, '内存 (memory)', psi['memory']),
          _psiRow(c, 'CPU', psi['cpu']),
          _psiRow(c, 'I/O', psi['io']),
          _kv(c, '说明', 'avg10 压力 · some/full'),
        ],
      ),
    );

    final sysCard = PanelCard(
      title: '系统',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(c, '主机名', (data['hostname'] ?? '-').toString()),
          _kv(c, '操作系统', (data['os'] ?? '-').toString()),
          _kv(c, '运行时长', _fmtUptime(data['uptime'] is num ? data['uptime'] as num : null)),
        ],
      ),
    );

    final netCard = PanelCard(
      title: '网络',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(c, '↓ 下载', _fmtRate(net['rx_rate'] is num ? net['rx_rate'] as num : null), amber: true),
          _kv(c, '↑ 上传', _fmtRate(net['tx_rate'] is num ? net['tx_rate'] as num : null)),
          _kv(c, '累计下载', _fmtBytes(_num(net['rx_bytes']))),
          _kv(c, '累计上传', _fmtBytes(_num(net['tx_bytes']))),
        ],
      ),
    );

    final ioCard = PanelCard(
      title: '磁盘 I/O',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _rateStat(c, '读', _fmtRate(io['read_rate'] is num ? io['read_rate'] as num : null), amber: true),
              ),
              _vDivider(c),
              Expanded(
                child: _rateStat(c, '写', _fmtRate(io['write_rate'] is num ? io['write_rate'] as num : null)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _rateStat(c, '累计读', _fmtBytes(_num(io['read_bytes'])))),
              _vDivider(c),
              Expanded(child: _rateStat(c, '累计写', _fmtBytes(_num(io['write_bytes'])))),
            ],
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            children: [
              cpuCard,
              const SizedBox(height: 12),
              memCard,
              const SizedBox(height: 12),
              swapCard,
              const SizedBox(height: 12),
              psiCard,
              const SizedBox(height: 12),
              sysCard,
              const SizedBox(height: 12),
              netCard,
              const SizedBox(height: 12),
              ioCard,
            ],
          );
        }
        return Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cpuCard),
                const SizedBox(width: 12),
                Expanded(child: memCard),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: swapCard),
                const SizedBox(width: 12),
                Expanded(child: psiCard),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: sysCard),
                const SizedBox(width: 12),
                Expanded(child: netCard),
              ],
            ),
            const SizedBox(height: 12),
            ioCard,
          ],
        );
      },
    );
  }

  /// 每核负载网格（对齐 Web CoreGrid）：per_core 缺失或空数组时整块不渲染，
  /// 窄屏按可用宽度自动换列，不产生横向滚动。
  Widget _coreGrid(dynamic raw, AppColors c) {
    final cores =
        raw is List ? raw.whereType<Map>().toList(growable: false) : const [];
    if (cores.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          final width = constraints.maxWidth;
          final cols = width < 300 ? 2 : (width < 460 ? 3 : 4);
          final itemW = (width - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < cores.length; i++)
                SizedBox(
                  width: itemW,
                  child: _coreCell(c, cores[i], i),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _coreCell(AppColors c, dynamic raw, int index) {
    final core = raw is Map ? raw : const {};
    final id = core['id'] ?? index;
    final percent = _pct(core['usage_percent']).clamp(0.0, 100.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '#$id',
              style: TextStyle(
                color: c.muted,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            Text(
              '${percent.toStringAsFixed(1)}%',
              style: TextStyle(
                color: c.fg,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        // 颜色分级复用 MetricBar 规则（>80 红 / 60-80 橙 / <60 绿）
        MetricBar(percent: percent, height: 3),
      ],
    );
  }

  /// 磁盘区：有 disks 列表时每块盘一张卡，缺失/空时回退旧单盘卡（不白屏）
  Widget _diskSection(Map<String, dynamic> data, AppColors c) {
    final raw = data['disks'];
    final disks = raw is List
        ? raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : <Map<String, dynamic>>[];
    if (disks.isEmpty) return _diskCard(data['disk'], c);
    return Column(
      children: [
        for (var i = 0; i < disks.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _diskCard(
            disks[i],
            c,
            title: (disks[i]['mount'] ?? '').toString().trim().isEmpty
                ? '磁盘'
                : '磁盘 ${(disks[i]['mount']).toString().trim()}',
          ),
        ],
      ],
    );
  }

  Widget _diskCard(dynamic diskRaw, AppColors c, {String title = '磁盘'}) {
    final disk = diskRaw is Map ? diskRaw : null;
    if (disk == null) return const SizedBox.shrink();
    final percent = _pct(disk['percent']);
    return PanelCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '已用 ${_fmtBytes(_num(disk['used']))}',
                style: TextStyle(
                  color: c.fg,
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${percent.toStringAsFixed(0)}% · 共 ${_fmtBytes(_num(disk['total']))}',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          MetricBar(percent: percent),
          const SizedBox(height: 10),
          _kv(c, '剩余 / 总', '${_fmtBytes(_num(disk['free']))} / ${_fmtBytes(_num(disk['total']))}'),
        ],
      ),
    );
  }

  /* ============ 进程排行 ============ */

  Widget _processBlock(AppColors c) {
    final sorted = List<Map<String, dynamic>>.from(_processes);
    if (_procSort == 'name') {
      sorted.sort((a, b) => (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    } else if (_procSort == 'cpu') {
      sorted.sort((a, b) => (_num(b['cpu'])).compareTo(_num(a['cpu'])));
    } else {
      sorted.sort((a, b) => (_num(b['mem_mb'])).compareTo(_num(a['mem_mb'])));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const BlockTitle('进程排行'),
            const Spacer(),
            _sortBtn(c, '名称', 'name'),
            const SizedBox(width: 4),
            _sortBtn(c, '内存', 'mem'),
            const SizedBox(width: 4),
            _sortBtn(c, 'CPU', 'cpu'),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: c.surface2,
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(child: _headLabel(c, '进程')),
                    SizedBox(width: 56, child: _headLabel(c, 'PID', right: true)),
                    SizedBox(width: 64, child: _headLabel(c, '内存', right: true)),
                    SizedBox(width: 60, child: _headLabel(c, 'CPU', right: true)),
                  ],
                ),
              ),
              for (final p in sorted)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      StatusDot(up: _serviceUp(p['pid'])),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (p['name'] ?? '-').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.fg, fontSize: 12.5),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '${p['pid']}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                          _fmtMB(_num(p['mem_mb'])),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: c.fg,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 60,
                        child: Text(
                          '${_num(p['cpu']).toDouble().toStringAsFixed(1)}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // 合计行（对齐 Web：合计（全部进程） + CPU 列）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.border, width: 0.5)),
                ),
                child: Row(
                  children: [
                    StatusDot(up: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '合计（全部进程）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(width: 56, child: Text('', style: TextStyle(color: c.muted, fontSize: 12))),
                    SizedBox(width: 64, child: Text('', style: TextStyle(color: c.fg, fontSize: 12))),
                    SizedBox(
                      width: 60,
                      child: Text(
                        _totalCpu == null ? '—' : '${_totalCpu!.toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: c.fg,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _serviceUp(dynamic pid) {
    for (final s in _services) {
      if ('${s['pid']}' == '$pid') {
        return s['status'] != 'down';
      }
    }
    return true;
  }

  Widget _sortBtn(AppColors c, String label, String key) {
    final active = _procSort == key;
    return InkWell(
      onTap: () => setState(() => _procSort = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  /* ============ 趋势图 ============ */

  Widget _trendBlock(AppColors c) {
    final sparse = _granularity != TrendGranularity.sec;
    // 秒档沿用 SSE 实时 history；非秒档用聚合接口结果（R10）
    final trend = sparse ? _granPoints : _history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const BlockTitle('趋势'),
            const Spacer(),
            _granularityBar(c),
          ],
        ),
        const SizedBox(height: 8),
        TrendChart(
          title: 'CPU / 内存 / Swap（%）',
          chartId: 'mem',
          granularity: _granularity,
          recordedMinutes: _granRecordedMinutes,
          history: trend,
          series: const [
            TrendSeries('cpu', 'CPU', tone: TrendTone.muted),
            TrendSeries('mem_percent', '物理内存', tone: TrendTone.accent),
            TrendSeries('swap_percent', 'Swap', tone: TrendTone.ok),
          ],
          yMax: 100,
          yLabel: '%',
          fmtValue: (v) => '${v.toStringAsFixed(1)}%',
        ),
        const SizedBox(height: 12),
        TrendChart(
          title: 'PSI 压力 · some avg10（%）',
          chartId: 'psi',
          granularity: _granularity,
          recordedMinutes: _granRecordedMinutes,
          history: trend,
          series: const [
            TrendSeries('psi_mem_avg10', '内存', tone: TrendTone.danger),
            TrendSeries('psi_cpu_avg10', 'CPU', tone: TrendTone.accent),
            TrendSeries('psi_io_avg10', 'I/O', tone: TrendTone.muted),
          ],
          yMax: 100,
          yLabel: '%',
          fmtValue: (v) => '${v.toStringAsFixed(1)}%',
        ),
        const SizedBox(height: 12),
        TrendChart(
          title: '网速（/s）',
          chartId: 'net',
          granularity: _granularity,
          recordedMinutes: _granRecordedMinutes,
          history: trend,
          series: const [
            TrendSeries('net_rx_rate', '↓ 下载', tone: TrendTone.accent),
            TrendSeries('net_tx_rate', '↑ 上传', tone: TrendTone.muted),
          ],
          fmtValue: (v) => _fmtRate(v),
        ),
        const SizedBox(height: 12),
        TrendChart(
          title: '磁盘 I/O（/s）',
          chartId: 'io',
          granularity: _granularity,
          recordedMinutes: _granRecordedMinutes,
          history: trend,
          series: const [
            TrendSeries('disk_io_read', '读', tone: TrendTone.accent),
            TrendSeries('disk_io_write', '写', tone: TrendTone.muted),
          ],
          fmtValue: (v) => _fmtRate(v),
        ),
      ],
    );
  }

  /// 粒度分段按钮组：直角、发丝线分隔，选中档位单琥珀点缀（对齐 Web .granularity）
  Widget _granularityBar(AppColors c) {
    const options = TrendGranularity.values;
    return Semantics(
      container: true,
      label: '趋势粒度',
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: c.border, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++)
              _granularityBtn(c, options[i], first: i == 0),
          ],
        ),
      ),
    );
  }

  Widget _granularityBtn(
    AppColors c,
    TrendGranularity g, {
    required bool first,
  }) {
    final active = _granularity == g;
    return InkWell(
      onTap: () => _selectGranularity(g),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? c.accentSoft : Colors.transparent,
          border: first
              ? null
              : Border(left: BorderSide(color: c.border, width: 0.5)),
        ),
        child: Text(
          trendGranularityLabel(g),
          style: TextStyle(
            color: active ? c.accent : c.muted,
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
      ),
    );
  }

  /* ============ 通用小组件 ============ */

  /// PSI 行（对齐 Web PsiRow）：显示 some/full 的 avg10，压力越大越警示
  Widget _psiRow(AppColors c, String label, dynamic raw) {
    final o = raw is Map ? raw : null;
    final some = (o != null && o['some'] is Map)
        ? o['some'] as Map
        : null;
    if (some == null) return _kv(c, label, '—');
    final full = o!['full'] is Map ? o['full'] as Map : null;
    final s = _pct(some['avg10']);
    final text = 'some ${s.toStringAsFixed(1)}% · '
        'full ${full == null ? '—' : '${_pct(full['avg10']).toStringAsFixed(1)}%'}';
    return _kv(
      c,
      label,
      text,
      color: s >= 50 ? c.danger : (s >= 30 ? c.warn : null),
    );
  }

  Widget _kv(AppColors c, String label, String value,
      {bool amber = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: color ?? (amber ? c.accent : c.fg),
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rateStat(AppColors c, String label, String value, {bool amber = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: c.muted, fontSize: 11)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              color: amber ? c.accent : c.fg,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _headLabel(AppColors c, String text, {bool right = false}) => Text(
    text,
    textAlign: right ? TextAlign.right : TextAlign.left,
    style: TextStyle(
      color: c.muted,
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
    ),
  );

  Widget _vDivider(AppColors c) => Container(
    width: 1,
    height: 34,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: c.border,
  );
}

/* ============ 趋势图（纯 CustomPainter，无图表库，对齐 Web 手写 SVG） ============ */

/// 趋势线配色（对齐 Web CSS 变量）：accent 琥珀 / muted 中性灰 / ok 绿 / danger 红
enum TrendTone { accent, muted, ok, danger }

Color _toneColor(AppColors c, TrendTone tone) {
  switch (tone) {
    case TrendTone.accent:
      return c.accent;
    case TrendTone.muted:
      return c.muted;
    case TrendTone.ok:
      return c.ok;
    case TrendTone.danger:
      return c.danger;
  }
}

class TrendSeries {
  final String key;
  final String label;
  final TrendTone tone;
  const TrendSeries(this.key, this.label, {this.tone = TrendTone.muted});
}

/// 趋势图平移位置记忆：键 `档位:图 id`。App 会话内有效，退出即失效（对齐 Web 模块级
/// `chartViewMemory`）。R8：切档不串位、切回保留。
final Map<String, ({int offset, bool follow})> _trendViewMemory = {};

class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.title,
    required this.chartId,
    required this.granularity,
    required this.history,
    required this.series,
    this.yMax,
    this.yLabel = '',
    this.recordedMinutes,
    required this.fmtValue,
  });

  final String title;

  /// 图标识（mem / psi / net / io）：平移位置按（档位 + 图）分别记忆。
  final String chartId;

  /// 当前粒度档位：决定窗口（秒 30 / 非秒 60）、X 轴刻度与稀疏渲染。
  final TrendGranularity granularity;

  final List<Map<String, dynamic>> history;
  final List<TrendSeries> series;
  final double? yMax;
  final String yLabel;

  /// 非秒档「数据积累中（已记录 N 分钟）」的 N；null 按 0。
  final int? recordedMinutes;

  final String Function(num) fmtValue;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int _offset = 0;
  // 跟随最新：初始为 true；用户平移离开最新后关闭，拖回末尾或点「回最新」恢复
  bool _follow = true;

  int get _window => trendWindow(widget.granularity);

  bool get _sparse => widget.granularity != TrendGranularity.sec;

  String get _memoryKey =>
      '${trendGranularityId(widget.granularity)}:${widget.chartId}';

  @override
  void initState() {
    super.initState();
    _restoreView();
  }

  @override
  void didUpdateWidget(covariant TrendChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.granularity != widget.granularity ||
        oldWidget.chartId != widget.chartId) {
      _restoreView(); // 切档：恢复该（档位 + 图）上次的平移位置
    }
  }

  void _restoreView() {
    final m = _trendViewMemory[_memoryKey];
    _offset = m?.offset ?? 0;
    _follow = m?.follow ?? true;
  }

  void _remember(int offset, bool follow) {
    _trendViewMemory[_memoryKey] = (offset: offset, follow: follow);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final history = widget.history;
    final len = history.length;

    final slice = computeTrendSlice(
      len: len,
      window: _window,
      offset: _offset,
      follow: _follow,
    );
    _offset = slice.offset;
    _remember(slice.offset, _follow);
    final points = history.sublist(slice.start, slice.end);

    // 秒档不足 2 点仍是「采集中」占位；非秒档 0 点才占位（单点要能看见）
    final placeholder = _sparse ? len == 0 : len < 2;

    return PanelCard(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final s in widget.series)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _toneColor(c, s.tone),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        s.label,
                        style: TextStyle(color: c.muted, fontSize: 11),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _latest(s.key),
                        style: TextStyle(color: c.fg, fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (placeholder)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text(
                  _sparse
                      ? trendAccumulatingText(widget.recordedMinutes)
                      : '数据采集中…（约 3 秒后显示趋势）',
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 160,
              child: ClipRect(
                child: GestureDetector(
                  onHorizontalDragEnd: (_) {},
                  onHorizontalDragUpdate: (d) {
                    if (len <= _window) return;
                    final maxOffset = len - _window;
                    final next = (_offset - (d.primaryDelta! / 6).round())
                        .clamp(0, maxOffset);
                    final following = next >= maxOffset;
                    setState(() {
                      _offset = next;
                      // 拖回最末窗口即恢复跟随
                      _follow = following;
                    });
                    _remember(next, following);
                  },
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _TrendPainter(
                      points: points,
                      series: widget.series,
                      yMax: widget.yMax,
                      yLabel: widget.yLabel,
                      fmtValue: widget.fmtValue,
                      granularity: widget.granularity,
                      c: c,
                    ),
                  ),
                ),
              ),
            ),
            if (!_follow && len > _window)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InkWell(
                    onTap: () {
                      final next = math.max(0, len - _window);
                      setState(() {
                        _follow = true;
                        _offset = next;
                      });
                      _remember(next, true);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.accentBorder),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '回最新',
                        style: TextStyle(color: c.accent, fontSize: 11),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _latest(String key) {
    final h = widget.history;
    if (h.isEmpty) return '';
    final v = h.last[key];
    return v is num ? widget.fmtValue(v) : '';
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.series,
    required this.yMax,
    required this.yLabel,
    required this.fmtValue,
    required this.granularity,
    required this.c,
  });

  final List<Map<String, dynamic>> points;
  final List<TrendSeries> series;
  final double? yMax;
  final String yLabel;
  final String Function(num) fmtValue;
  final TrendGranularity granularity;
  final AppColors c;

  static const double _l = 52, _r = 12, _t = 12, _b = 24;

  double _niceMax(double v) {
    if (v <= 0) return 1;
    final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    final f = v / exp;
    double nf;
    if (f <= 1) {
      nf = 1;
    } else if (f <= 2) {
      nf = 2;
    } else if (f <= 5) {
      nf = 5;
    } else {
      nf = 10;
    }
    return nf * exp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final plotW = w - _l - _r;
    final plotH = h - _t - _b;
    if (plotW <= 0 || plotH <= 0 || points.isEmpty) return;

    final gridPaint = Paint()
      ..color = c.border.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final textStyle = TextStyle(color: c.muted, fontSize: 9, fontFeatures: const [FontFeature.tabularFigures()]);
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    double maxV;
    bool percentChart;
    if (yMax != null) {
      maxV = yMax!;
      percentChart = true;
    } else {
      var m = 0.0;
      for (final p in points) {
        for (final s in series) {
          final v = p[s.key];
          if (v is num) m = math.max(m, v.toDouble());
        }
      }
      maxV = _niceMax(m);
      percentChart = false;
    }

    final nTicks = percentChart ? 4 : 5;
    for (var i = 0; i < nTicks; i++) {
      final ratio = i / (nTicks - 1);
      final y = _t + plotH * (1 - ratio);
      canvas.drawLine(Offset(_l, y), Offset(_l + plotW, y), gridPaint);
      final val = maxV * ratio;
      final label = percentChart
          ? '${val.round()}$yLabel'
          : fmtValue(val.toDouble());
      textPainter.text = TextSpan(text: label, style: textStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(_l - textPainter.width - 6, y - textPainter.height / 2));
    }

    // X 轴时间标签：首/1/3/2/3/尾；刻度格式随档位（秒 HH:mm:ss / 分钟 HH:mm / 小时 MM-DD HH:00 / 天 MM-DD）
    final single = points.length == 1;
    double xAt(int i) => single
        ? _l + plotW / 2
        : _l + plotW * (i / (points.length - 1));
    for (final i in trendTickIndices(points.length)) {
      final ts = points[i]['ts'];
      final x = xAt(i);
      textPainter.text = TextSpan(text: formatTrendTick(ts, granularity), style: textStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, _t + plotH + 4));
    }

    for (final s in series) {
      final tone = _toneColor(c, s.tone);
      if (single) {
        // 稀疏单点：画点 + 水平虚线参考线（对齐 Web .chart-line-single）
        final v = points[0][s.key];
        if (v is! num) continue;
        final y = _t + plotH * (1 - (v.toDouble().clamp(0, maxV) / maxV));
        _dashedLine(
          canvas,
          Offset(_l, y),
          Offset(_l + plotW, y),
          Paint()
            ..color = tone
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke,
        );
        canvas.drawCircle(Offset(xAt(0), y), 3, Paint()..color = tone);
        continue;
      }
      final linePaint = Paint()
        ..color = tone
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      var first = true;
      for (var i = 0; i < points.length; i++) {
        final v = points[i][s.key];
        if (v is! num) continue;
        final x = xAt(i);
        final y = _t + plotH * (1 - (v.toDouble().clamp(0, maxV) / maxV));
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      if (!first) canvas.drawPath(path, linePaint);
    }
  }

  /// 水平虚线（段长 4、间隔 3，对齐 Web `stroke-dasharray: 4 3`）
  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final end = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d = end + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.points != points ||
      old.c != c ||
      old.yMax != yMax ||
      old.granularity != granularity;
}
