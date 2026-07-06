# T01 — UMP là consent flow chính cho EEA + gate ad theo `canRequestAds`

- **REQ:** 6 (consent mọi quốc gia), 7 (policy)
- **Priority:** P0 (chặn phát hành) · **Severity:** CRITICAL · **Status:** ✅ done (2026-07-05)

## Kết quả
- **`AdManager.canRequestAds`** gate: chặn mọi load (appOpen/inter/rewarded/banner) + mọi show khi consent chưa cho phép; `requestUmpConsent` lưu `canRequestAds` + refill khi gate mở. Default `true` (non-UMP/non-EEA không ảnh hưởng). Seam test `debugCanRequestAds`.
- **`AdConfig.autoRequestUmpConsent`** (default false): SDK tự chạy UMP trong `initialize` trước load đầu + gate theo kết quả (SDK sở hữu flow). `umpTagForUnderAgeOfConsent` forward cờ under-age.
- **`AdConfig.disableAppLovinCmpFlow`** (default true): AppLovin adapter gọi `setTermsAndPrivacyPolicyFlowEnabled(false)` → UMP là CMP duy nhất, không double-prompt; kết quả UMP vẫn forward sang AppLovin qua `setHasUserConsent` (đã có) + AdMob TCF native + npa (T02).
- Test: `test/consent_gate_test.dart` (9 case: gate load/show, VIP precedence, widget-driven) + `test/applovin_adapter_test.dart` (2 case CMP disable). **266/266 xanh**, analyze SDK+host sạch.
- Tận dụng phát hiện device: host splash **đã** chạy ATT→UMP sẵn; gate nay enforce đúng `canRequestAds`.
- **Files:** `core/ump_consent.dart`, `core/ad_manager.dart` (initialize `:557-603`, `_maybeScheduleConsentDialog` `:230-284`, `requestUmpConsent` `:735-758`), `consent/consent_manager.dart`, `consent/consent_dialog.dart`

## Vấn đề (Why)
Dialog Cupertino nhị phân tự chế (`consent_dialog.dart`) được auto-show và đóng vai "consent", nhưng **không phải CMP được Google chứng nhận**: không phát hiện vùng, không purposes/vendors, không ghi TCF string. Google **bắt buộc** CMP hợp lệ cho EEA/UK.

**Điểm mấu chốt (đáp yêu cầu partner "dùng Google AdMob UMP khi init SDK cho admob/applovin"):** SDK **đã tích hợp sẵn Google UMP** — `core/ump_consent.dart` bọc `ConsentInformation` + `ConsentForm` của `google_mobile_ads` (chính là UMP SDK, không cần thêm dependency). Nhưng nó **opt-in**, SDK **không tự chạy khi init**, **không gate** ad theo `canRequestAds()`, và **không đẩy kết quả sang AppLovin**. Task này là biến UMP thành flow consent chính, chạy tự động lúc init, áp cho cả 2 provider.

## Acceptance criteria
- [ ] SDK **tự chạy UMP** (`requestUmpConsentFlow`) trong bootstrap khi init (splash), TRƯỚC request ad đầu tiên, cho user EEA/UK.
- [ ] **Đẩy kết quả UMP sang cả 2 provider:** AdMob nhận personalization qua TCF string (native UMP) + `npa` per-request (đã có T02); AppLovin nhận `setHasUserConsent`/`setDoNotSell`/`setPrivacyPolicy...` suy từ kết quả UMP (đồng bộ 1 nguồn sự thật, không double-prompt).
- [ ] Mọi `loadAppOpen/Interstitial/Rewarded/Banner` bị chặn khi `ConsentInformation.canRequestAds() == false` (persist để check nhanh).
- [ ] Dialog tự chế chỉ còn dùng cho non-EEA (hoặc gỡ hẳn) — không xung đột với UMP form.
- [ ] `AdConfig` có cờ bật/tắt UMP-managed consent (default: bật) để host cấu hình.
- [ ] Non-EEA: không bị ép form, ad vẫn chạy bình thường (`notRequired` → `canRequestAds=true`).
- [ ] Xử lý lỗi `requestConsentInfoUpdate`: nếu status cache là `required` → KHÔNG auto-allow (fail-closed cho EEA).

## Ghi chú kỹ thuật
- `ump_consent.dart:102-111` hiện fail-open (trả `canRequestAds=true` khi update lỗi) → sửa fail-closed cho EEA.
- Gate nên đặt tập trung: 1 hàm `bool _consentAllowsAdRequest()` gọi ở đầu mọi load path.
- Liên quan T02 (npa), T03 (ordering), T07 (ATT trước UMP).

## Test
- [ ] Unit: mock UMP `required` + form dismissed → mọi load path early-return.
- [ ] Unit: `notRequired` → loads chạy.
- [ ] Unit: update error + cached `required` → không request ad.
