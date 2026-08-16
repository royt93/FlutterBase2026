import 'dart:convert' show utf8;

/// T93 — deterministic A/B bucket assignment: `hash(installId + key) %
/// buckets`. Same result every call for the same `(installId, key,
/// buckets)` triple — no storage of its own, no dependency, letting a host
/// A/B test `AdSafetyParams`/arbitrator thresholds without integrating a
/// remote-config backend (lighter-weight than T88's `RemoteAdSafetyProvider`
/// — this only ever reads local state, no network involved).
///
/// [key] namespaces the experiment (e.g. `'daily_cap_experiment'`) so the
/// SAME install can land in different buckets for different concurrent
/// experiments, instead of always landing in "bucket N of every experiment
/// this app ever runs" — which would make experiments' outcomes correlated
/// with each other instead of independent.
int experimentBucket(String installId, String key, {required int buckets}) {
  if (buckets <= 0) {
    throw ArgumentError.value(buckets, 'buckets', 'must be positive');
  }
  final hash = _fnv1a('$installId|$key');
  return hash % buckets;
}

/// 32-bit FNV-1a — same algorithm AdPreferences already uses for its VIP
/// checksum (see `_fnv1a` there); duplicated rather than shared since that
/// one is private to a different file and this needs to stay a small, pure,
/// independently-testable function.
int _fnv1a(String s) {
  const prime = 0x01000193;
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(s)) {
    hash = ((hash ^ byte) * prime) & 0xFFFFFFFF;
  }
  return hash;
}
