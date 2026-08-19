# T05 — Tách & sửa map cờ CCPA (RDP) vs COPPA (TFCD)

- **REQ:** 6 (apply chuẩn)
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** done
- **Files:** `core/ad_consent.dart`, `adapters/gma_bridge.dart`, `adapters/admob_adapter.dart`, `consent/consent_settings.dart`
- **Tests:** `test/admob_behavioral_test.dart` — group `Restricted-data-processing (RDP/CCPA) consent propagation` (7 cases)

## Vấn đề (Why)
`ad_consent.dart:82` map `doNotSell` (CCPA California) → `tagForUnderAgeOfConsent` (TFUA, về tuổi). Hai khái niệm **trực giao**. CCPA của AdMob xử lý bằng Restricted Data Processing (RDP), không phải TFUA. Việc gộp làm sai cả hai semantics.

## Acceptance criteria
- [x] `isAgeRestrictedUser` (COPPA, app-level) và `doNotSell` (CCPA, user-level) là 2 tín hiệu độc lập, không chồng lấn — verified bằng test `hasUserConsent/isAgeRestrictedUser alone do not trigger RDP` và `doNotSell alone does not enable personalization`.
- [x] COPPA → `tagForChildDirectedTreatment` (đã đúng, giữ). TFUA chỉ dùng cho "under age consent" thật (EEA <16), không dùng cho CCPA — `ad_consent.dart` để `tagForUnderAgeOfConsent` unset, có comment giải thích rõ.
- [x] CCPA opt-out → áp cơ chế RDP đúng của AdMob (extra `AdRequest.extras: {'rdp': '1'}` qua `GmaBridge._extrasFor`/`_rdpExtras`, forward trên cả App Open/Interstitial/Rewarded + Banner), không map vào TFUA.
- [x] `ConsentSettings` phản ánh 2 trục riêng; `toAdConsent()` ánh xạ đúng (1:1, không lai ghép).

## Ghi chú kỹ thuật
- AdMob RDP forward qua `AdRequest.extras` (Google's documented mechanism) vì `RequestConfiguration` không có field RDP riêng.
- `AdMobAdapter._restrictedDataProcessing` set trong `applyConsent()` từ `consent.doNotSell`, reset về `false` khi dispose/teardown (an toàn khi re-init trước khi có consent).
- `flutter analyze` clean trên toàn bộ 4 file liên quan. `flutter test test/admob_behavioral_test.dart` — 21/21 pass, không regression.
