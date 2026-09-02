# Audit độc lập SDK `applovin_admob_sdk` 2.9.11 — Codex

**Ngày audit:** 2026-09-02  
**Revision:** `b0d0368`  
**Phạm vi:** toàn bộ `packages/ad_sdk/lib/`, `packages/ad_sdk/example/` và đối chiếu các audit cũ trong `doc/audit/`. Kết luận dưới đây dựa trên source hiện tại, không kế thừa kết luận cũ nếu chưa trace lại.

## Tóm tắt kết quả

| Mức độ | Số lượng |
|---|---:|
| BLOCKER | 1 |
| MAJOR | 6 |
| MINOR | 2 |
| Nitpick | 1 |

SDK có nền tảng lifecycle khá tốt: bốn fullscreen slot dùng state machine, watchdog/backoff, mutex chung; callback muộn được chặn bằng identity/epoch; tài nguyên và timer phần lớn được dispose có hệ thống; UMP chạy trước request quảng cáo; AdMob đặt COPPA/TFUA trước `MobileAds.initialize()`; App Open có expiry; banner/MREC/native được tách theo widget instance. Tuy nhiên, một lỗi fail-open trong bookkeeping consent đủ để chặn production. Ngoài ra, “dual provider” hiện là lựa chọn **một provider cho cả session**, không phải fallback runtime, và các cam kết trial/VIP/US privacy chỉ có mức bảo đảm local/best-effort.

## Findings

### BLOCKER-1 — Ghi nhận consent “đã apply” dù cả lệnh provider có thể đã thất bại

**Vị trí:** `lib/src/core/ad_consent.dart:142-172`, `174-219`; dữ liệu sai được dùng tại `lib/src/core/ad_manager.dart:4699-4703`, `4782-4809`, `5155-5175`.

**Cơ chế:** `applyConsentToProviders()` bọc riêng lệnh AppLovin và AdMob trong `try/catch`, nuốt exception ở dòng 170-172 và 207-209, nhưng sau đó luôn gán `_lastAppliedToProviders = c` ở dòng 219. `_committedConsent` coi biến này là trạng thái đã thực sự áp dụng. Các luồng reconcile/resume so TCF với `_committedConsent`; nếu chúng bằng nhau, SDK không retry provider write.

**Kịch bản tái hiện:** (1) phiên trước đang personalized; (2) người dùng rút consent hoặc bật “Do Not Sell”; (3) `AppLovinMAX.setHasUserConsent(false)` hoặc `MobileAds.updateRequestConfiguration()` ném `PlatformException`/timeout do channel/native SDK đang lỗi; (4) exception bị log rồi nuốt, `_lastAppliedToProviders` vẫn thành restrictive; (5) resume reconcile thấy device state bằng “committed” và return; provider thực tế vẫn giữ cấu hình permissive cũ, request tiếp theo có thể personalized/RDP sai. Đây là vi phạm consent thực, không chỉ sai telemetry.

**Khuyến nghị bắt buộc:** chỉ commit từng provider sau khi write thành công; trả kết quả apply có trạng thái theo provider; đóng ad gate khi apply restrictive chưa xác nhận; retry có epoch và timeout. Không được coi log warning là recovery.

### MAJOR-1 — Không có switch/fallback AdMob ↔ AppLovin trong runtime

**Vị trí:** `lib/src/config/ad_config.dart:380-424`; `lib/src/core/ad_manager.dart:455-477`, `561-577`; `lib/src/monetization/waterfall_tuner.dart:50-63`; example xác nhận thiết kế tại `example/lib/main.dart:151-165`, `222-224`.

**Cơ chế:** `AdConfig.provider` chọn đúng một adapter. `pickProviderCohort()` chỉ A/B cố định theo install; `SelfHealingObserver` chỉ observe; tài liệu trong `WaterfallTuner` thừa nhận provider không active không có dữ liệu nên không thể đề xuất switch trên thiết bị thật. Không tồn tại load failover theo slot hoặc circuit breaker đổi provider.

**Kịch bản:** cấu hình AdMob; Google init thành công nhưng placement bị no-fill/outage hoặc mediation adapter lỗi. SDK retry cùng AdMob (watchdog/backoff/5 phút), không thử AppLovin dù config AppLovin đầy đủ. Reinitialize để đổi provider cũng huỷ cache/view và không phải fallback trong cùng request.

**Tác động:** tên “dual-provider” đúng theo nghĩa hỗ trợ hai backend, nhưng không đáp ứng yêu cầu availability fallback. Không có race switch vì không switch; đổi lại không có HA giữa providers.

### MAJOR-2 — Rewarded Interstitial không có parity trên AppLovin

