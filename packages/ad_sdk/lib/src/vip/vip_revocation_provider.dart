/// T95 — provider-agnostic hook for fetching a periodically-refreshed,
/// offline-signed VIP-key revocation list (CRL). Mirrors
/// `RemoteAdSafetyProvider`'s shape: the SDK has no opinion on the transport
/// (Firebase Remote Config, a self-hosted static JSON/text endpoint, ...) and
/// takes no dependency on any specific package — implement this with
/// whatever the host app already uses.
///
/// The returned string is the RAW signed CRL code as produced by
/// `tool/vip_crl_mint.dart` (e.g. `"CRL1.<payload>.<signature>"`) — do not
/// pre-parse it. `VipManager.refreshRevocationList` verifies the signature
/// itself before trusting anything inside.
///
/// ```dart
/// class MyCrlProvider implements VipRevocationProvider {
///   @override
///   Future<String?> fetchSignedCrl() async {
///     final resp = await http.get(Uri.parse('https://example.com/vip_crl.txt'));
///     return resp.statusCode == 200 ? resp.body.trim() : null;
///   }
/// }
///
/// // Once/day is plenty — the SDK caches the verified result locally and
/// // fails open (keeps the last-known-good list) on any fetch/verify error.
/// Timer.periodic(const Duration(hours: 24), (_) {
///   AdManager().vip?.refreshRevocationList(
///     publicKeyBase64: myVipPublicKey,
///     revocationProvider: MyCrlProvider(),
///   );
/// });
/// ```
abstract class VipRevocationProvider {
  /// Returns the raw signed CRL code, or `null`/throws if unavailable —
  /// either way `VipManager.refreshRevocationList` leaves the cached
  /// revocation list untouched (fail-open; a network hiccup must never
  /// block a legitimate redemption).
  Future<String?> fetchSignedCrl();
}
