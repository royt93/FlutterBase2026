import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

late String _scenario;
bool get _loading => _scenario == 'loading';
late bool _autoStart;

class T257StartGate extends StatefulWidget {
  const T257StartGate({
    super.key,
    required this.canStart,
    required this.autoStart,
    required this.onStart,
  });

  final ValueListenable<bool> canStart;
  final bool autoStart;
  final VoidCallback onStart;

  @override
  State<T257StartGate> createState() => _T257StartGateState();
}

class _T257StartGateState extends State<T257StartGate> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.canStart.addListener(_readinessChanged);
    _readinessChanged();
  }

  @override
  void didUpdateWidget(covariant T257StartGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.canStart != widget.canStart) {
      oldWidget.canStart.removeListener(_readinessChanged);
      widget.canStart.addListener(_readinessChanged);
      _readinessChanged();
    }
  }

  @override
  void dispose() {
    widget.canStart.removeListener(_readinessChanged);
    super.dispose();
  }

  void _readinessChanged() {
    if (widget.autoStart && widget.canStart.value && !_started) {
      _start();
    }
  }

  void _start() {
    if (_started || !widget.canStart.value) return;
    _started = true;
    widget.onStart();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.canStart,
    builder: (context, canStart, _) => Semantics(
      button: true,
      label: 't267-start-benchmark',
      enabled: canStart && !_started,
      onTap: !canStart || _started ? null : _start,
      child: SizedBox(
        width: 200,
        height: 48,
        child: ExcludeSemantics(
          child: TextButton(
            onPressed: canStart && !_started ? _start : null,
            child: const Text('Start benchmark'),
          ),
        ),
      ),
    ),
  );
}

void _startBenchmark() {
  if (_benchmarkStarted.isCompleted) return;
  debugPrint('T267_START requested');
  _benchmarkStarted.complete();
}

void _autoStartBenchmark() {
  if (_benchmarkStarted.isCompleted) return;
  debugPrint('T267_START auto');
  _benchmarkStarted.complete();
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
    mrecId: 'ca-app-pub-3940256099942544/6300978111',
  ),
  autoRequestUmpConsent: false,
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

final _navigatorKey = GlobalKey<NavigatorState>();
final _bannerKey = GlobalKey();
final _benchmarkInitialized = ValueNotifier<bool>(false);
final _benchmarkStarted = Completer<void>();
final _timings = <FrameTiming>[];
final _phases = <(String, int)>[];
final _scrollController = ScrollController();
final _benchmarkCompleted = ValueNotifier<bool>(false);
final _scrollStarted = ValueNotifier<bool>(false);
final _bannerReady = ValueNotifier<bool>(false);
final _canStart = ValueNotifier<bool>(false);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runT257ProfileFrameBenchmark(
    WidgetsBinding.instance.platformDispatcher.defaultRouteName,
  );
}

void runT257ProfileFrameBenchmark(String route) {
  WidgetsFlutterBinding.ensureInitialized();
  _autoStart = route.endsWith('-auto');
  final baseRoute = _autoStart ? route.substring(0, route.length - 5) : route;
  _scenario = baseRoute == '/real' || baseRoute == '/loading'
      ? baseRoute.substring(1)
      : const String.fromEnvironment(
          'T257_BENCH_SCENARIO',
          defaultValue: 'real',
        );
  if (_scenario != 'real' && !_loading) {
    throw StateError('T257_BENCH_SCENARIO must be real or loading');
  }
  AdManager().setNavigatorKey(_navigatorKey);
  SchedulerBinding.instance.addTimingsCallback(_onTimings);
  _mark('startup');
  runApp(
    MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
      home: const _BenchmarkHome(),
    ),
  );
  unawaited(_initialize());
}

void _onTimings(List<FrameTiming> values) => _timings.addAll(values);

Future<void> _waitFor(bool Function() predicate, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!predicate()) {
    throw TimeoutException('T257 benchmark wait expired', timeout);
  }
}

void _mark(String phase) {
  final now = Timeline.now;
  final latestVsync = _timings.isEmpty
      ? -1
      : _timings.last.timestampInMicroseconds(FramePhase.vsyncStart);
  _phases.add((phase, now));
  debugPrint(
    'T257_PHASE_MARK phase=$phase timeline_us=$now '
    'latest_frame_vsync_us=$latestVsync timing_samples=${_timings.length}',
  );
}