**Vị trí:** `lib/src/adapters/applovin_adapter.dart:197-203`; `lib/src/core/ad_manager.dart:6786-6794`, `6797-6836`, `6968-6984`.

**Cơ chế:** AppLovin adapter giữ slot vĩnh viễn `idle`; load/show là no-op. API công khai vẫn tồn tại nên caller chỉ nhận `shown=false`/`canShow=false`, không có capability API hoặc fallback sang rewarded/interstitial thường.

**Kịch bản:** host viết flow dùng `loadRewardedInterstitialAd()` rồi chuyển cohort/provider sang AppLovin. Cùng code chạy trên AdMob, nhưng trên AppLovin không bao giờ ready và periodic retry tiếp tục gọi no-op.

**Khuyến nghị:** công khai capability matrix hoặc fail-fast cấu hình; nếu sản phẩm yêu cầu parity, định nghĩa fallback UX rõ ràng (không tự thay rewarded-interstitial bằng format khác nếu chưa có consent của product/policy).

### MAJOR-3 — Trial 1 ngày không thể chống reset/reinstall một cách đáng tin cậy trên Android

**Vị trí:** `lib/src/config/ad_config.dart:511-533`; `lib/src/utils/ad_preferences.dart:187-207`; `lib/src/vip/_first_install_guard.dart:8-55`.

**Cơ chế:** cờ trial/first-init nằm trong SharedPreferences. iOS có Keychain backstop; Android chỉ trông vào Auto Backup của host app. Source tự ghi rõ backup/sync tắt hoặc account khác thì reinstall bypass. Xoá app data cũng xoá cờ. Package không thể buộc app tích hợp giữ đúng XML backup.

**Kịch bản:** Android Settings → tắt backup/sync (hoặc dùng account khác) → uninstall/reinstall, hay Clear storage → mở app. `isFirstInstallGraceApplied()` trả false, SDK cấp lại 24 giờ.

**Đánh giá:** chấp nhận được nếu đây chỉ là retention perk; không đạt yêu cầu entitlement/trial chống gian lận. Không thể sửa triệt để “không backend”.

### MAJOR-4 — VIP offline chống forge tốt, nhưng không chống chia sẻ/replay toàn cầu và revocation là tùy chọn fail-open

**Vị trí:** `lib/src/vip/signed_vip_key.dart:86-120`, `149-191`, `210-249`; `lib/src/vip/vip_manager.dart:1237-1246`, `1282-1313`, `1436-1494`; `lib/src/utils/ad_preferences.dart:336-356`.

**Cơ chế:** Ed25519 public-key verification đúng: decompile public key không tạo được chữ ký mới nếu private key được giữ ngoài app. Nhưng AVP1 vẫn được chấp nhận và không có expiry/bundle binding; một code hợp lệ có thể dùng trên mọi thiết bị. One-time ledger chỉ per-device; Android ledger là SharedPreferences có thể bị xoá. CRL chỉ có hiệu lực nếu host chủ động fetch, và fetch/cache lỗi thì fail-open. Hàm được mô tả “offline signed” nhưng `redeemSignedKey()` cố ý yêu cầu connectivity 2 giây, dù không bắt buộc kỹ thuật.

**Kịch bản:** một AVP1 code bị đăng công khai; mỗi thiết bị mới redeem một lần và đều được VIP. Hoặc code AVP2 bị revoke nhưng app chưa gọi `refreshRevocationList()`/đang offline/cache bị xoá: chữ ký vẫn hợp lệ và code được nhận.

**Khuyến nghị:** ngừng mint AVP1 và có deadline loại bỏ; bắt buộc AVP2 có expiry + bundle; phát hành CRL định kỳ. Muốn one-time/revocation chắc chắn phải có backend/attestation — không thể đạt bằng public-key offline thuần túy.

### MAJOR-5 — AVP2 bỏ qua bundle binding khi `PackageInfo` lỗi

**Vị trí:** `lib/src/vip/vip_manager.dart:1315-1345`; `lib/src/vip/signed_vip_key.dart:225-242`.

**Cơ chế:** nếu `PackageInfo.fromPlatform()` ném lỗi, manager log rồi truyền `currentBundleId=null`; verifier chỉ reject khi bundle hiện tại non-null/non-empty. Đây là fail-open trên chính ràng buộc chống dùng chéo app.

**Kịch bản:** plugin registration/channel lỗi trên một build, hoặc môi trường bị hook làm `PackageInfo` throw; nhập code AVP2 ký cho bundle khác. Signature/expiry qua, bundle check bị skip, VIP được grant.

**Khuyến nghị:** AVP2 có `boundBundle` không rỗng phải fail-closed khi không đọc được bundle ID.

