# Audit độc lập `applovin_admob_sdk` — agy CLI (bản hợp nhất, round 1 + round 2)

Hợp nhất `audit_agy_20260815.md` (round 1, version 2.0.4, 700 test) và `audit_agy_20260819_round2.md` (round 2, version 2.1.0, 860 test). Round 2 supersede round 1 khi có xung đột hoặc re-verify cùng finding; phần round 1 chưa được round 2 chạm tới vẫn giữ nguyên, đánh dấu rõ.

**Người audit:** Senior Flutter/Mobile Ads Engineer (agy CLI, cả 2 round).

---

## Trạng thái các bug round 1 sau round 2

| # | Finding round 1 | Trạng thái tại round 2 |
|---|---|---|
| 1.1 | `_admobIsTop` không init đúng khi banner/MREC mount trên route hiện tại → hiện khoảng trắng | **Chưa re-verify riêng ở round 2** — không nằm trong danh sách finding round 2, không có bằng chứng đã fix. Coi là **còn mở, cần audit lại**. |
| 1.2 | `MonetizationArbitrator` lệch tỷ lệ 1000x eCPM → veto gần 100% ad | **Chưa re-verify ở round 2.** Không nằm trong finding round 2 (không rõ đã fix hay round 2 không chạm module này). **Ưu tiên cao cho lần audit sau** — nếu đúng như mô tả, đây là bug mức Blocker (chặn toàn bộ doanh thu), không phải P0 thường. |
| 1.3 | `ConsentManager.showDialog()`/`set()` không gỡ `_footgunBlocked` | Không thấy round 2 nhắc lại trực tiếp — có thể đã fix cùng loạt sửa `autoRequestUmpConsent` default 08-19, nhưng **chưa có xác nhận rõ**. Giữ mở cho tới khi verify. |
| 1.4 | `VipEntriesStore.setRaw` nuốt lỗi Keystore, đánh dấu migrated dù ghi thất bại → mất VIP vĩnh viễn | Không nằm trong round 2. **Chưa verify — giữ mở.** |
| 1.5 | Nhiều `NativeAdWidget`/`BannerAdWidget` cùng lúc trên AdMob crash do singleton `_nativeAd`/`_bannerAd` trong adapter | Không nằm trong round 2. **Chưa verify — giữ mở.** |
| 1.6 | `_lastBackgroundTime` giữ mốc cũ khi Android bắn `paused`/`resumed` dồn nhanh | Không nằm trong round 2. **Chưa verify — giữ mở**, mức độ P2 theo round 1. |

Round 2 tập trung sâu vào 7 khu vực audit chính (dual-provider, offline/online, ad lifecycle/leak, trial/VIP, consent, policy) hơn là re-scan toàn bộ finding cũ — nên các mục trên **không bị bác bỏ**, chỉ đơn giản là round 2 không đi qua lại. Coi 1.1–1.6 là backlog còn treo, ưu tiên xác minh lại 1.2 trước (khả năng ảnh hưởng doanh thu toàn bộ).

---

## Findings round 2 (2026-08-19, version 2.1.0, 860/860 test pass, 0 issues analyze)

### Đã fix trong loạt sửa 08-19 (xác nhận trực tiếp)
1. Show-time freshness validation cho toàn bộ AdMob fullscreen format (`admob_adapter.dart:677-689`).
2. Resumed App Open ad tuân thủ safety cap (`ad_manager.dart:2743-2746`).
3. AppLovin native `MaxAdView` destroy khi widget unmount (`applovin_adapter.dart:157-161,229-233`) — **lưu ý:** round 2 chỉ xác nhận lệnh gọi destroy tồn tại, KHÔNG xác minh sâu native source có thực sự destroy thành công khi view còn attach hay không. Xem `audit_claude.md` mục B1 — vòng audit Claude 08-20 xác nhận native `destroyWidgetAdView` từ chối destroy khi `hasContainerView()==true`, nên leak vẫn tồn tại trong trường hợp dispose khi banner đang hiển thị. **agy round 2 không phát hiện được nuance này** — đáng lưu ý cho phương pháp audit: xác nhận API được gọi không đồng nghĩa hành vi native phía dưới thành công.

