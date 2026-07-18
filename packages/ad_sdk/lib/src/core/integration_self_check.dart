/// Outcome of a single check in `AdManager.runIntegrationSelfCheck()`.
enum SelfCheckStatus { pass, fail, skipped }

/// One line of the self-check checklist.
class SelfCheckItem {
  const SelfCheckItem(this.name, this.status, [this.detail]);

  final String name;
  final SelfCheckStatus status;

  /// Human-readable reason, populated for [SelfCheckStatus.fail] and
  /// [SelfCheckStatus.skipped].
  final String? detail;

  Map<String, dynamic> toJson() =>
      {'name': name, 'status': status.name, 'detail': detail};
}

/// Result of `AdManager.runIntegrationSelfCheck()` — a debug-only checklist
/// covering init, consent, and per-ad-type load, so a partner integrating
/// the SDK doesn't have to manually click through the example app's ~15 demo
/// pages to confirm their `AdConfig` works on their device.
///
/// Deliberately does **not** call `AdManager.destroy()` or grant/revoke VIP
/// entries — those mutate live session/entitlement state and would be a
/// destructive side effect of what's meant to be a read-mostly sanity check.
class SelfCheckResult {
  const SelfCheckResult(this.items);

  final List<SelfCheckItem> items;

  bool get allPassed => items.every((i) => i.status != SelfCheckStatus.fail);

  Map<String, dynamic> toJson() =>
      {'allPassed': allPassed, 'items': items.map((i) => i.toJson()).toList()};
}
