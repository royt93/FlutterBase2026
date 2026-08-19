# T88 — Ý tưởng: Remote Config adapter cho `AdSafetyParams` + dynamic ad unit ID

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** ✅ done (MVP: AdSafetyParams override; ad unit ID deferred)
- **Files:** `packages/ad_sdk/lib/src/config/ad_safety_config.dart`, `packages/ad_sdk/lib/src/config/ad_config.dart`

## Ý tưởng
Tham số an toàn (tần suất, giới hạn ngày/giờ) và Ad Unit ID hiện cứng trong code client. Cung cấp interface cắm Remote Config (Firebase Remote Config hoặc custom API tự host) giúp publisher điều chỉnh chiến lược kiếm tiền từ xa mà không cần submit bản cập nhật App Store/Google Play.

## Việc cần làm (đề xuất, chưa code)
- [x] Thiết kế interface abstract (không ép buộc Firebase cụ thể) cho `AdSafetyParams`/ad unit ID provider.
- [x] SDK tự áp dụng giá trị mới khi provider trả về, có validate + fallback về giá trị local nếu remote lỗi/không có mạng.

## Đã làm (2026-08-16) — MVP, scope thu hẹp có chủ đích

**Scope quyết định:** chỉ làm remote override cho `AdSafetyParams` (tần suất/giới hạn) — ĐÂY LÀ PHẦN GIÁ TRỊ CAO, RỦI RO THẤP. **Cố tình bỏ ad unit ID remote override** khỏi MVP này: ad unit ID gắn liền với mediation config phía AdMob/AppLovin dashboard, đổi remote không đồng bộ với dashboard dễ gây mismatch (ví dụ ad unit ID trỏ sai format/placement), rủi ro cao hơn nhiều so với lợi ích, và ticket gốc tự nhận "ý tưởng, chưa thiết kế chi tiết" — không nên cùng lúc thiết kế 2 thứ khác bản chất trong 1 lần.

**Thiết kế:**
- `abstract class RemoteAdSafetyProvider` (file mới `lib/src/config/remote_ad_safety_provider.dart`) — 1 method `Future<Map<String, dynamic>?> fetchSafetyParamOverrides()`, không phụ thuộc Firebase hay bất kỳ package remote-config cụ thể nào (đúng yêu cầu "không ép buộc Firebase cụ thể").
- `applyRemoteSafetyOverrides(local, overrides)` — merge có validate riêng từng field: int phải `>= 0`, `suspiciousCtrThreshold` phải trong `[0, 1]`, `dryRun` phải đúng kiểu `bool`. Field thiếu/sai kiểu/ngoài range → giữ nguyên giá trị local, KHÔNG throw, KHÔNG áp dụng 1 phần sai.
- `AdManager().initialize(..., remoteSafetyProvider: ...)` — gọi provider với timeout 5s (`Future.timeout`), bọc `try/catch` toàn phần — provider chậm/throw/trả `null` đều fallback về `config.safety` gốc, không bao giờ chặn init.

TDD: `remote_ad_safety_provider_test.dart` (7 test) cho logic merge/validate thuần; `ad_manager_core_test.dart` nhóm `remoteSafetyProvider (T88)` (3 test, dùng `fakeAsync` cho case timeout) xác nhận override thật sự áp dụng vào `AdSafetyConfig`, và cả throw/timeout đều fallback đúng, không crash init.

README: thêm section "Remote-controlled AdSafetyParams" với ví dụ Firebase Remote Config thật. CHANGELOG `[Unreleased]` ghi rõ tính năng mới + lý do bỏ ad-unit-ID khỏi scope.

`flutter test`: 760/760 pass (2 lần), `flutter analyze` sạch.