Future<void> _initialize() async {
  _mark('consent_init');
  final consent = await AdManager().requestUmpConsent();
  debugPrint(
    'T257_CONSENT status=${consent.status.name} canRequestAds=${consent.canRequestAds}',
  );
  await AdManager().initialize(
    config: _config,
    onComplete: (ok, _) {
      debugPrint('T257_INIT ok=$ok scenario=$_scenario');
    },
  );
  if (AdManager().vip?.isActive ?? false) await AdManager().vip?.revokeAll();
  _benchmarkInitialized.value = true;
  _mark('banner_load_begin');
  await _waitFor(
    () =>
        _bannerKey.currentState != null &&
        AdManager().adapter!.bannerSlot(_bannerKey.currentState!).value !=
            AdSlotState.idle,
    const Duration(seconds: 10),
  );
  final key = _bannerKey.currentState!;
  final adapter = AdManager().adapter!;
  debugPrint(
    'T257_AD slot=${adapter.bannerSlot(key).value.name} '
    'loaded=${adapter.banner(key).isLoaded.value} scenario=$_scenario',
  );
  await _waitFor(
    () =>
        adapter.bannerSlot(key).value == AdSlotState.loading ||
        adapter.bannerSlot(key).value == AdSlotState.ready ||
        adapter.banner(key).hasError.value,
    const Duration(seconds: 15),
  );
  if (!_loading) {
    await _waitFor(
      () =>
          adapter.bannerSlot(key).value == AdSlotState.ready ||
          adapter.banner(key).hasError.value,
      const Duration(seconds: 45),
    );
    _bannerReady.value =
        adapter.bannerSlot(key).value == AdSlotState.ready &&
        adapter.banner(key).isLoaded.value;
    debugPrint('T257_REAL_AD_READY ready=${_bannerReady.value}');
  }

  if (_loading) {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _mark('banner_loading_observed');
  } else if (!_bannerReady.value) {
    _mark('real_banner_not_ready');
  }
  if (!_loading && !_bannerReady.value) {
    throw StateError('AdMob test banner not ready');
  }
  debugPrint('T267_READY scenario=$_scenario');
  _canStart.value = true;
  await _benchmarkStarted.future;
  _scrollStarted.value = true;
  debugPrint(
    'T267_BANNER_AT_SCROLL slot=${adapter.bannerSlot(key).value.name} '
    'loaded=${adapter.banner(key).isLoaded.value} error=${adapter.banner(key).hasError.value}',
  );
  if (_loading) {
    _mark('loading_scroll');
    await _scrollController.animateTo(
      420,
      duration: const Duration(seconds: 2),
      curve: Curves.easeInOut,
    );
    _mark('loading_scroll_end');
  } else {
    final realSlot = adapter.bannerSlot(key);
    final isReady =
        _bannerReady.value &&
        realSlot.value == AdSlotState.ready &&
        adapter.banner(key).isLoaded.value;
    _bannerReady.value = isReady;
    debugPrint(
      'T257_REAL_AD_RESULT state=${realSlot.value.name} '
      'loaded=${adapter.banner(key).isLoaded.value} ready=$isReady '
      'error=${adapter.banner(key).hasError.value}',
    );
    if (isReady) {
      _mark('real_banner_visible_end');
      _scrollController.animateTo(
        420,
        duration: const Duration(seconds: 2),
        curve: Curves.easeInOut,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      _mark('real_scroll_end');
      _scrollController.animateTo(
        0,
        duration: const Duration(seconds: 2),
        curve: Curves.easeInOut,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      _mark('real_return_end');
    }
  }

  _benchmarkCompleted.value = true;
  _mark('report');
  _report();
}

class _BenchmarkHome extends StatelessWidget {
  const _BenchmarkHome();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('T257 Profile · $_scenario')),
    body: ValueListenableBuilder<bool>(
      valueListenable: _benchmarkInitialized,
      builder: (context, initialized, _) {
        if (!initialized) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: _benchmarkCompleted,
              builder: (context, completed, _) => ValueListenableBuilder<bool>(
                valueListenable: _scrollStarted,
                builder: (context, scrollStarted, _) => Column(
                  children: [
                    T257StartGate(
                      canStart: _canStart,
                      autoStart: _autoStart,
                      onStart: _autoStart
                          ? _autoStartBenchmark
                          : _startBenchmark,
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: _bannerReady,
                      builder: (context, ready, _) => Text(
                        't267Ready=true bannerReady=$ready benchmarkComplete=$completed scrollStarted=$scrollStarted',
                        key: const ValueKey('t257-benchmark-status'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: 80,
                itemBuilder: (context, index) => ListTile(
                  title: Text('Benchmark content row $index'),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            ),
          ],
        );
      },
    ),
    bottomNavigationBar: ValueListenableBuilder<bool>(
      valueListenable: _benchmarkInitialized,
      builder: (context, initialized, _) => initialized
          ? SafeArea(top: false, child: BannerAdWidget(key: _bannerKey))
          : const SizedBox.shrink(),
    ),
  );
}

void _report() {
  for (var i = 0; i < _phases.length - 1; i++) {
    final (name, start) = _phases[i];
    final end = _phases[i + 1].$2;
    final phaseFrames = _timings.where((f) {
      final stamp = f.timestampInMicroseconds(FramePhase.vsyncStart);
      return stamp >= start && stamp < end;
    }).toList();
    final firstVsync = phaseFrames.isEmpty
        ? -1
        : phaseFrames.first.timestampInMicroseconds(FramePhase.vsyncStart);
    final lastVsync = phaseFrames.isEmpty
        ? -1
        : phaseFrames.last.timestampInMicroseconds(FramePhase.vsyncStart);
    final build =
        phaseFrames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
          ..sort();
    final raster =
        phaseFrames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
          ..sort();
    final total =
        phaseFrames.map((f) => f.totalSpan.inMicroseconds / 1000).toList()
          ..sort();
    final vsyncIntervals = <double>[];
    for (var i = 1; i < phaseFrames.length; i++) {
      final delta =
          phaseFrames[i].timestampInMicroseconds(FramePhase.vsyncStart) -
          phaseFrames[i - 1].timestampInMicroseconds(FramePhase.vsyncStart);
      if (delta > 0) vsyncIntervals.add(delta / 1000);
    }
    vsyncIntervals.sort();
    double percentile(List<double> xs, double p) =>
        xs.isEmpty ? 0.0 : xs[((xs.length - 1) * p).round()];
    final over60 = total.where((v) => v > 16.67).length;
    final over120 = total.where((v) => v > 8.33).length;
    final intervalOver16 = vsyncIntervals.where((v) => v > 16.67).length;
    final intervalOver33 = vsyncIntervals.where((v) => v > 33.3).length;
    for (final frame in phaseFrames) {
      debugPrint(
        'T257_FRAME scenario=$_scenario phase=$name '
        'vsync_us=${frame.timestampInMicroseconds(FramePhase.vsyncStart)} '
        'build_us=${frame.buildDuration.inMicroseconds} '
        'raster_us=${frame.rasterDuration.inMicroseconds} '
        'total_us=${frame.totalSpan.inMicroseconds}',
      );
    }
    debugPrint(
      'T257_METRIC scenario=$_scenario phase=$name phase_start_us=$start phase_end_us=$end '
      'first_vsync_us=$firstVsync last_vsync_us=$lastVsync '
      'duration_ms=${(end - start) ~/ 1000} '
      'frame_timing_samples=${phaseFrames.length} frame_timing_samples_per_second=${phaseFrames.length / ((end - start) / 1e6)} '
      'total_over_16_67ms=$over60 total_over_8_33ms=$over120 '
      'sample_vsync_gap_over_16_67ms=$intervalOver16 '
      'sample_vsync_gap_over_33_3ms=$intervalOver33 '
      'p95_sample_vsync_gap_ms=${percentile(vsyncIntervals, .95).toStringAsFixed(2)} '
      'p95_build_ms=${percentile(build, .95).toStringAsFixed(2)} '
      'p95_raster_ms=${percentile(raster, .95).toStringAsFixed(2)} '
      'p95_total_ms=${percentile(total, .95).toStringAsFixed(2)}',
    );
  }
  debugPrint(
    'T257_LIMIT: FrameTiming durations/sample gaps are Flutter pipeline observations, '
    'not confirmed presented/dropped-frame counts. Correlate with Android frame-timeline evidence.',
  );
}
