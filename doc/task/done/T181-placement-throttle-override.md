# T181 — Cho phép cài "khoảng cách tối thiểu giữa 2 lần" riêng theo từng vị trí quảng cáo

**Loại:** new-feature
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config
**Quyết định chủ dự án (2026-09-08):** Làm luôn

## Vấn đề (giải thích thực tế)
Hiện mỗi vị trí quảng cáo chỉ cài được giới hạn "số lần/ngày" riêng (`PlacementSpec.frequencyCapOverride`). Ý tưởng mới: cho phép cài thêm "khoảng cách tối thiểu giữa 2 lần" (throttle/min-interval) riêng cho từng vị trí (hiện chỉ cài được chung cho cả app qua `AdConfig`).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/config/placement_registry.dart:7-32` (`PlacementSpec`) — hiện chỉ hỗ trợ `frequencyCapOverride`.
- Cần đối chiếu cơ chế throttle chung hiện có (30s throttle nhắc trong CLAUDE.md mục "Built-in safety layer") để biết đúng chỗ áp dụng override.

## Việc cần làm
1. Thêm field mới vào `PlacementSpec` (VD `minIntervalOverride`), tương tự cách `frequencyCapOverride` đã làm.
2. Sửa điểm kiểm tra throttle chung trong `ad_safety_config.dart`/`ad_manager.dart` để ưu tiên override riêng theo placement nếu có, fallback về giá trị chung của app nếu không.
3. Viết test cho: placement có override riêng (throttle chặt/lỏng hơn app-wide), placement không override (dùng giá trị chung).
4. Thêm demo trong `example/`: 1 placement cài throttle riêng ngắn hơn app-wide, chứng minh áp dụng đúng.
5. Cập nhật CHANGELOG.md và README.md (mục cấu hình placement).

## Prompt để chạy loop-fix
```
Thêm field mới vào PlacementSpec (packages/ad_sdk/lib/src/config/placement_registry.dart dòng ~7-32), VD minIntervalOverride (Duration?, nullable), theo đúng pattern frequencyCapOverride đã có (đọc kỹ cách đó implement + áp dụng ở đâu). Tìm điểm kiểm tra throttle chung hiện có (30s throttle, xem CLAUDE.md mục built-in safety layer để biết vị trí đúng trong ad_safety_config.dart/ad_manager.dart), sửa để ưu tiên minIntervalOverride của placement nếu có, fallback về giá trị throttle chung app-wide nếu không. Viết test: placement có override (throttle khác app-wide) và placement không override (dùng chung). Thêm demo trong example/. Cập nhật README.md.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả 2 case (có/không override); test không breaking cho placement không cấu hình gì thêm.
3. Demo trong `example/` + CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, cấu hình 1 placement throttle riêng, xác nhận áp dụng đúng khác với các placement khác.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-13)

