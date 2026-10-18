import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const _scenario = String.fromEnvironment(
  'T257_BENCH_SCENARIO',
  defaultValue: 'real',
);
const _deterministic = _scenario == 'deterministic';

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
final _timings = <FrameTiming>[];
final _phases = <(String, int)>[];
final _bannerGeneration = ValueNotifier<int>(0);
final _scrollController = ScrollController();
_ControllableAdapter? _fake;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_scenario != 'real' && !_deterministic) {
    throw StateError('T257_BENCH_SCENARIO must be real or deterministic');
  }
  if (_deterministic) {
    _fake = _ControllableAdapter();
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager.debugAdapterFactory = (_) => _fake!;
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
  _mark('banner_load_begin');
  await _waitFor(
    () => _fake == null || _fake!.activeKey != null,
    const Duration(seconds: 15),
  );
  await Future<void>.delayed(const Duration(milliseconds: 800));
  _mark('banner_loading_observed');
  final key = _fake?.activeKey ?? _bannerKey.currentState!;
  final adapter = AdManager().adapter!;
  debugPrint(
    'T257_AD slot=${adapter.bannerSlot(key).value.name} '
    'loaded=${adapter.banner(key).isLoaded.value} scenario=$_scenario',
  );

  if (_deterministic) {
    for (var cycle = 0; cycle < 5; cycle++) {
      final loadingKey = _fake!.activeKey;
      _mark('deterministic_cycle_${cycle + 1}_loading_scroll');
      unawaited(
        _scrollController.animateTo(
          420,
          duration: const Duration(seconds: 2),
          curve: Curves.easeInOut,
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      _fake!.resolveCurrentLoad(success: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _mark('deterministic_cycle_${cycle + 1}_filled_scroll_back');
      unawaited(
        _scrollController.animateTo(
          0,
          duration: const Duration(seconds: 2),
          curve: Curves.easeInOut,
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      _bannerGeneration.value++;
      await _waitFor(
        () => _fake!.activeKey != loadingKey,
        const Duration(seconds: 10),
      );
    }
  } else {
    await Future<void>.delayed(const Duration(seconds: 10));
    final realSlot = adapter.bannerSlot(key);
    debugPrint(
      'T257_REAL_AD_RESULT state=${realSlot.value.name} '
      'loaded=${adapter.banner(key).isLoaded.value} error=${adapter.banner(key).hasError.value}',
    );
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

  _mark('report');
  _report();
}

class _BenchmarkHome extends StatelessWidget {
  const _BenchmarkHome();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('T257 Profile · $_scenario')),
    body: ListView.builder(
      controller: _scrollController,
      itemCount: 80,
      itemBuilder: (context, index) => ListTile(
        title: Text('Benchmark content row $index'),
        trailing: const Icon(Icons.chevron_right),
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: ValueListenableBuilder<int>(
        valueListenable: _bannerGeneration,
        builder: (context, generation, _) => BannerAdWidget(
          key: generation == 0 ? _bannerKey : ValueKey('banner-$generation'),
        ),
      ),
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

class _ControllableAdapter extends FakeAdProviderAdapter {
  Completer<void>? _pending;
  Object? activeKey;
  bool _pendingSuccess = false;

  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {
    activeKey = key;
    final slot = bannerSlot(key);
    final listenables = banner(key);
    if (!slot.beginLoad()) return;
    _pendingSuccess = false;
    _pending = Completer<void>();
    await _pending!.future;
    if (!slot.isLoading) return;
    if (_pendingSuccess) {
      slot.markReady();
      listenables.clearError();
      listenables.isLoaded.value = true;
      listenables.adSize.value = Size(widthPx, 50);
    } else {
      slot.markFailed();
      listenables.markError();
    }
  }

  void resolveCurrentLoad({required bool success}) {
    _pendingSuccess = success;
    if (!(_pending?.isCompleted ?? true)) _pending!.complete();
  }
}
