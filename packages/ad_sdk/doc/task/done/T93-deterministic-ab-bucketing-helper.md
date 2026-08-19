# T93 — Ý tưởng: Deterministic A/B bucketing helper dùng install-id sẵn có

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart`

## Ý tưởng
`AdManager().experimentBucket(key, buckets: n)` tận dụng GAID/install-id đã có sẵn trong SDK, giúp host A/B test tham số `AdSafetyParams`/arbitrator threshold mà không cần tích hợp thêm dependency remote-config riêng (nhẹ hơn T88, không cần backend).

## Việc cần làm (đề xuất, chưa code)
- [x] Hàm hash deterministic (install-id + key) → bucket index, ổn định qua nhiều lần gọi cùng install.

## Đã làm (2026-08-16)

**Phát hiện khi thiết kế (không chỉ implement máy móc):** dùng GAID đơn thuần làm install-id có 1 lỗ hổng thật — user tắt "cho phép theo dõi quảng cáo" (Limit Ad Tracking/không cấp quyền ATT) sẽ có GAID rỗng hoặc toàn số 0 (`00000000-0000-0000-0000-000000000000`), khiến TOÀN BỘ user đã opt-out rơi vào ĐÚNG 1 bucket — làm lệch kết quả A/B test cho 1 phần không nhỏ user thật. Sửa root cause: thêm fallback install-id giả danh (pseudonymous), sinh ngẫu nhiên 128-bit (`dart:math` `Random.secure()`, không thêm dependency `uuid`), persist qua `AdPreferences` — chỉ dùng khi GAID rỗng/toàn-0.

**Thiết kế:**
- `lib/src/utils/experiment_bucket.dart` — hàm thuần `experimentBucket(installId, key, {buckets})`, dùng lại đúng thuật toán FNV-1a 32-bit đã có sẵn trong `AdPreferences._fnv1a` (không tạo dependency mới, nhất quán với pattern đã dùng cho VIP checksum).
- `AdPreferences.getOrCreateExperimentInstallId()` — getter có side-effect ghi đĩa lần đầu (fire-and-forget), đúng pattern đã chấp nhận từ T69 (`VipManager.expiresAt`).
- `AdManager().experimentBucket(key, {required buckets})` — ưu tiên GAID thật nếu có và khác rỗng/toàn-0, fallback install-id giả danh.
- `key` tham gia vào hash (không chỉ installId) — để 1 install có thể rơi bucket khác nhau giữa các experiment độc lập, tránh mọi kết quả A/B tương quan hoàn toàn với nhau.

TDD: `experiment_bucket_test.dart` (5 test hàm thuần — ổn định, trong range, phân bố tốt qua nhiều installId/key, throw khi buckets<=0). `ad_preferences_test.dart` (3 test — ổn định qua gọi lại, sống sót qua "restart app" giả lập, 2 install khác nhau ra 2 id khác nhau). `ad_manager_core_test.dart` (5 test — ổn định, ưu tiên GAID, fallback install-id khi GAID rỗng/toàn-0 cho ra phân bố thật (không phải hardcode 1 bucket), throw khi buckets<=0). Thêm debug seam `debugCurrentDeviceGAID` (GAID thật fetch qua platform channel không khả dụng dưới `flutter test`).

README + CHANGELOG cập nhật.

`flutter test`: 784/784 pass (2 lần), `flutter analyze` sạch.