### Major/Minor còn mở tại round 2
2. Android Trial/VIP-replay protection hoàn toàn phụ thuộc host tự wire Auto Backup manifest (`_first_install_guard.dart:27-47,126-133`, `_redeemed_key_ledger.dart:16-23,49-51`) — nếu host quên set `allowBackup`/`dataExtractionRules`/`fullBackupContent`, Android user uninstall/reinstall lấy lại trial + tái sử dụng VIP code single-use vô hạn. Đề xuất: thêm check runtime trong `releaseFootgunWarnings` cảnh báo nếu thiếu config này.
3. Consent revoke giữa phiên không tự flush/reload fullscreen slot đã ready trước đó (đề xuất: `AdManager.setConsent`/`_syncConsentToAdapter` nên trigger reload slot đang ready khi consent bị revoke).
4. Rewarded Interstitial trên AppLovin fail không có diagnostic rõ ràng — `shown:false` giống hệt trường hợp "chưa ready" bình thường, không phân biệt được với "provider không hỗ trợ format này" (trùng với `audit_claude.md` finding M4, ở đó có thêm phát hiện orchestrator còn báo sai `shown:true` — 2 vấn đề khác nhau trên cùng 1 tính năng).
5. Clock rollback protection có giới hạn trước lần chạy đầu tiên (`vip_manager.dart:190-198`, `vip_entry.dart:38-41`) — liên quan `audit_claude.md` finding B3 (forward-rồi-lùi), đọc kèm.

### Confirmed-correct (round 2)
- Dual-provider adapter 100% method parity.
- Show-time ad freshness enforcement cho AdMob (4h App Open, 1h interstitial/rewarded).
- Native view disposal — cả AdMob và AppLovin banner/MREC/native đều gọi teardown lúc widget unmount (xem lưu ý ở trên về nuance chưa bắt được).
- Reactive state engine — `ValueNotifier`/`Stream` subscription sạch, không leak qua route transition.
- Offline resilience: mọi async operation có timeout, fail fast khi mất mạng, reload debounce khi reconnect.
- Zero-backend VIP crypto: Ed25519 offline, rotation support, bundle binding, CRL domain-separated.
- Anti-tamper/anti-fraud: daily cap, CTR anomaly detection, click-spam throttle, safety param force-enforce ở release.
- Global privacy compliance: UMP, IAB TCF string, CCPA/RDP per-request tagging, COPPA fail-closed, iOS ATT coordination.
- Reward integrity: reward chỉ cấp qua callback thật, không optimistic granting.

---

## Enhancement / Technical debt / Feature ideas (giữ từ round 1, chưa bị round 2 phủ định)

- Debounce/batch `AdEventLog` — ghi SharedPreferences mỗi event đơn lẻ có thể gây jank ở tần suất cao (`ad_event_log.dart:88-97`).
- Fallback an toàn cho `VipEntriesStore` khi secure storage lỗi trên Android giá rẻ/custom ROM (`_vip_entries_store.dart:42-90`) — liên quan trực tiếp bug 1.4 còn mở.
- `AdManager().vip` trả `null` tới khi init xong, chưa có `ValueListenable` để host lắng nghe thời điểm sẵn sàng thay vì tự poll `initRevision`.
- `NativeAdWidget` cố định `TemplateType.medium`/height 320 — nên cho custom size/template cho in-feed layout.
- Roadmap nâng Flutter 3.38+/Dart 3.10+ để mở khoá `google_mobile_ads` 8/9 (10 điểm pub.dev còn thiếu) — đã biết từ CLAUDE.md, breaking change nếu làm.
- CI iOS simulator vẫn mất 16-18 phút dù đã shard 3 runner — có thể tối ưu thêm boot time/log stream.
- `1 << 62` trong `AdEventLog.inRange` có rủi ro nếu compile sang Web/Wasm (giới hạn 53-bit của JS) — hiện tại không phải target platform nên priority thấp.

## Flagship differentiators (giữ nguyên, không đổi qua 2 round)

