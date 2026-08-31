# T120 — Idea: Bộ mô phỏng ma trận consent (simulateConsentOutcome)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/core/ad_consent.dart`, `lib/src/consent/consent_manager.dart`

## Vấn đề

Một hàm thuần `simulateConsentOutcome(AdConsent hypothetical)` chạy qua đúng logic `applyConsentToProviders`/`ad_consent.dart` NHƯNG không gọi platform channel thật — trả về AdMob sẽ nhận `npa=?`, AppLovin sẽ nhận `hasUserConsent=?`/COPPA=? cho từng tổ hợp GDPR/ATT/COPPA giả định. Giúp QA compliance kiểm tra trước khi build thật lên thiết bị — đúng điểm round-26 finding #5 từng vật lộn.

## Việc cần làm

- [ ] Bọc logic mapping hiện có (`applyConsentToProviders`) thành pure function không side-effect, trả về struct mô tả thay vì gọi platform channel
- [ ] Test: mọi tổ hợp GDPR/ATT/COPPA cho kết quả khớp với logic thật (so sánh với `applyConsentToProviders` chạy trong test env)
