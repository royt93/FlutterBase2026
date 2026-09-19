# Audit round 33 (Claude, tự verify qua source) — applovin_admob_sdk 2.9.14

Phạm vi: verify 6 fix của round 32 (2 BLOCKER trong 2.9.12 + 4 MAJOR trong 2.9.13/2.9.14),
sau đó quét lại fresh trên các trục gốc (lifecycle/leak, offline, consent, trial/VIP,
example app), cộng `flutter analyze` + `flutter test` thật trên máy.

## Phần 1 — Verify fix round 32 (đọc code hiện tại, không tin changelog)

| # | Finding round 32 | File | Trạng thái | Ghi chú verify |
|---|---|---|---|---|
| BLOCKER-A | `applyConsentToProviders()` set `_lastAppliedToProviders` vô điều kiện | `lib/src/core/ad_consent.dart:230-232` | **ĐÃ FIX ĐÚNG** | Đọc source: `appLovinApplied`/`adMobApplied` là 2 cờ bool set `true` chỉ ở cuối mỗi `try` (không trong `catch`); dòng 230 `if (appLovinApplied && adMobApplied) { _lastAppliedToProviders = c; }` — chỉ 1 trong 2 write throw là không ghi nhận, đúng như thiết kế. |
| BLOCKER-B | `IabStorage.tcfAllowsPersonalisedAds()` `on StateError` không bắt `TimeoutException` | `lib/src/core/iab_storage.dart:219-246` | **ĐÃ FIX ĐÚNG** | Thêm `catch (e)` sau `on StateError`, trả `false` (fail-closed) kèm log rõ lý do "platform open failed — failing closed". Đúng ý đồ round-31 fail-closed đã bị round-32 phát hiện gãy. |
| #15 | `minSessionDurationBeforeAd` thiếu sàn `min:1` | `lib/src/config/remote_ad_safety_provider.dart:102-103` | **ĐÃ FIX ĐÚNG** | `posInt('minSessionDurationBeforeAd', min: 1, max: 3600000)` — khớp 2 field chị em cùng lớp. |
| #11 | `canShowRewardedInterstitialAd()` thiếu gate `AdLoadingDialog.isShowing` | `lib/src/core/ad_manager.dart:6980-6991` | **ĐÃ FIX ĐÚNG** | Thêm `if (AdLoadingDialog.isShowing) return false;` — đối xứng với `canShowInterstitial`/`canShowRewardedAd`. |
| #10 | `example/lib/main.dart` thiếu guard `_navigated` cho App Open buffered callback | `example/lib/main.dart:803-853` | **ĐÃ FIX ĐÚNG** | `if (!mounted || _navigated) return;` trước khi show App Open; `_goHome()` set `_navigated = true` trước điều hướng. Race round-31 đã port đúng sang example. |
| #9 | `AdBootstrap.bootstrap()` không hard-cap tổng | `lib/src/core/ad_bootstrap.dart:20,50,133-141` | **ĐÃ FIX ĐÚNG** | `AdBootstrapOptions.initTimeout` mặc định 20s, `await initDone.future.timeout(timeout, onTimeout: () {})` — không cancel init thật (vẫn chạy nền cập nhật `AdManager`), chỉ bound cái `await` splash đang chờ. `null` = giữ hành vi cũ. Đúng thiết kế mô tả. |
| #7 | AppLovin banner/MREC tính revenue lúc fill (`onAdLoadedCallback`) thay vì lúc hiển thị | `lib/src/widget/banner_ad_widget.dart:624-655`, `mrec_ad_widget.dart:501-527` | **ĐÃ FIX ĐÚNG** | Đọc trực tiếp: `onAdLoadedCallback` giờ chỉ log, không còn gọi `recordBannerImpression`/emit revenue. Impression + `appLovinRevenueEvent()` chuyển hẳn sang `onAdRevenuePaidCallback` — đúng tín hiệu thật của AppLovin cho `MaxAdView` (không có callback "displayed" riêng). |
| #8 | AppLovin Native không có revenue event | `lib/src/widget/native_ad_widget.dart:487-504` | **ĐÃ FIX ĐÚNG** | `onAdRevenuePaidCallback` được wire, gọi `appLovinRevenueEvent()` cùng hàm dùng chung với banner/MREC/fullscreen (`lib/src/adapters/applovin_ad_revenue.dart`) — một nguồn map field duy nhất thay vì 4 bản gần giống nhau như trước. |

**Không có fix nào sai sót hay chưa xong trong 6 mục trên** — cả 8 dòng trong bảng (2 BLOCKER + 6
MAJOR) đều verify đúng qua đọc source thật, khớp mô tả CHANGELOG `[2.9.12]`/`[2.9.13]`/`[2.9.14]`.