- VIP entitlement Ed25519 hoàn toàn offline, bundle-id + expiry binding (AVP2), chống decompile-forge, chống rollback, chống replay reinstall (iOS Keychain).
- Ad Safety Engine nhiều tầng + Policy Risk Score theo thời gian thực — khác biệt rõ so với wrapper ad thông thường.
- Compliance report xuất được 1 dòng code — hữu ích khi tài khoản AdMob/AppLovin bị flag invalid traffic và cần bằng chứng kháng cáo.
- Smart Monetization Arbitrator — **lưu ý:** nếu bug 1.2 (eCPM scale ×1000) chưa fix, tính năng flagship này đang tự chặn gần hết doanh thu thay vì tối ưu nó. Verify bug này trước khi quảng cáo tính năng này với ai.

---

## Khuyến nghị cuối (đứng từ round 2, là kết luận hiện hành)

**YES-WITH-CONDITIONS.**

Điều kiện bắt buộc trước khi deploy production:
1. **Publish version 2.1.0 lên pub.dev** (hoặc pin git ref `main`) — code tại `main` (2.1.0) production-grade, nhưng app không được pull `2.0.4` từ pub.dev vì thiếu các fix 08-16 đến 08-19.
2. Đóng gap Android trial/VIP-replay Auto Backup opt-in (thêm cảnh báo runtime nếu thiếu, hoặc chấp nhận rủi ro có ghi rõ trong README cho từng app).
3. ~~**Xác minh lại bug 1.2 (eCPM scale) và 1.4 (VipEntriesStore nuốt lỗi Keystore) trước khi ship**~~ — **ĐÃ HOÀN THÀNH Ở ROUND 3 (2026-08-20)**: Toàn bộ 6 backlog bug từ Round 1 (bao gồm 1.2 và 1.4) đã được verify trực tiếp trên mã nguồn: 5 bug đã fix, 1 bug refuted (không phải bug). Nguy cơ Blocker từ eCPM đã hoàn toàn được loại bỏ.
4. Đối với Rewarded Interstitial trên AppLovin: thêm log cảnh báo rõ ràng khi provider không hỗ trợ, tránh host nhầm với lỗi ready bình thường.

---

## Round 3 re-verify (2026-08-20)

Đã kiểm tra trực tiếp toàn bộ source code thực tế và test suite cho cả 6 bug từ Round 1 còn tồn đọng trong backlog. Kết quả: **5/6 bug ĐÃ FIX** trong các task từ 2026-08-15 đến 2026-08-16 (có test suite khoá hành vi đi kèm), **1/6 KHÔNG PHẢI BUG** (Refuted do claim gốc hiểu sai hành vi đồng bộ của Flutter SDK `RouteObserver`).

### Bảng tổng hợp trạng thái Round 3

