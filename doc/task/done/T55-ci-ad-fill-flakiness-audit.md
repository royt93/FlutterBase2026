# T55 — CI "xanh" không chắc show/dismiss cycle đã chạy thật nếu ad không kịp fill

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding N6
- **Priority:** P3 (Low) · **Status:** ✅ done — verified, không cần fix code (2026-07-20)
- **Files:** (chỉ đọc) `packages/ad_sdk/example/integration_test/{interstitial,app_open}_ad_test.dart`, `packages/ad_sdk/lib/src/adapters/{admob,applovin}_adapter.dart`

## Vấn đề (Why)
Một số integration test dùng pattern `if (loaded) { ...show/dismiss... }` — nếu ad network không kịp fill trong CI, nhánh show/dismiss bị skip êm, test vẫn "pass" mà không chứng minh gì.

## Kết luận
Audit gốc tự nhận định "giới hạn môi trường CI đã biết, không phải bug", Low, không cần fix. Xác nhận đúng: SDK đã có sẵn test seam `debugSimulate*` (`@visibleForTesting`, cả `AdMobAdapter` và `AppLovinAdapter` cho interstitial/rewarded; chỉ `AdMobAdapter` có bản app-open) — đủ để làm CI deterministic nếu sau này cần, nhưng wire vào ngay bây giờ là over-engineering so với severity của finding, và đóng gap hoàn toàn cho app-open trên AppLovin (provider mặc định của example) đòi hỏi viết code production mới chưa tồn tại.

Phát hiện phụ: `interstitial_ad_test.dart` đã tự hardening thành `expect(isTrue)` (hard assertion) độc lập từ sau round 8 — rủi ro đổi từ "false-green" sang "có thể flake khi ad chậm fill", không cần hành động thêm.

## Acceptance criteria
- [x] Xác nhận test seam `debugSimulate*` tồn tại và hoạt động đúng behavior.
- [x] Quyết định rõ ràng: fix code hay giữ nguyên, có lý do.

## Đã verify (2026-07-20)
Không sửa code. Xem `doc/audit/audit_claude.md` round 9.
