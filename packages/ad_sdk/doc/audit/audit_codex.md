# Round 4 — audit độc lập từ đầu, Codex CLI riêng biệt (2026-08-21, v2.2.0)

**Phạm vi/phương pháp.** Đây là vòng đọc source độc lập của agent `codex`, được gọi riêng, không giả định agent khác đã review. Đã đọc `../../CLAUDE.md`, toàn bộ ba file lịch sử audit, rồi tự kiểm tra implementation hiện tại của `AdManager`, hai adapter, widget của từng format, consent/UMP/ATT, safety, trial/VIP/CRL và public API mới từ commit `558dda0`. Không build device/simulator và không sửa source. Worktree đã có sẵn thay đổi không liên quan ở `example/pubspec.lock`; vòng audit không đụng vào file đó.

**Gate thực chạy ngày 2026-08-21:** `flutter analyze` **PASS — 0 issues**; `flutter test` **PASS — 873/873 tests** (`All tests passed`, exit 0, khoảng 1m28s). Con số cũ 860/868 không còn hiện hành.

## Blocker

Không phát hiện Blocker mới theo nghĩa có thể forge chữ ký Ed25519, cấp reward giả, hoặc stack hai fullscreen ad trên đường chính. Fullscreen mutex hiện bao gồm cả rewarded-interstitial; AdMob re-check freshness lúc show; dispose theo instance tồn tại cho banner/MREC/native ở cả hai adapter.

## Major — còn mở, phải xử lý trước production ship

### M1 — VIP code không redeem được offline, trái yêu cầu sản phẩm “must work fully offline” — **RE-CONFIRMED / đổi verdict cũ**

`VipManager.redeemSignedKey()` trả `invalid` ngay khi `_isConnectedCheck()` false, trước parse, `PackageInfo`, Ed25519 verify, CRL cache và ledger. Đây là gate nhân tạo; crypto và persistence không cần mạng. README cũng tự mâu thuẫn: `README.md:885-890` thừa nhận redemption bị chặn offline, nhưng `README.md:1151` gọi `redeemSignedKey` “fully offline”. Audit cũ đánh dấu “không phải bug” vì coi đó là product choice; vòng này user nêu yêu cầu rõ rằng activation phải hoạt động hoàn toàn offline, nên đây là Major không còn tranh luận.

**Evidence:** `lib/src/vip/vip_manager.dart:664-686`; verify local tại `:688-725`; cached CRL/ledger/grant tại `:727-769`; `README.md:877-890,1151-1155`.

**Minimum fix:** bỏ connectivity precondition khỏi `redeemSignedKey`; vẫn dùng CRL đã cache (nếu có), Ed25519 local và ledger local. Network chỉ nên dùng cho `refreshRevocationList`, không phải redemption.

### M2 — SDK-owned UMP fail-open khi platform channel lỗi — **RE-CONFIRMED CÒN MỞ**

Auto UMP đóng gate ở `_canRequestAds=false`, nhưng `runZonedGuarded` error handler gán lại `true` nếu callback/platform channel ném lỗi. “Missing plugin” không chứng minh user là non-EEA hay đã consent; cùng nhánh cũng bắt lỗi channel/runtime thật trên thiết bị. Adapter được init ngay sau đó và `canReload` nhận gate đã mở, vì vậy ad request có thể đi ra khi consent state chưa xác định. Đây là fail-open về pháp lý, không chỉ availability.

**Evidence:** `lib/src/core/ad_manager.dart:1843-1898` (đóng gate/chạy UMP), `:1899-1917` (error handler mở gate), `:1920-1931` (adapter + reload gate tiếp tục init).

**Minimum fix:** giữ gate đóng khi UMP lỗi/inconclusive nếu SDK đã được cấu hình sở hữu consent; surface lỗi/retry rõ ràng. Nếu muốn hỗ trợ app cố ý không dùng UMP, đó phải là config explicit và release footgun guard riêng, không suy ra từ channel failure.

### M3 — Consent revoke/COPPA change giữa session không dỡ creative đã cache/mounted; AppLovin banner có thể tiếp tục auto-refresh — **NEW / CONFIRMED**

`setConsent()` cập nhật provider flags và chặn *request mới* (`_canRequestAds=false` cho AppLovin child user), nhưng không dispose/hide các fullscreen slot đã `ready`, banner/MREC/native đã mount, hoặc reset widget `_allowed`. Ba widget chỉ subscribe `initRevision`, VIP và adapter listenables; chúng không subscribe `canRequestAds`. Sau `_allowed=true`, gate consent không được re-check trong render path. Với AppLovin banner/MREC, route lifecycle vẫn có thể để native auto-refresh bật; đó là request path nằm trong native `MaxAdView`, ngoài `adapter.canReload`. Fullscreen show methods currently re-check `canRequestAds`, nên creative không show qua orchestrator while false, nhưng stale cached data remains and can later be shown if gate reopens without a privacy-safe reload.