| # | Bug / Finding Round 1 | Trạng thái (CONFIRMED CÒN MỞ / ĐÃ FIX / KHÔNG PHẢI BUG) | Evidence file:line | Severity nếu còn mở |
|---|---|---|---|---|
| 1.1 | `_admobIsTop` không init đúng khi banner/MREC mount ngay trên route hiện tại → hiện khoảng trắng tạm thời | **KHÔNG PHẢI BUG** (REFUTED) | `lib/src/widget/banner_ad_widget.dart:73-82,130-146,274-280`<br>`lib/src/widget/mrec_ad_widget.dart:73-82,109-124,238-245`<br>`doc/task/done/T57-admob-top-flag-first-route.md`<br>`test/banner_ad_widget_test.dart:180-220` | N/A |
| 1.2 | (Ưu tiên cao) `MonetizationArbitrator` lệch tỷ lệ eCPM ×1000 → veto gần 100% ad | **ĐÃ FIX** (Fixed 2026-08-15 trong T58) | `lib/src/monetization/monetization_arbitrator.dart:111-115`<br>`test/monetization_arbitrator_test.dart:196-234`<br>`doc/task/done/T58-monetization-arbitrator-ecpm-unit-scale.md` | N/A (Đã giải quyết nguy cơ Blocker) |
| 1.3 | `ConsentManager.set()` hoặc flow show consent dialog không clear `_footgunBlocked` sau khi user đồng ý consent | **ĐÃ FIX** (Fixed 2026-08-15 trong T60 / N2) | `lib/src/core/ad_manager.dart:1227-1228,2087-2089`<br>`doc/task/done/T60-consent-footgun-builtin-dialog-narrow-config.md`<br>`test/ad_manager_core_test.dart` | N/A |
| 1.4 | `VipEntriesStore.setRaw` nuốt lỗi khi ghi Keystore/secure storage thất bại nhưng vẫn đánh dấu đã migrate | **ĐÃ FIX** (Fixed 2026-08-15 trong T59 + T71) | `lib/src/vip/_vip_entries_store.dart:65-81,88-108`<br>`test/vip_entries_store_test.dart:183-255`<br>`doc/task/done/T59-vip-entries-store-swallow-write-failure.md`<br>`doc/task/done/T71-vip-entries-store-fallback-storage.md` | N/A |
| 1.5 | Nhiều instance `NativeAdWidget`/`BannerAdWidget` cùng lúc trên AdMob provider bị crash do adapter dùng singleton field `_nativeAd`/`_bannerAd` | **ĐÃ FIX** (Fixed 2026-08-16 trong T65) | `lib/src/adapters/admob_adapter.dart:158-159,213-214,265-279,342-351`<br>`lib/src/widget/banner_ad_widget.dart:66-70`<br>`lib/src/widget/native_ad_widget.dart`<br>`doc/task/done/T65-native-banner-widget-instance-conflict.md`<br>`example/integration_test/multi_instance_ad_test.dart` | N/A |
| 1.6 | `_lastBackgroundTime` bị stale khi Android fire event paused/resumed liên tiếp nhanh (app switcher, multi-window) | **ĐÃ FIX** (Fixed 2026-08-16 trong T66) | `lib/src/core/ad_safety_config.dart:263-270,546-567,645-650`<br>`test/ad_safety_config_test.dart:468-492`<br>`doc/task/done/T66-safety-config-last-background-time-stale.md` | N/A |

### Chi tiết phân tích & Bằng chứng mã nguồn Round 3

1. **Bug 1.1 (`_admobIsTop` route initialization) — KHÔNG PHẢI BUG (REFUTED):**
   - **Cơ chế hoạt động:** Trong Flutter SDK (`RouteObserver.subscribe(routeAware, route)`), `subscribers.add(routeAware)` luôn gọi `routeAware.didPush()` đồng bộ ngay lập tức khi đăng ký lần đầu, bất kể route đó là route mới push hay route đã active từ trước.
   - **Mã nguồn:** Trong `banner_ad_widget.dart:78` và `mrec_ad_widget.dart:78`, `adRouteObserver.subscribe(this, route)` được gọi trong `didChangeDependencies()`. Ngay sau đó `didPush()` (`banner_ad_widget.dart:141-144`, `mrec_ad_widget.dart:118-121`) kích hoạt postFrameCallback gán `_admobIsTop.value = true`.
   - **Xác nhận:** Đã có test khóa hành vi trong `banner_ad_widget_test.dart` và `mrec_ad_widget_test.dart` (xem chi tiết tại `doc/task/done/T57-admob-top-flag-first-route.md`).

2. **Bug 1.2 (`MonetizationArbitrator` eCPM scale ×1000) — ĐÃ FIX (T58):**
   - **Nguyên nhân gốc:** `AdRevenueEvent.valueMicros` lưu doanh thu của **1 impression** (vd 5,000 micros = $0.005), trong khi `ecpmThresholdMicros` so sánh theo mốc eCPM chuẩn (**1,000 impressions**, vd 5,000,000 micros = $5.00 eCPM).
   - **Mã nguồn đã fix:** Tại `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart:111-115`:
     ```dart
     int get estimatedEcpmMicros {
       if (_samples.isEmpty) return 0;
       final sum = _samples.fold<int>(0, (a, b) => a + b);
       return sum * 1000 ~/ _samples.length;
     }
     ```
   - **Xác nhận:** Đã nhân `sum * 1000` đúng chuẩn eCPM. Unit test `T58 — eCPM unit conversion` trong `test/monetization_arbitrator_test.dart:196-234` kiểm tra ad đạt $5 eCPM không bị veto nhầm ở threshold $5 eCPM.

