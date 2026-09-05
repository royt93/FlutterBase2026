# Audit độc lập — `applovin_admob_sdk` (round 37, Codex)

**Cách chạy:** `codex exec --dangerously-bypass-approvals-and-sandbox` trên bản copy read-only riêng (rsync,
loại trừ `.git`/`build`/`.dart_tool`/`Pods`), không có quyền ghi vào working tree thật, không đọc `doc/audit/`.
Báo cáo dưới đây là **nguyên văn** output của Codex. Phần "Ghi chú verify" ở cuối là của tôi (Claude), sau khi
tự đọc lại source thật để kiểm chứng finding quan trọng nhất.

---

# Independent security / compliance / architecture audit

Date: 2026-09-04
Scope: `packages/ad_sdk/lib/src/` (74 filesystem entries, 31,354 lines), supporting package tests and example integration. Existing conclusions under `doc/audit/` were not used as evidence.

## Executive summary

The core runtime is unusually defensive: both adapters separate per-widget inline resources; fullscreen slots have load/show state machines, stale-callback identity checks, consent epochs, cache-age checks and bounded teardown; connectivity loss gates new loads and reconnect re-arms eligible slots; provider privacy state is applied before initialization and again after changes. Android/iOS ad-unit selection is correct. COPPA deliberately prevents AppLovin initialization, which matches AppLovin's prohibition on using MAX for a child. ATT is sequenced before UMP and native consent forms participate in the fullscreen mutex.

Static analysis and all package tests pass. This does **not** establish production policy compliance: two public production paths below can violate explicit ad-policy requirements. Offline entitlements also have unavoidable but materially under-described replay/reset limits.

## Verification performed

- Read every file in `packages/ad_sdk/lib/src/`, tracing configuration → consent/IAB storage → manager gates → provider adapter/bridge → slot callback → widgets/disposal, and trial/VIP persistence and verification.
- Re-read the cited source ranges after forming each finding.
- `flutter analyze`: **PASS**, no issues.
- `flutter test`: **PASS**, 1,581 tests.
- No emulator/simulator was available, so native Android/iOS integration behavior was assessed from bridge calls and callbacks, not re-executed on-device.

## BLOCKER

### B-01 — Rewarded interstitial can be shown without the mandatory introductory opt-out screen

**Location:** `packages/ad_sdk/lib/src/core/ad_manager.dart:6799-6806`, `6851-6940`; `packages/ad_sdk/lib/src/adapters/gma_bridge.dart:205-220`.

**Mechanism:** `showRewardedInterstitialAd()` goes directly through gates and calls `ad.showRewardedInterstitial(...)`. There is no SDK-owned introductory screen, no parameter proving a host screen was shown, and no API contract carrying the disclosed action/reward or an explicit "No/Don't accept" result. The comment explicitly describes the format as being shown without an explicit watch-ad tap. The bridge then loads a real `RewardedInterstitialAd`; Google does not synthesize the publisher's required pre-ad disclosure screen.

**Reproduction:** configure an AdMob rewarded-interstitial unit, await readiness, then call `AdManager().showRewardedInterstitialAd(onDone: ...)` from a natural transition. The Google fullscreen ad is presented immediately; the user receives neither a prior reward disclosure nor a usable refusal control from this SDK.

**Policy:** Google's rewarded-ad implementation requirements say rewarded interstitials must present an introductory screen with a visible, functional "no"/"don't accept" option and sufficient time to opt out, and require clear disclosure of the required action and offered reward before every rewarded ad: [Policies for ad units that offer rewards](https://support.google.com/admob/answer/7313578?hl=en-GB).

**Impact:** direct AdMob policy violation and account/ad-serving risk. Frequency caps and correct reward callbacks do not cure the missing pre-presentation choice.

**Required remediation:** remove/disable the public show path until it accepts and enforces an SDK-owned disclosure model (localized action, exact reward, affirmative/negative choices), or require an unforgeable-in-process one-shot acknowledgement produced only by an SDK disclosure screen immediately before `show()`.