Thêm `PlacementSpec.minIntervalOverrideMs` (int?, ms) — override
`AdSafetyParams.minTimeBetweenFullscreenAds` (throttle chung "khoảng cách
tối thiểu giữa 2 quảng cáo toàn màn hình") riêng theo từng placement, cùng
pattern với `frequencyCapOverride` đã có. Nối vào cả 4 điểm show thật
(interstitial/rewarded/rewardedInterstitial/appOpen), 3 hàm pre-check
UI (`canShowInterstitial`/`canShowRewardedAd`/
`canShowRewardedInterstitialAd` — nay có thêm tham số `placement`, mặc
định `AdPlacement.unspecified` để không phá caller cũ), và luồng App Open
tự động khi resume app (khớp `AdPlacement.splash` — placement mặc định
của `showAppOpenAd`).

**7 vòng `codex review --uncommitted`** (đã hết quota 2 lần giữa chừng,
đợi reset rồi chạy tiếp — vòng 7 bị skip theo yêu cầu người dùng vì hàng
đợi quá dài, xử lý dựa trên tự audit + test thật):
- Vòng 1: 2 luồng UI pre-check (`canShowInterstitial` v.v.) và App Open
  resume flow chưa nhận override — chỉ hàm show thật mới có. Đã thêm
  tham số `placement`/override cho cả 2.
- Vòng 2: `AdScreenState` (`ad_screen.dart`) — wrapper
  `showInterstitialAd`/`showRewardedAd`/`showRewardedInterstitialAd` gọi
  pre-check KHÔNG kèm placement, nên override vẫn không áp dụng qua
  pattern widget chính thức của SDK. Đã sửa cả 3.
- Vòng 3: sạch.
- Vòng 4: demo trong `example/` lỗi — dùng lại đúng chuỗi ad fullscreen
  (single-use, cần reload) nên tap 2 lần nhanh không chứng minh được gì;
  thiếu tài liệu README/CHANGELOG cho field mới. Đã viết lại demo +
  cập nhật README/CHANGELOG.
- Vòng 5: demo VẪN sai — gọi `AdSafetyConfig.recordFullscreenAdShown()`
  giả (không có ad thật) làm bẩn số đếm PRODUCTION thật (daily/session/
  hourly cap, risk score) — bấm demo 5 lần có thể chặn hết quảng cáo thật
  trong ngày ở bản release; demo cũng hardcode literal `500` thay vì đọc
  giá trị đăng ký thật, không kiểm chứng đúng luồng `AdManager`/registry.
  Đã viết lại demo: dùng `AdManager().showInterstitial()` thật (side
  effect ghi nhận là thật, không giả), và `AdManager().canShowInterstitial
  (placement:)` thật (không gọi thẳng `AdSafetyConfig`).
- Vòng 6: giá trị `minIntervalOverrideMs` âm khiến `elapsed < minInterval`
  luôn sai (elapsed không bao giờ âm) — vô tình TẮT HẲN throttle cho
  placement đó dù giá trị app-wide vẫn hợp lệ. Sửa: giá trị âm bị TỪ CHỐI
  (không phải floor về 0) — fallback về giá trị app-wide, giống hệt như
  không truyền override. `0` vẫn là giá trị hợp lệ, có chủ đích ("tắt hẳn
  throttle cho placement này").

Trong lúc sửa vòng 6, tự phát hiện 2 test mới của mình fragile theo thứ
tự chạy (`_lastFullscreenAdTime`/`_isColdStart` không bị `resetSession()`
reset, rò rỉ giữa các test) — sửa bằng cách truyền
`minIntervalOverrideMs: 0` riêng cho bước "consume cold start" để không
phụ thuộc trạng thái để lại từ test trước.

Xác minh mỗi fix không vô nghĩa: tạm bỏ guard thật (`_require...`/`.clamp`/
logic reject-âm) và xác nhận test tương ứng fail đúng như kỳ vọng, rồi
khôi phục — lặp lại cho từng vòng sửa.

Xác minh cuối: `flutter analyze` sạch; SDK suite 1991 test xanh; example
suite 47 file xanh; device smoke thật trên **TECNO BG6**
(`118743744X002560` — S24 Ultra không còn kết nối lúc này) qua
`example/integration_test/t181_placement_throttle_override_test.dart`,
dùng AdMob test ad unit ID thật, `AdManager().initialize()` thật (không
qua debug seam), chờ interstitial load xong thật rồi mới kiểm tra —
`canShowInterstitial(placement: t181_loose)` đúng `true` dù throttle
app-wide đặt cực lớn, `canShowInterstitial()` (placement mặc định) đúng
`false` — pass.

Điểm tự chấm: **9.3/10**. Trừ điểm vì vòng 7 codex bị skip (hết quota,
người dùng yêu cầu bỏ qua) — bù lại bằng tự-audit kỹ + 6 vòng codex trước
đó đã bắt hầu hết vấn đề thật (2 vòng là bug production thật: thiếu
forward placement qua UI pre-check/AdScreenState, và giá trị âm tắt
throttle).
