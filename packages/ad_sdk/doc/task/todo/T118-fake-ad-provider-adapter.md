# T118 — Idea: FakeAdProviderAdapter — demo/CI-safe hoàn toàn offline

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `core/ad_provider_adapter.dart` (interface có sẵn), file mới `lib/src/adapters/fake_adapter.dart`

## Vấn đề

`AdProviderAdapter` đã là interface trừu tượng — implement thêm 1 adapter thứ 3 phát placeholder creative + event giả lập đúng shape `AdEvent` hiện có, không cần ad-unit ID thật, không gọi network. Giải đúng nhu cầu documented trong chính CI (`.github/workflows/test.yml` phải force `AD_PROVIDER_ADMOB` vì không có AppLovin key thật commit) và demo/App-Store-review build không được phép burn spend thật.

## Việc cần làm

- [ ] Implement `FakeAdProviderAdapter` (load/show trả kết quả giả lập có cấu hình được: thành công/thất bại/độ trễ)
- [ ] Wire vào example như 1 `AdProvider` option mới (không thay đổi provider mặc định)
- [ ] Test: dùng làm adapter test-double thay `_FakeAdapter` riêng lẻ trong nhiều test hiện có nếu tiện