**Evidence:** `lib/src/core/ad_manager.dart:2204-2260`; `lib/src/widget/banner_ad_widget.dart:89-123,226-258,315-332`; `lib/src/widget/mrec_ad_widget.dart:70-103,159-205,260-279`; `lib/src/widget/native_ad_widget.dart:66-96,108-134,177-188`; `lib/src/adapters/applovin_adapter.dart:1408-1455,1483-1533`.

**Minimum fix:** on consent becoming non-requestable or child-restricted, atomically hide/dispose all mounted display ads, stop AppLovin auto-refresh, discard all cached fullscreen creatives, and require fresh loads only after the gate reopens. Add regression tests for both providers and all seven formats.

### M4 — Public GAID API có thể trả identifier cũ ở trạng thái “not resolved”/sau destroy — **NEW, API `558dda0`**

`currentDeviceGaid` đã normalize all-zero ID thành empty (tốt), và iOS `.notDetermined` có defer để tránh prompt ATT ngầm (tốt). Tuy nhiên `_currentDeviceGAID` không được clear khi bắt đầu resolve, trong catch/timeout failure, khi defer vì ATT, hoặc trong `destroy()`. Vì vậy sau một init thành công, `destroy()` vẫn để getter/hint lộ raw advertising ID; re-init mà fetch lỗi/defer tiếp tục trả ID của session/provider/privacy state cũ. Doc contract nói empty trước init/không resolved, nhưng implementation vi phạm. API hoạt động ở release và `adMobTestDeviceHashHint()` nhúng raw GAID vào chuỗi, dễ bị host đưa vào UI/log/support telemetry. Tests mới chỉ kiểm tra happy path + zero normalization/text; không khóa teardown/failure/deferred behavior.

**Evidence:** backing field/getter/hint `lib/src/core/ad_manager.dart:749-800`; resolve chỉ assignment khi success/null và catch giữ nguyên `:1519-1538`; ATT defer `:1701-1718`; `destroy()` không clear field `:2494-2571`; tests `test/ad_manager_core_test.dart` group `adMobTestDeviceHashHint / currentDeviceGaid`.

**Privacy assessment:** LAT/ATT-denied all-zero placeholder không bị public API trả ra — phần này đúng. Rủi ro thật là stale real ID và release-surface disclosure, không phải tự bypass ATT để lấy ID mới.

**Minimum fix:** clear field synchronously on destroy, before every resolve attempt, and when fetch is deferred/throws/times out; ideally return a typed state (`unresolved`/`unavailable`/`available`) rather than overloading empty string. Hint should not embed the raw GAID by default, or must be explicitly debug-only/redacted with a separate opt-in accessor.

## Minor — còn mở

### m1 — Empty AppLovin banner/native unit IDs vẫn có đường vào native widget/load

MREC có hard guard `mrecId.isEmpty`, nhưng banner preload calls `preloadWidgetAdView(cfg.bannerId, ...)` không guard, và native builds `MaxNativeAdView(adUnitId: nativeId)` trực tiếp. Release-footgun warnings log/assert but do not block in release. A host that omits an optional-looking surface then accidentally mounts its widget can get native error/crash behavior instead of a safe no-op.

**Evidence:** `lib/src/adapters/applovin_adapter.dart:1408-1433` versus MREC guard `:1497-1506`; `lib/src/widget/native_ad_widget.dart:177-188,274-289`; warning-only validation `lib/src/core/ad_manager.dart:256-301,1678-1685`.

### m2 — `currentDeviceGaid` naming/docs are Android-centric and encourage production exposure

The value is described as GAID even on iOS, where the underlying advertising identifier is IDFA. README says callers may surface it in their “own debug UI” but API/hint remain callable in release and the hint explicitly advertises release logging. This is not a direct consent bypass after zero normalization, but is weak privacy-by-design guidance for a raw persistent identifier.

**Evidence:** `lib/src/core/ad_manager.dart:761-800`; `README.md:1851-1855`.

## Re-verification of older material

