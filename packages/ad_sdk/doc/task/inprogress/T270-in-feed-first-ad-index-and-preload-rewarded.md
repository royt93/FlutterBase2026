# T270 & T271 — InFeedAdListView firstAdIndex & AdScreenState preloadRewardedOnMount

- **Loại:** Enhancement / Revenue Maximization
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** in progress (2026-10-25)

## Bối cảnh & Vấn đề

1. **T270 — Hiển thị Native Ad sớm hơn trong feed (firstAdIndex):**
   - Trước đây `InFeedAdListView` và `InFeedIndexCalculator` chỉ hỗ trợ `adInterval` cố định (mặc định 10). Mọi quảng cáo đều xuất hiện sau mỗi N item (ví dụ item 10, 21, 32...).
   - Trong thực tế, nhiều ứng dụng muốn người dùng nhìn thấy quảng cáo Native đầu tiên sớm hơn (ví dụ sau 3-4 item nội dung) để tối ưu tỷ lệ viewability và doanh thu ngay trong màn hình đầu tiên, trong khi các quảng cáo tiếp theo vẫn giữ khoảng cách giãn đều (ví dụ 8-10 item).
   - Giải pháp: Thêm tham số tùy chọn `firstAdIndex` vào `InFeedAdListView` và `InFeedIndexCalculator`. Mặc định giữ nguyên `adInterval` để tương thích 100% mã nguồn hiện tại.

2. **T271 — Preload Rewarded Ad khi mount màn hình (preloadRewardedOnMount):**
   - Hiện tại `AdScreenState.initState()` tự động preload `loadInterstitial()` nhưng không nạp trước video trả thưởng (`Rewarded Ad`).
   - Với các màn hình chuyên nhận thưởng (Shop, Gift, Daily Rewards, Lucky Spin), người dùng vào màn hình với mục đích chính là xem video nhận quà. Nếu không nạp trước, khi người dùng bấm nút nhận quà, ad chưa sẵn sàng sẽ phải nạp nóng hoặc báo chưa sẵn sàng.
   - Giải pháp: Thêm getter `bool get preloadRewardedOnMount => false;` trong `AdScreenState` và gọi `AdManager().loadRewardedAd()` khi getter trả về `true`. Thêm helper `loadRewardedAd()` trong `AdScreenState`.

## Acceptance Criteria

- [x] `InFeedIndexCalculator` hỗ trợ `firstAdIndex` tùy chọn trên cả 4 phương thức (`isAdPosition`, `toOriginalItemIndex`, `toAdIndex`, `totalCount`).
- [x] Khi `firstAdIndex == null`, hành vi và kết quả tính toán giống 100% phiên bản trước.
- [x] Khi `firstAdIndex` được truyền (ví dụ `firstAdIndex: 4, adInterval: 10`), ad đầu tiên ở raw index 4 (sau 4 content item), các ad tiếp theo ở raw index 15, 26...
- [x] `InFeedAdListView.builder` hỗ trợ tham số `firstAdIndex`.
- [x] `AdScreenState` có getter `bool get preloadRewardedOnMount => false;` và gọi `AdManager().loadRewardedAd()` trong `initState()` khi `preloadRewardedOnMount == true`.
- [x] `AdScreenState` có helper `void loadRewardedAd()`.
- [x] Unit & widget tests cho cả 2 tính năng đạt độ phủ đầy đủ (thêm trong `in_feed_ad_list_view_test.dart` và `ad_screen_test.dart`).
- [x] `flutter analyze` sạch 0 issue trên cả package và example.
- [x] `test/goldens/public_api_surface.txt` được regenerate và `api_golden_test.dart` pass.
- [x] Full SDK test suite **2,797 tests pass**; example suite 71 tests pass.
- [x] Release gate `./tool/release_readiness_gate.sh all` pass; dung lượng `lib/` giữ đúng 2048 KB.

