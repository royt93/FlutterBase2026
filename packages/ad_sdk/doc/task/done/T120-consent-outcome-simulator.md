# T120 — Idea: Bộ mô phỏng ma trận consent (simulateConsentOutcome)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/core/ad_consent.dart`, `lib/applovin_admob_sdk.dart`, `test/ad_consent_test.dart`

## Vấn đề

Một hàm thuần `simulateConsentOutcome(AdConsent hypothetical)` chạy qua đúng logic `applyConsentToProviders`/`ad_consent.dart` NHƯNG không gọi platform channel thật — trả về AdMob sẽ nhận `npa=?`, AppLovin sẽ nhận `hasUserConsent=?`/COPPA=? cho từng tổ hợp GDPR/ATT/COPPA giả định. Giúp QA compliance kiểm tra trước khi build thật lên thiết bị — đúng điểm round-26 finding #5 từng vật lộn.

## Việc cần làm

- [x] Trích logic mapping của `applyConsentToProviders` thành 1 hàm pure `_decideConsentOutcome(consent, config)` trả về `ConsentSimulationResult` — CẢ `applyConsentToProviders` (đường thật) LẪN `simulateConsentOutcome` (mới) cùng gọi đúng 1 hàm này, nên không thể lệch pha theo thời gian (single source of truth, không phải 2 bản logic song song dễ trôi dạt). Export public (`lib/applovin_admob_sdk.dart`) — đây là API dành cho host/QA, không phải nội bộ SDK.
- [x] Test (`test/ad_consent_test.dart`, group "T120"): quét toàn bộ 16 tổ hợp GDPR×CCPA×COPPA×`umpTagForUnderAgeOfConsent`, xác nhận `simulateConsentOutcome` khớp đúng mapping đã document VÀ không gọi platform channel nào; 1 test riêng xác nhận `applyConsentToProviders` (đường thật) gửi cho AppLovin đúng giá trị mà simulation dự đoán. Không decode message AdMob thô qua `AdMessageCodec` (rủi ro đoán sai wire-format enum của plugin bên thứ 3, không phải logic của SDK này) — sự nhất quán AdMob được đảm bảo bằng kiến trúc single-source-of-truth ở trên, không phải test tích hợp giòn.