## MAJOR

### M-01 — GPP enforcement ignores state sections and targeted-advertising opt-out

**Location:** `packages/ad_sdk/lib/src/core/iab_storage.dart:204-250`; `packages/ad_sdk/lib/src/core/ad_manager.dart:5100-5138`.

**Mechanism:** reconciliation first prefers the deprecated `IABUSPrivacy_String`; otherwise it reads only `IABGPP_7_String` (US National). The source explicitly declines to decode any state-specific section. Even within US National it reads only `SaleOptOut` and `SharingOptOut`; it does not read `TargetedAdvertisingOptOut`. `_reconcileDeviceUsPrivacy()` therefore leaves `ConsentSettings.doNotSell == false`, AppLovin `setDoNotSell(false)`, and AdMob's explicit `rdp=1` unset for a valid opt-out expressed only in California/Colorado/Connecticut/Florida/Virginia GPP sections, or only in the targeted-advertising field.

**Reproduction:** let a CMP write a valid `IABGPP_8_String` California section with the relevant opt-out, omit the legacy USP string and US National section, launch/resume, and call `AdManager().doNotSell`. It remains false; subsequent GMA requests omit explicit RDP and AppLovin receives false. The same occurs for a section-7 signal where sale/sharing are "did not opt out" but targeted advertising is "opted out."

