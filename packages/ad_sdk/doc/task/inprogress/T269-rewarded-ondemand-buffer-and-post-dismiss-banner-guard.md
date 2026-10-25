# T269 — Tối Ưu Sẵn Sàng Video Trả Thưởng (On-Demand Buffer) & Khoảng Đệm Chống Chạm Nhầm Sau Đóng Ad (Post-Dismiss Banner Guard)

- **Loại:** Enhancement / Revenue Maximization & Policy Safety
- **Priority:** P1 · **Severity:** HIGH
- **Status:** implementation complete (2026-10-25; verified locally, not committed)

## Bối cảnh & Vấn đề

1. **Thất thoát doanh thu video trả thưởng (Rewarded Ad):**
   - Khi người dùng nhấn nút "Xem video nhận quà", nếu ad chưa kịp nạp xong (do mạng chậm, vừa mở app hoặc preload chưa hoàn tất), SDK hiện tại lập tức từ chối và trả về `onEarnedReward: false`.
   - Điều này làm mất trực tiếp lượt hiển thị có giá trị eCPM cao nhất, gây ức chế cho người dùng và giảm doanh thu của nhà phát hành.
   - Cơ chế nạp nóng (`_loadRewardedOnDemand`) vốn đã tồn tại trong SDK nhưng trước đây chỉ mở riêng cho người dùng VIP (`bypassVipGuard == true`).
2. **Nguy cơ vi phạm chính sách click nhầm (Invalid Traffic) khi tắt quảng cáo:**
   - Khi tắt quảng cáo toàn màn hình (bấm nút X), ngón tay người dùng dễ vô tình chạm trúng banner hoặc quảng cáo bên dưới trong 500ms đầu.
   - Google AdMob coi đây là hành vi click nhầm không hợp lệ và phạt trừ tiền doanh thu cuối tháng hoặc đình chỉ tài khoản.
   - Cần một khoảng đệm an toàn 750ms sau khi đóng ad toàn màn hình để giữ banner ở trạng thái placeholder, ngăn chặn hoàn toàn việc chạm nhầm vào PlatformView.

## Giải pháp triển khai

1. **On-demand Rewarded Ad Buffer:**
   - Thêm tham số tùy chọn `bool onDemandBuffer = false` vào `AdManager().showRewardedAd(...)`.
   - Nếu bật cờ này và slot chưa sẵn sàng, SDK hiển thị `AdLoadingDialog` và gọi `_loadRewardedOnDemand(ad, timeout: onDemandLoadTimeout)`. Nếu tải thành công trong thời gian chờ, ad được phát ngay lập tức.
2. **Post-Dismiss Banner Interaction Guard:**
   - Gọi `setInlineAdsHidden(true)` khi bất kỳ quảng cáo toàn màn hình nào bắt đầu hiển thị (`showAppOpenAd`, `showInterstitial`, `showRewardedAd`, `showRewardedInterstitialAd`).
   - Khi quảng cáo toàn màn hình đóng lại (sự kiện slot rời khỏi trạng thái `showing` trong `_attachFullscreenDismissWatchers`), giữ banner ẩn thêm một khoảng đệm an toàn `750ms` qua `Timer` trước khi gọi `setInlineAdsHidden(false)`.
   - Nếu quảng cáo hiển thị thất bại hoặc lỗi native: phục hồi banner ngay lập tức (0ms).
   - Dọn dẹp Timer trong `destroy()` và khi app vào background.

## Acceptance Criteria

- [x] `showRewardedAd` với `onDemandBuffer: true` hiển thị `AdLoadingDialog`, nạp on-demand khi slot chưa ready, và chỉ show khi load success; timeout/no-fill trả `earned: false`.
- [x] `onDemandBuffer` mặc định `false`; hành vi cũ được giữ nguyên khi không bật flag.
- [x] `AdManager.showRewardedAd` và `AdScreenState.showRewardedAd` đều hỗ trợ public flag; helper bỏ qua pre-check readiness chỉ khi flag true.
- [x] `showInterstitial`, `showRewardedAd`, `showRewardedInterstitialAd`, `showAppOpenAd` ẩn inline ads khi bắt đầu; dismissed ad giữ inline hidden 750ms rồi restore. Không phủ/khóa touch trên native PlatformView.
- [x] Adapter callback báo show-failure/exception phục hồi inline ads ngay; destroy và app pause hủy timer guard.
- [x] `dart analyze` các file SDK/example liên quan không có issue.
- [x] Public API golden `test/goldens/public_api_surface.txt` được regenerate và `test/api_golden_test.dart` pass.
- [x] Full SDK suite **2,792 tests pass**; 36 focused tests và regression suite liên quan pass.
- [x] TECNO KJ7 integration: cả `rewarded_ad_test.dart` và `interstitial_ad_test.dart` với AdMob test ads đều hoàn tất **2 show/dismiss cycles** và pass (đã verify arm guard `🛡️ dismissed — app-open/post-dismiss guard armed`).
- [x] Release gate `./tool/release_readiness_gate.sh all` pass; tracked `lib/` <= 2048 KB.
- [ ] Chưa push lên remote. Chưa đo uplift doanh thu, Invalid Traffic hoặc hiệu quả 750ms trên sản phẩm thật; kết quả là correctness/policy-safety verification, không phải cam kết doanh thu.