### MAJOR-6 — “Consent mọi quốc gia” chưa tự động đầy đủ cho US state laws/COPPA AppLovin

**Vị trí:** `lib/src/consent/consent_settings.dart:12-18`, `27-28`, `39-46`; `lib/src/core/iab_storage.dart:145-161`; `lib/src/core/ad_consent.dart:24-31`, `101-128`, `142-168`; `lib/src/core/ad_manager.dart:5099-5139`.

**Cơ chế:** mặc định `doNotSell=false`; SDK chỉ tự reconcile legacy `IABUSPrivacy_String`. GPP được expose raw nhưng không parse/enforce. Do đó opt-out theo các US-state section mới không tự đi vào AppLovin `setDoNotSell`/AdMob RDP nếu CMP không đồng thời ghi legacy USP; widget CCPA cần host chủ động đặt vào UI. AppLovin Flutter 4.x không có COPPA setter: adapter chặn init nếu child flag đã biết, nhưng thay đổi sang child giữa session chỉ cảnh báo và yêu cầu host destroy/reinit.

**Kịch bản:** người dùng Virginia/Colorado bật opt-out trong CMP chỉ ghi GPP; `usPrivacyOptedOut()` trả null, `doNotSell` vẫn false, request không bật RDP. Hoặc age gate đổi adult→child sau AppLovin init; SDK vẫn đang initialized cho đến khi host tự reinit.

**Khuyến nghị:** không quảng cáo “mọi quốc gia” như zero-config; bắt buộc host/CMP map GPP jurisdictional choices vào `setConsent`, document privacy-options entry point, và tự động teardown/disable AppLovin ngay khi COPPA chuyển true.

### MINOR-1 — Reinit có thể mất fast reconnect và chờ tối đa chu kỳ 5 phút

**Vị trí:** `lib/src/core/ad_manager.dart:7322-7392`, `7406-7448`.

**Cơ chế:** teardown huỷ `_connectivitySub` nhưng giữ `_connectivityReady=true`. Nếu watch của phiên mới thất bại, periodic repair chỉ chạy khi `!_connectivityReady`; vì vậy không dựng lại subscription. Source tự ghi nhận residual gap ở dòng 7378-7386.

**Kịch bản:** init A tạo watch → destroy → init B, lần dựng watch B lỗi sau khi subscription cũ đã huỷ → offline→online không tạo refill; ad chỉ hồi ở poll tối đa 5 phút sau.

### MINOR-2 — Fresh-install time/trial vẫn phụ thuộc wall clock trước lần chạy đầu và storage local

**Vị trí:** `lib/src/utils/ad_preferences.dart:200-207`, `374-407`; `lib/src/vip/vip_manager.dart:301-366`.

**Cơ chế:** high-water mark giảm hiệu quả rollback sau khi SDK đã quan sát đồng hồ, nhưng không thể biết clock đã bị chỉnh trước lần chạy đầu; trên Android mark còn là SharedPreferences. Root/physical access có thể xoá mark rồi đưa clock vào cửa sổ VIP cũ.

**Kịch bản:** đặt giờ máy sai trước first launch rồi nhận grant, hoặc trên máy root xoá riêng `ad_sdk_vip_max_observed_clock_ms` và rollback clock. Kết quả có thể kéo dài/hồi sinh entitlement local. Đây là giới hạn của no-backend, không phải cryptographic clock.

### NITPICK-1 — Comment example về timeout UMP đã lỗi thời

**Vị trí:** `example/lib/main.dart:705-710`; timeout thực tế ở `lib/src/core/ump_consent.dart` (form-dismiss timeout và late-dismiss handling).

Comment nói consent form “no timeout” và có thể wedge splash mãi, trong khi implementation hiện có timeout/hard-cap. Không ảnh hưởng runtime nhưng làm QA hiểu sai hành vi.

## Đánh giá theo checklist

### 1. Dual provider, Android/iOS, race switch

- AdMob và AppLovin có adapter riêng, ID theo platform, callback/state/dispose tương đối chặt.
- Không thấy race double-show giữa bốn fullscreen format: `_fullscreenBusyReason` kiểm tra cả App Open, Interstitial, Rewarded, Rewarded Interstitial, UMP form, loading dialog và Flutter popup (`ad_manager.dart:1481-1515`). Các show path kiểm tra lại ngay trước present.
- Provider không switch tự động; reinit là teardown/rebuild. Vì thế “fallback an toàn” hiện không tồn tại, xem MAJOR-1.

### 2. Online/offline

