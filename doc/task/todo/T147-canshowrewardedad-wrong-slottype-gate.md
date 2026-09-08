# T147 — Nút xem quảng cáo có thưởng kiểm tra nhầm loại

**Loại:** bug
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state, tự verify trực tiếp code (copy-paste sai từ hàm bên cạnh)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Có 3 loại quảng cáo có thưởng gần giống nhau (rewarded thường + rewarded-interstitial). Có 1 công tắc từ xa (remote kill-switch T137) để tắt riêng từng loại khi có sự cố. Do copy nhầm code, hàm kiểm tra "có nên hiện nút xem rewarded thường không" lại đi kiểm tra công tắc của loại rewarded-interstitial — nên bật/tắt có thể ngược. Hậu quả: nút bấm cho người dùng xem có thể hiện ra nhưng bấm không chiếu được, hoặc ngược lại (nút bị ẩn dù thực ra vẫn xem được).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_manager.dart:7746-7747` — `canShowRewardedAd()` gọi `AdSafetyConfig.canShowFullscreenAdPeek(forType: AdSlotType.rewardedInterstitial)` — sai, phải là `AdSlotType.rewarded`.
- Đối chiếu: `showRewardedAd()` thật (dòng 7288) dùng đúng `AdSlotType.rewarded` để gate — nghĩa là hàm "peek" (chỉ xem trước, không tiêu side-effect) và hàm "show" thật (có side-effect) đang không đồng bộ loại kiểm tra.
- Đúng loại lỗi mà comment "m18" trong cùng file từng cố ý ngăn.

## Việc cần làm
1. Sửa dòng 7746-7747: đổi `AdSlotType.rewardedInterstitial` thành `AdSlotType.rewarded`.
2. Grep toàn file tìm các cặp `canShow*Peek`/`show*` tương tự khác để đảm bảo không còn cặp nào bị lệch loại (kiểm tra `canShowRewardedInterstitialAd()` dùng đúng `rewardedInterstitial`, không bị lây lỗi ngược).
3. Thêm log SafeLogger khi remote kill-switch của 1 loại rewarded được đọc (ghi rõ loại nào, giá trị gì) để dễ debug sau này.
4. Thêm demo trong `example/`: 1 nút bật/tắt remote kill-switch riêng cho rewarded và rewarded-interstitial, cho thấy `canShowRewardedAd()`/nút bấm phản ứng đúng theo đúng loại.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa bug trong packages/ad_sdk/lib/src/core/ad_manager.dart dòng ~7746-7747: canShowRewardedAd() đang gọi AdSafetyConfig.canShowFullscreenAdPeek(forType: AdSlotType.rewardedInterstitial) — sai, phải dùng AdSlotType.rewarded (đối chiếu showRewardedAd() thật ở dòng ~7288 dùng đúng AdSlotType.rewarded). Sau khi sửa, grep toàn ad_manager.dart tìm mọi cặp canShow*Peek/show* khác để chắc chắn không còn cặp nào bị lệch loại slot tương tự. Viết unit test: remote kill-switch tắt rewardedInterstitial thì canShowRewardedAd() (loại rewarded thường) phải vẫn trả true; tắt rewarded thì canShowRewardedAd() phải trả false và showRewardedAd() thật cũng phải chặn tương ứng — test cả 2 chiều để không sửa ngược lại. Thêm log SafeLogger. Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cả 2 chiều (tắt rewarded / tắt rewardedInterstitial) cho `canShowRewardedAd`/`canShowRewardedInterstitialAd` lẫn `showRewardedAd`/`showRewardedInterstitialAd` thật; widget test cho nút bấm phản ứng đúng theo trạng thái kill-switch.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập (`codex exec --dangerously-bypass-approvals-and-sandbox` / `agy --dangerously-skip-permissions --print` / `claude --dangerously-skip-permissions -p` hoặc tự audit adversarial) — chấm điểm /10.
6. ≤9/10: liệt kê finding, sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, bật/tắt remote kill-switch qua `RemoteSafetyDemoPage`, chụp bằng chứng nút bấm đúng loại.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