- **Still fixed/correct:** pending COPPA consent is replayed before adapter init (`ad_manager.dart:1803-1829`); AppLovin refuses init when known child-restricted; AdMob uses child-directed RequestConfiguration plus per-request NPA/RDP; fullscreen busy mutex includes app-open/interstitial/rewarded/rewarded-interstitial and modal/loading-dialog state (`:1030-1082`); App Open resume checks the modal mutex and safety; AdMob fullscreen show-time freshness exists; adapter `dispose()` tears down keyed ads/listenables/slots.
- **Still a disclosed limitation, accepted only if product accepts it:** AppLovin exposes no load timestamp; SDK can show long-cached MAX fullscreen creatives (`README.md:82-89`). This conflicts with a strict cross-provider freshness requirement, but the package documents it. A production integration requiring a hard freshness SLA should not enable AppLovin until the wrapper records its own load-success timestamp and expires the slot locally.
- **Trial/replay:** 1-day release grant and mid-session expiry are implemented. iOS uses Keychain; Android remains dependent on host Auto Backup and is bypassable via Clear Data/disabled backup/cross-account reinstall. Documentation is now explicit (`README.md:61-71,1207-1218`), so this is not hidden, but it is not attacker-proof.
- **VIP crypto:** Ed25519 verification is genuine local public-key verification; AVP2 signs duration, key id, absolute redeem expiry and bundle binding; rotation accepts comma-separated public keys; signed CRL has domain separation and issued-at anti-rollback. Residual limits remain: AVP1 has no expiry/app binding; bundle-id read failure fails open; CRL cannot claw back an already granted window; Android ledger is reinstall-replayable without restored backup; clock defense cannot solve manipulation before first observation/across every process/background boundary without trusted time.
- **Offline ad resilience:** load paths check connectivity/gates and reconnect retry is generation-guarded; network/bridge waits inspected are bounded or callback-driven. No evidence of an offline retry storm was found. This does not cure M1: VIP redemption itself is deliberately blocked offline.

## Verdict

**NO — không an toàn để ship production as-is theo các yêu cầu audit này.** Minimum trước ship: (1) make signed VIP redemption genuinely offline; (2) make SDK-owned UMP fail closed on channel/fetch failure; (3) dispose/hide and invalidate all mounted/cached ads on consent/COPPA revocation; (4) clear/redesign the new GAID public state so no stale real identifier is exposed after destroy/failure/defer. For a strict stale-ad policy, also add wrapper-owned freshness timestamps for AppLovin or disable that provider. Only after those fixes plus targeted regression tests and a fresh analyze/test run should v2.2.0 be considered production-ready.

---

# Audit độc lập `applovin_admob_sdk` — codex CLI (bản hợp nhất)

Hợp nhất `audit_codex.md` (round 1, ~2026-08-09, local version 2.0.3, pub.dev khi đó 1.2.2) và `audit_codex_20260815.md` (round 2, 2026-08-15, version 2.0.4, 700 test pass). **codex CLI không chạy được round 3 trong phiên audit 08-19/20 này** (quota OpenAI hết, trả về "usage limit — resets Aug 20 2026") — file này KHÔNG có góp ý mới từ codex sau 08-15; phần "cross-check" dưới đây là do Claude tự re-verify trực tiếp source trong phiên 08-19/20.

---

## Cross-check các "P1 bug" của round 2 (08-15) với vòng audit 08-19/20

| # | Finding round 2 (08-15) | Trạng thái sau re-verify 08-19/20 |
|---|---|---|
| P1-1 | AppLovin Native có thể request ad sau khi gate đổi trạng thái (`native_ad_widget.dart:48,70,102,158,249`) — `_allowed=true` latch không re-check `canRequestAds`/`canReload` khi rebuild | **UNVERIFIED** — không tự đọc lại trong phiên này, không khẳng định fixed hay còn mở. |
| P1-2 | `canShowInterstitial()`/`canShowRewardedAd()` trả `true` dù đường show thực tế sẽ bị chặn | **STALE/ĐÃ FIX** — phiên 08-19/20 xác nhận trực tiếp cả 2 hàm này hiện dùng `canShowFullscreenAdPeek()` (side-effect-free, phản ánh đúng trạng thái sẽ chặn hay không) thay vì logic cũ gây sai lệch. |
| P1-3 | README ghi sai default `autoRequestUmpConsent` (README nói `false`, code là `true`) | **STALE/ĐÃ FIX** — README hiện tại (dòng ~715) ghi đúng `true`, khớp `ad_config.dart:370`. |
| P1-4 | `destroy()` không reset đủ consent/ATT guard state (`_canRequestAds`, `_lastUmpResult`, `_umpAttemptFailed`, `_attRequested` sống sót qua destroy→reinit) | **UNVERIFIED** — không tự đọc lại trong phiên này. |
| P1 (UMP fail-open) | UMP channel lỗi fail-open cho phép request ads sau lỗi consent SDK (`ad_manager.dart:1272,1275,1294,1300` — số dòng lịch sử tại thời điểm đó) | **CONFIRMED CÒN MỞ** — re-verify độc lập trong phiên 08-19/20 (lane E M2) xác nhận `runZonedGuarded` error handler mở lại gate khi UMP channel native lỗi. Đây là finding thật, không phải lỗi audit cũ. |

