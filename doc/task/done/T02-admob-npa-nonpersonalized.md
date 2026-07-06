# T02 — Set `npa` (non-personalized) cho AdMob khi thiếu consent

- **REQ:** 6 (apply chuẩn AdMob)
- **Priority:** P0 · **Severity:** CRITICAL · **Status:** ✅ done (2026-07-05)
- **Files:** `core/ad_consent.dart`, `core/ad_provider_adapter.dart`, `adapters/admob_adapter.dart`, `adapters/applovin_adapter.dart`, `adapters/gma_bridge.dart`, `core/ad_manager.dart`

## Vấn đề (Why)
`applyConsentToProviders` cho AdMob **chỉ** set `tagForChildDirectedTreatment` + `tagForUnderAgeOfConsent`, **không hề** truyền `npa=1`. Grep xác nhận `npa` chỉ có trong **comment** `ad_consent.dart:15` ("forwards ... AdMob `npa` extra") — code không làm. Hệ quả: user "Reject" → **AdMob vẫn phục vụ personalized ads** → sai cam kết consent, rủi ro policy ở vùng ngoài phạm vi UMP (vd CCPA opt-out).

## Acceptance criteria
- [x] Khi `AdConsent.hasUserConsent == false`, mọi `AdRequest` của AdMob dùng `AdRequest(nonPersonalizedAds: true)` (npa=1). _(dùng field `nonPersonalizedAds` của `google_mobile_ads` 7.x thay cho extra thô — chuẩn hơn.)_
- [x] Khi có consent → `nonPersonalizedAds: false` (personalized bình thường).
- [x] Áp dụng đồng nhất cho banner/interstitial/rewarded/app-open (banner qua `admob_adapter`, 3 fullscreen qua `gma_bridge`).
- [x] Adapter đồng bộ consent qua `applyConsent()`; `AdManager` gọi tại init, `setConsent`, và listener `ConsentManager` (bao phủ auto dialog / set / reset / privacy screen). Default conservative (npa=true) + reset khi dispose.
- [x] Comment `ad_consent.dart` cập nhật cho khớp: npa là per-request ở `AdMobAdapter.applyConsent`.

## Kết quả
- Unit: `test/admob_behavioral_test.dart` (group "Non-personalized (npa) consent propagation", 6 case).
- Integration: `test/npa_consent_wiring_test.dart` (setConsent → adapter, 5 case) + buffer-before-init.
- Widget: cùng file, tap Accept/Reject → adapter nhận đúng consent.
- App sample: `example/lib/main.dart` Consent page có indicator "personalized vs NON-personalized (npa=1)" live.
- **237/237 test SDK xanh**, `flutter analyze` sạch (SDK + example). CHANGELOG cập nhật (Unreleased).

## Lưu ý phát hành
Host app đang dùng `applovin_admob_sdk: ^1.0.23` **hosted từ pub.dev**, chưa thấy thay đổi local này. Để host nhận fix: bật `path: packages/ad_sdk` override (hoặc publish version mới) theo hướng dẫn trong CLAUDE.md.

## Ghi chú kỹ thuật
- `AdRequest(nonPersonalizedAds: true)` hoặc `extras: {'npa':'1'}` (theo `google_mobile_ads` version đang dùng — kiểm tra API).
- UMP-managed users: AdMob tự xử lý personalization qua TCF string → tránh double-restrict; chỉ set npa cho path non-UMP.

## Test
- [ ] Unit/adapter: consent=false → request có npa; consent=true → không có.
