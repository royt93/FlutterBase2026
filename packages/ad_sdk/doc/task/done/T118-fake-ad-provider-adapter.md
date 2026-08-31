# T118 — Idea: FakeAdProviderAdapter — demo/CI-safe hoàn toàn offline

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `core/ad_provider_adapter.dart` (interface có sẵn), file mới `lib/src/adapters/fake_adapter.dart`

## Vấn đề

`AdProviderAdapter` đã là interface trừu tượng — implement thêm 1 adapter thứ 3 phát placeholder creative + event giả lập đúng shape `AdEvent` hiện có, không cần ad-unit ID thật, không gọi network. Giải đúng nhu cầu documented trong chính CI (`.github/workflows/test.yml` phải force `AD_PROVIDER_ADMOB` vì không có AppLovin key thật commit) và demo/App-Store-review build không được phép burn spend thật.

## Việc đã làm

- [x] `FakeAdProviderAdapter` (lib/src/adapters/fake_adapter.dart, export công khai) — implement đủ toàn bộ interface `AdProviderAdapter` (~40 member). `shouldSucceed`/`loadDelay` cấu hình được. Mọi format (appOpen/interstitial/rewarded/rewardedInterstitial/banner/mrec/native) dùng chung 1 `AdSlot` state machine thật (`beginLoad`/`markReady`/`markFailed`/`beginShow`/`markDisplayed`/`markDismissed`) — không tự chế state machine riêng.
- [x] Render 1 placeholder widget rõ ràng là giả (`_FakePlaceholderAd`, nền xám + label) cho banner/mrec/native — không silent-null như AppLovin's admob-view stub.
- [x] Test: `test/fake_adapter_test.dart` (13 test) — init, load/show cả 4 định dạng fullscreen, đường thất bại (`shouldSucceed: false`), show không qua load trước không throw, banner/mrec/native load+dispose, 2 key banner độc lập, dispose() không leak/throw.
- [ ] KHÔNG wire vào example như 1 `AdProvider` option mới — đây là thay đổi lớn hơn (cần API công khai chọn adapter, hiện chỉ có `AdManager.debugAdapterFactory` — `@visibleForTesting`, không định dùng production). Để ticket riêng nếu thật sự cần adapter này chọn được từ UI/production build.
- [ ] KHÔNG thay `_FakeAdapter` riêng lẻ trong các test hiện có bằng adapter này — mỗi test hiện tại tự tay implement fake tối giản đúng nhu cầu riêng (nhiều test chỉ cần 1-2 method); đổi hàng loạt rủi ro cao hơn giá trị, không nằm trong 1 lượt an toàn.

Test cuối: 1396 pass (từ baseline 1383 + 13 test mới), `flutter analyze` sạch.