3. **Bug 1.3 (`ConsentManager` / `_footgunBlocked` clearance) — ĐÃ FIX (T60):**
   - **Cơ chế đã fix:** Cờ `_footgunBlocked` được giải phóng (`= false`) và `_consentExplicitlySet = true` tại tất cả các luồng hoàn tất consent:
     - `AdManager._maybeScheduleConsentDialog()` (`ad_manager.dart:1227-1228`) sau khi dialog built-in đóng lại.
     - `AdManager.setConsent()` (`ad_manager.dart:2087-2089`) khi host app gọi hoặc từ `requestUmpConsentFlow()` (`ad_manager.dart:2244`).
   - **Xác nhận:** Không còn trường hợp user đã tương tác consent hợp lệ mà vẫn bị kẹt `_footgunBlocked` ở release mode. Đã có regression test trong `test/ad_manager_core_test.dart`.

4. **Bug 1.4 (`VipEntriesStore.setRaw` nuốt lỗi Keystore) — ĐÃ FIX (T59 + T71):**
   - **Mã nguồn đã fix:** Tại `packages/ad_sdk/lib/src/vip/_vip_entries_store.dart:88-108`:
     ```dart
     Future<void> setRaw(String json) async {
       final wrote = await _writeSecure(json);
       if (wrote) {
         await _legacyPrefs.markVipEntriesSecureMigrated();
         await _legacyPrefs.clearVipEntriesFallbackRaw();
       } else {
         await _legacyPrefs.setVipEntriesFallbackRaw(json);
       }
     }
     ```
   - Tương tự trong `getRaw()` (`_vip_entries_store.dart:65-81`), chỉ clear legacy data và đánh dấu migrated khi `_writeSecure(legacy)` thành công (`wrote == true`).
   - **Xác nhận:** Khi Keystore/Keychain lỗi, hệ thống không đánh dấu migrated sai sự thật và lưu trữ dự phòng qua checksum-prefixed fallback storage (T71), đảm bảo VIP grant không bị mất. Kiểm chứng qua `test/vip_entries_store_test.dart:183-255`.

5. **Bug 1.5 (Nhiều `NativeAdWidget`/`BannerAdWidget` crash trên AdMob) — ĐÃ FIX (T65):**
   - **Mã nguồn đã fix:** `AdMobAdapter` (`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:158-159, 213-214, 265-279, 342-351`) đã thay thế toàn bộ singleton ad instances bằng keyed map:
     - `final Map<Object, BannerAd> _bannerAdsByKey = {};`
     - `final Map<Object, BannerAd> _mrecAdsByKey = {};`
     - `final Map<Object, NativeAd> _nativeAdsByKey = {};`
     - Kèm theo các map quản lý slot, listenables và route pause riêng cho từng instance key.
   - **Xác nhận:** Hỗ trợ N instance đồng thời độc lập. Đã xác nhận qua unit tests, widget tests, integration test `example/integration_test/multi_instance_ad_test.dart` và test thực tế trên Pixel 7 Pro.

6. **Bug 1.6 (`_lastBackgroundTime` stale khi resume nhanh) — ĐÃ FIX (T66):**
   - **Mã nguồn đã fix:** Thêm cờ one-shot `_pendingResumeGate` trong `packages/ad_sdk/lib/src/core/ad_safety_config.dart:263-270`.
     - `recordAppWentBackground()` (`ad_safety_config.dart:645-650`) set `_pendingResumeGate = true`.
     - `_canShowAppOpenOnResumeStrict` (`ad_safety_config.dart:546-558`) kiểm tra: nếu `_pendingResumeGate == false` (phantom resume từ notification shade/permission dialog không qua `paused`), lệnh show bị chặn ngay lập tức với lý do `spurious lifecycle event`, tránh dùng lại timestamp `_lastBackgroundTime` cũ từ trước đó.
   - **Xác nhận:** Test xác thực tại `test/ad_safety_config_test.dart:468-492` ("blocks a phantom resumed that has no new paused since the last check").