---

## Round 1 (2026-08-09) — các mục còn giá trị tham khảo

**Bối cảnh lúc đó:** local `pubspec.yaml` = 2.0.3, pub.dev serve 1.2.2. **Tình trạng hiện tại (08-20):** local = 2.1.0, đã release theo git log (`51e79e6`, `95c12e8`) — verify trực tiếp trên pub.dev trước khi tin đã lên hẳn (CDN có thể lag, xem CLAUDE.md). Số liệu phiên bản cũ trong round 1 (2.0.3 vs 1.2.2) đã lỗi thời hoàn toàn, không dùng lại.

### Critical
Không có regression Critical mới trong diff lúc đó. `canReload` gate đã wire đúng cho banner/MREC/native cả 2 adapter (`ad_manager.dart:1312`, `admob_adapter.dart:944`, `applovin_adapter.dart:1081,395,676,879`) — mục này vẫn còn đúng theo cấu trúc code hiện tại (chưa có tín hiệu gì cho thấy gate này bị gỡ).

### High (M2–M4 của round 1)
- **M2 — version mismatch local/pub.dev.** Đã lỗi thời về số liệu cụ thể, nhưng **bản chất finding vẫn còn giá trị**: mỗi lần release cần verify pub.dev đã serve version mới thật, không chỉ tin theo commit local. Xem mục "Tình trạng hiện tại" trên.
- **M3 — UMP fail-open khi channel lỗi.** Trùng với P1 (UMP fail-open) ở bảng cross-check trên — **CONFIRMED CÒN MỞ** tại 08-19/20.
- **M4 — Signed VIP redeem yêu cầu online dù verify crypto là offline.** `redeemSignedKey` trả invalid nếu `_isConnectedCheck()` false (`vip_manager.dart:599`), lý do là product gate chống chia sẻ key qua mạng, không phải hạn chế kỹ thuật. **Chưa re-verify trong phiên 08-19/20** — nếu còn đúng, cần ghi rõ trong README rằng "hoạt động offline" chỉ áp dụng cho VIP đã redeem trước đó và ad loading, không áp dụng cho redeem key mới.

### Ghi nhận scope — các mục host-app đã lỗi thời do tách repo
Round 1 có nhắc tới các file `lib/mckimquyen/widget/splash/...`, `lib/mckimquyen/widget/vip/...` — đây là code của **host app**, theo CLAUDE.md hiện tại **host app đã được tách sang repo riêng**, không còn nằm trong repo này. Các finding liên quan (cold-start App Open bypass safety trong splash screen của host, privacy settings persistence phụ thuộc host UI) **ngoài phạm vi audit của package `ad_sdk` hiện tại** — giữ lại chỉ để lưu ý cho bên tích hợp (consuming app), không phải backlog của package này.

---

## Findings từ round 2 (08-15) — chưa cross-check ở trên, giữ nguyên

- Thiếu test cho "banner AdMob ở route đầu tiên" (đi kèm bug `_admobIsTop` không init đúng khi mount trên route hiện tại — trùng với `audit_agy.md` finding 1.1, cũng chưa được verify lại 08-19/20. Hai nguồn độc lập (codex + agy) cùng nêu vấn đề tương tự → nên ưu tiên xác minh sớm).
- Thiếu test cho tổ hợp `autoRequestUmpConsent:false` + dialog built-in.
- CI không track code coverage định kỳ, tự động — chỉ có số đo thủ công một lần (66.4% tại thời điểm 08-11).
- Barrel export `applovin_admob_sdk.dart` lộ nhiều low-level/testing surface (adapters, event bus, slot/backoff internals) ra public API — rủi ro breaking change ngầm nếu ai dùng nhầm phần internal.
- Pinning wall Dart/CocoaPods (đã ghi trong CLAUDE.md) chưa có matrix test hoặc doctor-check tự động để phát hiện xung đột trước khi consuming app build.
- README stale nhắc `google_mobile_ads 6.x` trong khi package dùng `^7.0.0` (cần re-verify README hiện tại có còn stale không).
- Không có watchdog cho load thường (không phải on-demand) của interstitial/rewarded — chỉ có cho on-demand rewarded load.