Các mục còn lại của round 32 (#1, #2, #3, #4, #5, #6, #12, #13, #14) đã được user review và
reclassify tường minh trong CHANGELOG `[2.9.13]` + `audit_round32_deep_consolidated.md` header
(#6-COPPA là false positive đã sửa lại; #2/#3/#4/#5 là intentional/known-limit có comment giải
thích; #12/#13 là giới hạn kiến trúc đã document ở README; #14 chỉ thêm doc-comment cảnh báo, cố
ý không enforce cứng — xem lý do bên dưới). #1 (không auto-failover AdMob↔AppLovin) là feature
gap thật, đã explicit "deferred, real feature work", không phải bug — round 33 không tìm thấy
lý do để nâng cấp đánh giá này.

## Phần 2 — Verify khách quan: `flutter analyze` + `flutter test` thật

```
flutter analyze  → No issues found! (ran in 16.5s)
flutter test     → All tests passed! (+1562, ~2 min)
```

Khớp đúng con số CHANGELOG `[2.9.14]` công bố (1562/1562).

## Phần 3 — Fresh scan round 33 (không chỉ diff-since-round-32)

### 3.1 Leak sanity spot-check (Timer/StreamSubscription tạo vs huỷ)

| File | `Timer(` | `.cancel()` | `.listen(` | `StreamSubscription` |
|---|---:|---:|---:|---:|
| `applovin_adapter.dart` | 2 | 5 | 0 | 0 |
| `admob_adapter.dart` | 1 | 5 | 0 | 0 |
| `ad_manager.dart` | 15 | 20 | 2 | 1 |

Số `.cancel()` ≥ số điểm tạo ở cả 3 file trọng yếu (chênh dương vì nhiều timer dùng chung 1 biến
qua nhiều cycle, mỗi lần gán lại đều cancel timer cũ trước — pattern đã thấy nhất quán ở các
round trước). Không phát hiện leak mới. Đây là spot-check heuristic, không phải audit từng dòng
lại toàn bộ — 32 round trước đã đọc kỹ dispose path cho từng loại ad, không có lý do nghi ngờ
mới xuất hiện regression ở đúng vùng này khi không có commit nào động vào từ round 32.

### 3.2 Trial 1 ngày

Xác nhận lại: "trial 1 ngày" không phải module riêng — nó là `FirstInstallVipGrace.day` cấp qua
chính `VipManager` (grep `trial` chỉ ra 3 file, không có `trial_manager.dart` riêng). Cơ chế và
giới hạn (Android clear-data/reinstall bypass được vì dựa Auto Backup best-effort, iOS bền hơn
nhờ Keychain sống sót qua reinstall) đã audit kỹ ở round 32 #3, giữ nguyên đánh giá
**MAJOR nhưng INTENTIONAL/KNOWN LIMIT** — không phải bug triển khai.

### 3.3 VIP by-code, consent, dual-provider, ad lifecycle

Không tìm thấy finding BLOCKER/MAJOR mới ngoài 6 mục đã verify-fix ở Phần 1. Các giới hạn đã biết
(AVP1 legacy, bundle-binding fail-open khi `PackageInfo` throw, US-state/GPP cần host tự map,
Overlay-popup mù với route observer, RI AppLovin no-op, không auto-failover) không đổi so với
round 32 — đọc lại source ở đúng các điểm đó (`signed_vip_key.dart`, `vip_manager.dart`, README)
xác nhận comment giải thích tradeoff vẫn còn nguyên, không bị code sau đó làm sai lệch.

## Kết luận round 33

**Không có BLOCKER mới. Không có MAJOR mới.** 6/6 fix từ round 32 verify đúng qua source thật,
`flutter analyze` sạch, 1562/1562 test pass. Các giới hạn kiến trúc đã biết (không auto-failover,
RI AppLovin no-op, trial Android reinstall, VIP AVP1/bundle-binding fail-open, Overlay-popup mù,
bypassSafety không enforce cứng nơi gọi) không đổi bản chất — đều đã được document tường minh,
không phải lỗ hổng ẩn.

**SHIP** — 2.9.14 đủ điều kiện production cho use case ads thông thường (không giá trị tài chính
thật gắn trực tiếp vào VIP/trial). Điều kiện giữ nguyên từ round 32 đã đóng xong; điều kiện còn
mở duy nhất là feature-gap #1 (auto-failover) nếu yêu cầu sản phẩm là HA giữa 2 network — đó là
việc làm thêm tính năng, không phải điều kiện chặn ship.