**Policy/compliance basis:** Google says its Mobile Ads SDK supports GPP and accepts US National, California, Colorado, Connecticut, Florida and Virginia sections; publishers must decide and correctly signal their compliance treatment: [Supporting IAB GPP](https://support.google.com/admob/answer/14126918?hl=en), [Flutter US states privacy](https://developers.google.com/admob/flutter/privacy/us-states). AppLovin states multi-state laws may require a Do Not Sell/Share link or other interest-based-advertising opt-out and documents propagation via its privacy flags: [MAX privacy guidance](https://developers.applovin.com/en/max/ios/overview/privacy/).

**Impact:** the native Google SDK may independently consume a correctly stored GPP value, but the SDK's own cross-provider reconciliation contradicts it and AppLovin receives the wrong binary flag. This fails the stated "both providers / every country" contract.

**Required remediation:** use a certified CMP as the authority and forward its complete decision to both providers; if parsing storage remains necessary, implement the current GPP header plus every provider-supported jurisdictional section and all applicable opt-out fields, with conformance vectors from the IAB specification. Do not treat legacy USP as universally authoritative over a newer conflicting GPP decision.

### M-02 — Signed VIP codes are globally replayable across devices; AVP1 never expires or binds to an app

**Location:** `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:86-120`, `121-128`, `210-212`; `packages/ad_sdk/lib/src/vip/vip_manager.dart:1384-1404`; `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:9-25`, `79-92`.

**Mechanism:** Ed25519 correctly prevents forging a new payload without the private key. It does not make a bearer code one-time globally. Redemption ledgers are local. A valid code copied to a second device passes signature verification and finds no local `kid`; AVP1 additionally has neither expiry nor bundle binding and remains accepted for compatibility. Android uninstall with backup disabled also clears the ledger.

**Reproduction:** redeem one valid AVP1/AVP2 code on device A, copy the identical string to device B and redeem it there. Both grants succeed. On Android, uninstall after redemption with backup disabled, reinstall, and redeem the same code again.

**Impact:** leaked/resold codes can produce unlimited grants, bounded only per device and by optional CRL refresh. This is replay, not signature forgery. No purely offline design can guarantee global single use.

**Required remediation:** document codes as transferable multi-device bearer instruments, retire AVP1, require short-lived app-bound AVP2 codes, and use a server redemption ledger for actual one-time activation. If "no backend" is immutable, accept this risk explicitly and avoid selling codes as globally single-use.

## MINOR

### m-01 — Android's one-day first-install trial is trivially renewable when backup is unavailable

**Location:** `packages/ad_sdk/lib/src/vip/_first_install_guard.dart:27-47`, `49-57`, `126-145`, `157-185`.

**Mechanism:** Android always returns `false` from `hasAlreadyGranted()` and `markGranted()` is a no-op. Protection relies entirely on restoration of ordinary SharedPreferences through Auto Backup. A user who disables backup, uses another Google account, clears/restores selectively, or installs outside a restoring environment gets a fresh 24-hour trial. The source acknowledges this behavior. Clock rollback within an observed installation is substantially mitigated by the persisted high-water mark and monotonic session anchor; storage deletion is the weaker boundary.

**Reproduction:** on Android with backup disabled, install and receive grace, uninstall, reinstall, and initialize. The preferences marker is absent, the guard returns false, and a new grace entry is issued.

**Impact:** repeatable revenue bypass; not a cryptographic/security boundary. This is lower severity because the feature is a promotional trial, not a paid entitlement.

**Required remediation:** describe the trial as best-effort, not tamper-resistant. Strong enforcement requires a server/account/install-integrity authority; local Android storage cannot survive an adversarial uninstall reliably.

## Nitpick

### N-01 — Policy-safe placement is caller-controlled, so the SDK cannot certify host compliance

**Location:** `packages/ad_sdk/lib/src/core/ad_manager.dart:6278-6389` and `6509-6795`.

`showInterstitial()` and `showRewardedAd()` are callable from any host event; `AdPlacement` is analytics metadata, not an enforced transition/opt-in proof. Google requires interstitials at logical breaks and ordinary rewarded ads only after affirmative, unambiguous opt-in: [Interstitial guidance](https://support.google.com/admob/answer/6201362?hl=en), [Rewarded policy](https://support.google.com/admob/answer/7313578?hl=en-GB). This is a documentation/integration boundary rather than a defect in native lifecycle handling, but the package must not claim that its safety caps alone guarantee policy compliance.

## Areas without a confirmed defect

- **Dual provider / platforms:** platform-specific IDs resolve correctly; GMA objects are explicitly disposed; MAX keyed inline views are destroyed with retry and teardown guards. Fullscreen listeners/timers/slot notifiers are detached or disposed during adapter/manager teardown.
- **Offline resilience:** loads are gated offline, retry state is bounded, and reconnect clears only connectivity-class cooldowns before refilling eligible formats. Existing cached fullscreen ads still pass consent/freshness/presentation gates.
- **Consent/COPPA/ATT:** UMP gates requests; TCF withdrawal invalidates cached ads; AdMob gets COPPA/TFUA configuration; AppLovin initialization is refused for child users, consistent with AppLovin's rule that MAX must not be initialized for a child ([MAX privacy guidance](https://developers.applovin.com/en/max/ios/overview/privacy/)); ATT denial fails safely and Apple requires ATT before cross-company tracking ([Apple User Privacy and Data Use](https://developer.apple.com/app-store/user-privacy-and-data-use/)). Host dashboard configuration, manifest/plist declarations, mediated-network versions, CMP message publication and real-device behavior remain deployment obligations and cannot be proven from this package alone.
- **EU policy:** the default UMP path is a Google-certified CMP path and waits on `canRequestAds`; Google requires a certified TCF CMP for personalized ads in EEA/UK/Switzerland: [Google CMP requirement](https://support.google.com/admob/answer/13554020?hl=en). Disabling that flow transfers responsibility to the host and is guarded/warned, but cannot be certified from SDK source.

## Verdict

**NO** for production in the current form, because B-01 exposes a direct policy-violating production API and M-01 makes the advertised cross-provider US-state privacy enforcement incomplete. After disabling/fixing rewarded interstitial presentation and replacing the partial GPP interpretation with authoritative complete CMP propagation, the verdict can become **CONDITIONAL** on real-device Android/iOS integration tests, dashboard/CMP configuration, and explicit acceptance of the offline trial/VIP replay limits.

**Confidence: 9/10.** High confidence in Dart control flow, persistence and policy findings; the missing point reflects lack of physical-device native execution and inability to inspect each consuming app's dashboards/manifests/mediated SDK graph.

---

## Ghi chú verify (Claude, sau khi tự đọc lại source thật)

**B-01 (BLOCKER) — hạ xuống: false positive AS STATED, nhưng có 1 gap thật hẹp hơn nhiều.**

Đã đọc trực tiếp `lib/src/core/ad_screen.dart:252-339` (`AdScreenState.showRewardedInterstitialAd`) — đây là
API tầng CAO mà README khuyến nghị mọi screen hiển thị ads dùng (extend `AdScreen`/`AdScreenState`, xem
CLAUDE.md mục "Integration contract" điểm 5). Method này CÓ disclosure screen, **bật mặc định**
(`showDisclosure = true`), với doc-comment trích dẫn CHÍNH XÁC cùng lý do Codex nêu ("Round-23 QC (reviewer B,
BLOCKER) — the rewarded-interstitial format is the one fullscreen format Google mandates an announcement
for... The disclosure is on by default for that reason"). Đây rõ ràng là bản fix cho đúng lớp lỗi Codex đang
báo cáo lại như thể chưa được fix.

Codex chỉ trích dẫn `ad_manager.dart` và `gma_bridge.dart` — tầng THẤP hơn, nơi comment của chính
`ad_screen.dart` xác nhận CHỦ Ý không duplicate disclosure ("VIP suppression, the not-ready toast and every
safety gate live in AdManager — deliberately not duplicated here"). Codex không đọc `ad_screen.dart` nên kết
luận "no SDK-owned introductory screen" là sai cho đường tích hợp được khuyến nghị.

**Gap thật còn sót lại (hạ xuống MINOR):** `AdManager().showRewardedInterstitialAd()` — API tầng thấp, public,
export đầy đủ — hoàn toàn KHÔNG có disclosure lẫn cảnh báo nếu host bỏ qua `AdScreen` và gọi thẳng API này
(xác nhận: ví dụ có thật trong chính example app — `AppOpenDemoPage`/VIP watch-ad flow gọi `AdManager()` trực
tiếp cho các loại ad khác). Một host tự viết integration mà không dùng `AdScreen` sẽ không được SDK nhắc/enforce
gì về nghĩa vụ disclosure này — đúng nguy cơ compliance Codex mô tả, nhưng chỉ với nhóm host bỏ qua đường tích
hợp được khuyến nghị, không phải với SDK nói chung. Đề xuất: thêm `assert`/log cảnh báo ở tầng `AdManager` khi
gọi `showRewardedInterstitialAd` mà chưa từng gọi qua `AdScreen`, hoặc note rõ trong doc-comment của API tầng
thấp.

**M-01 (GPP state-section gap) — XÁC NHẬN THẬT**, trùng khớp độc lập với Gemini/agy's F-05 và nhánh audit nội
bộ của tôi (đã verify byte-for-byte đúng spec IAB cho phần code CÓ đọc — xem `audit_claude.md`). Đồng ý xếp
MINOR/MAJOR tuỳ mức độ rủi ro thị trường mục tiêu (MAJOR nếu app có nhiều user California/Colorado/Virginia
và CMP chỉ ghi state section, MINOR nếu CMP luôn ghi kèm national/MSPA section như đa số).

**M-02 (VIP replay cross-device) — XÁC NHẬN THẬT**, trùng với finding VIP của cả 3 nguồn (đã biết, đã
accepted-by-design trong kiến trúc "no backend" — xem `audit_claude.md` phần VIP).

**m-01 (Android trial renewable) — XÁC NHẬN THẬT**, trùng với F-01 (Gemini) và nhánh VIP của tôi.