- Load có gate connectivity, native init/load có timeout/watchdog; failure đi vào cooldown/backoff; reconnect refill và poll 5 phút; init retry hữu hạn 5/15/30 giây.
- Dispose có timeout và late-callback guards; không thấy crash/leak rõ ràng ở mất mạng giữa show.
- Khoảng trống reconnect sau reinit ở MINOR-1. VIP signed-code lại cố ý không redeem offline, trái kỳ vọng từ tên “offline signed”.

### 3. Banner/App Open/Rewarded/Interstitial

- Banner/MREC/native keyed per widget, dispose native object/notifier, ẩn hoặc pause refresh khi background/fullscreen/route; vẫn cần host wire `AdScreenRouteLogger` và tránh `IndexedStack` trần.
- App Open có freshness 4 giờ, resume debounce, splash budget và dialog/fullscreen mutex.
- Interstitial/Rewarded có freshness 1 giờ cho AdMob, reward chỉ cấp từ callback earned, reentrancy guard và safety cap.
- Rewarded Interstitial là AdMob-only. Không phát hiện logic ép click/xem trong SDK; việc host chọn placement vẫn quyết định policy. `bypassSafety` App Open và `bypassVipGuard` rewarded là API nhạy cảm nhưng có audit event/call-site tag; chỉ nên dùng đúng flow được mô tả.

### 4. Trial một ngày

- Logic 24 giờ release/30 giây debug và purge/expiry timer là nhất quán.
- Không đạt chống lách mạnh: Android Clear data/reinstall khi backup không phục hồi; clock/storage local vẫn có threat model nêu trên.

### 5. VIP code offline

- Không forge được code mới chỉ từ binary nếu Ed25519 private key không ship.
- Rotation bằng danh sách public key hoạt động; muốn retire key bị lộ phải xoá key cũ khỏi list. CRL hỗ trợ revocation nhưng host phải refresh.
- Không có global one-time use; AVP1 legacy và fail-open bundle check làm giảm đáng kể bảo đảm.

### 6. Consent

- UMP được sequence trước first ad request; TCF purpose 1/3/4 được kiểm tra; fail-closed khi platform store thật lỗi; ATT riêng với GDPR; AdMob nhận COPPA/TFUA trước initialize; AppLovin nhận consent/doNotSell.
- BLOCKER-1 phá tính đúng của retry/committed state khi native apply lỗi.
- GPP/US-state và COPPA AppLovin chưa zero-config đầy đủ; cần host integration.

### 7. Policy AdMob/AppLovin

- Có frequency/session/hour/day/placement caps, invalid-traffic cooldown, impression/click event, test IDs và fullscreen stacking guard.
- SDK không thể bảo đảm placement của host: caller vẫn phải dùng interstitial ở natural transition, giữ khoảng cách click với banner, cung cấp privacy policy/app-ads.txt và không dùng bypass API để spam.
- BLOCKER-1 và MAJOR-6 là rủi ro policy/compliance trực tiếp.

## Kiểm chứng tự động

- `flutter analyze` tại `packages/ad_sdk/`: **No issues found**.
- `flutter test` tại `packages/ad_sdk/`: **1553/1553 passed**.
- Các test trên không phủ lỗi BLOCKER-1: test consent hiện xác nhận happy path, không inject failure riêng cho từng provider rồi kiểm tra `_lastAppliedToProviders`/retry.
- Không chạy integration test thiết bị thật trong checkout này; do đó plugin/native behavior iOS (đặc biệt IAB storage) vẫn cần device verification như source tự ghi tại `iab_storage.dart:39-41`.

## Kết luận production

**Không nên đưa nguyên trạng 2.9.11 vào production app.** Phải sửa và regression-test **BLOCKER-1** trước khi phát hành. Sau đó có thể dùng với điều kiện:

1. Chấp nhận rằng dual-provider là build/session selection, không phải runtime failover; hoặc triển khai fallback có state/consent/cap ownership rõ ràng.
2. Nếu dùng AppLovin, không yêu cầu Rewarded Interstitial và không phục vụ child-directed traffic; nếu age có thể đổi runtime, phải tự động disable/reinit provider.
3. Cấu hình UMP/CMP trên console, privacy-options UI, US-state/GPP mapping, ATT/Info.plist, app-ads.txt và placement policy ở host app.
4. Xem trial/VIP là entitlement local best-effort. Nếu có giá trị tài chính hoặc yêu cầu one-time/revocation đáng tin cậy, bắt buộc thêm backend; chỉ phát AVP2 bound + expiring và refresh signed CRL.
5. Chạy smoke/integration trên Android và iOS thiết bị thật cho init, consent withdrawal, offline→online, background/resume và từng format trước rollout; canary rollout với telemetry load/show/impression/consent-apply failures.