---

## Kết luận

**Không có second opinion mới từ codex trong vòng audit 08-19/20** do quota hết. File này là tổng hợp 2 round trước + annotation từ verify độc lập của Claude trong vòng mới nhất.

**Bugs còn mở, xác nhận cần fix:**
1. UMP channel fail-open cho phép request ads khi consent SDK lỗi (CONFIRMED CÒN MỞ, xem `audit_claude.md` cho finding tương đương).
2. Version mismatch pub.dev vs local — verify lại trước mỗi lần khuyến nghị ship.
3. `_admobIsTop` route đầu tiên (2 nguồn độc lập nêu, chưa verify lại — ưu tiên cao).

**Round 3 đã đọc lại source:** P1-1 **CONFIRMED CÒN MỞ**; P1-4 **CONFIRMED CÒN MỞ nhưng đã giảm phạm vi** (hai guard chính đã reset, còn `_lastUmpResult` và `_attRequested` sống qua teardown); M4 **KHÔNG PHẢI BUG** vì connectivity gate là quyết định sản phẩm và README hiện đã ghi rõ giới hạn này.

**Khuyến nghị:** nhất quán với `audit_claude.md` và `audit_agy.md` — **YES-WITH-CONDITIONS**. Điều kiện thêm riêng từ góc nhìn codex: đóng UMP fail-open trước khi ship cho audience có EEA user thật; sửa P1-1 và quyết định/reset rõ lifecycle của hai state còn lại trong P1-4. Ba mục từng UNVERIFIED đã được re-verify ở Round 3 dưới đây.

## Round 3 self re-verify (2026-08-20)

| # | Trạng thái (CONFIRMED CÒN MỞ / ĐÃ FIX / KHÔNG PHẢI BUG) | Evidence file:line |
|---|---|---|
| P1-1 | **CONFIRMED CÒN MỞ** — `_initNative()` kiểm tra VIP, consent, connectivity và cooldown trước khi set `_allowed=true`, nhưng sau đó `_allowed` chỉ được dùng như latch; rebuild chỉ thử init lại khi `_allowed=false`. Nhánh render có re-check `isInitialised` và notifier VIP, nhưng không hạ `_allowed` hay re-check `canRequestAds`/`canLoadNative`/adapter `canReload` sau consent revoke hoặc thay đổi gate. Vì vậy AppLovin `MaxNativeAdView` vẫn có thể được mount/request dựa trên quyền đã latch từ trước. | `lib/src/widget/native_ad_widget.dart:56`; gate ban đầu `:66-89`; latch/rebuild `:109-133` |
| P1-4 | **CONFIRMED CÒN MỞ (đã fix một phần)** — `destroy()` nay gọi `_resetGuardState()`, và helper reset `_canRequestAds=true`, `_umpAttemptFailed=false` (đồng thời reset `_umpRequested`), nên hai phần chính của finding cũ đã fix. Tuy nhiên helper không reset `_lastUmpResult` hay `_attRequested`; hai field này chỉ được gán tại luồng UMP/ATT và không có assignment reset nào. `_lastUmpResult` hiện bị cô lập bởi `_umpRequested=false` nên không được cache path dùng ngay ở init kế tiếp, nhưng `_attRequested=true` cũ vẫn làm mất warning thứ tự ATT→UMP trong session mới. Do teardown được mô tả là đưa in-memory flags về trạng thái sạch, finding “reset chưa đủ” vẫn còn mở với impact nhỏ hơn bản cũ. | `lib/src/core/ad_manager.dart:1080-1087,1116-1119`; cache/warning consumers `:2167-2195`; assignments `:2262,2340-2343`; `destroy()` gọi reset `:2347-2353,2411-2415`; reset helper `:2446-2461` |
| M4 | **KHÔNG PHẢI BUG** — `redeemSignedKey()` vẫn trả `invalid` ngay khi `_isConnectedCheck()` false, trước verify Ed25519; code ghi rõ đây là product gate, không phải yêu cầu kỹ thuật. README hiện ghi trực tiếp “redeem attempt requires connectivity”, offline chỉ mô tả signature verification chứ không phải toàn bộ redemption flow. Vì vậy behavior còn tồn tại nhưng gap tài liệu của finding cũ đã được đóng. | `lib/src/vip/vip_manager.dart:61-67,602-624`; `README.md:869-882` |
