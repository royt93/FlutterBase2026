# T156 — Hàm tiện lợi chặn cứng VIP xem thêm quảng cáo tự nguyện

**Loại:** enhancement (bug ẩn trong hàm tiện lợi)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** agy, tự verify plausible qua code thật
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Khi 1 người đã trả tiền VIP (không bị quảng cáo làm phiền) muốn TỰ NGUYỆN xem thêm 1 quảng cáo có thưởng để nhận quà thưởng thêm — SDK đã hỗ trợ đúng tính năng này ở tầng thấp (`showRewardedAd(bypassVipGuard: true)`, xem CLAUDE.md mục VIP entitlement). Nhưng nếu dev dùng đúng hàm tiện lợi có sẵn (`AdScreenState.showRewardedAd`, thay vì tự viết thủ công), tham số này bị chặn cứng, không có cách bật — người VIP muốn xem thêm để lấy quà sẽ không làm được dù họ muốn.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_screen.dart:158-192` — `AdScreenState.showRewardedAd` không chuyển tiếp tham số `bypassVipGuard` xuống `AdManager().showRewardedAd(...)` thật.

## Việc cần làm
1. Thêm tham số `bypassVipGuard` (mặc định `false`, không breaking) vào `AdScreenState.showRewardedAd`, forward đúng xuống `AdManager().showRewardedAd(...)`.
2. Grep các hàm helper show* khác trong `ad_screen.dart` xem có thiếu tham số quan trọng nào tương tự không (đối chiếu toàn bộ tham số của `AdManager().showRewardedAd`).
3. Thêm demo trong `example/`: màn hình VIP có nút "xem quảng cáo thưởng thêm" dùng qua `AdScreenState.showRewardedAd(bypassVipGuard: true)`.
4. Cập nhật CHANGELOG.md và README.md (mục VIP entitlement, nhắc dùng qua `AdScreenState` cũng hoạt động).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_screen.dart dòng ~158-192: AdScreenState.showRewardedAd không forward tham số bypassVipGuard xuống AdManager().showRewardedAd() thật (tham số này đã tồn tại ở tầng AdManager, dùng cho case VIP tự nguyện xem thêm quảng cáo thưởng — xem CLAUDE.md mục VIP entitlement). Thêm tham số bypassVipGuard (default false) vào AdScreenState.showRewardedAd, forward đúng xuống. Đối chiếu toàn bộ tham số khác của AdManager().showRewardedAd để chắc không thiếu thêm tham số nào khác trong helper này. Viết widget test: gọi AdScreenState.showRewardedAd(bypassVipGuard: true) trong lúc VIP đang active, xác nhận rewarded ad thật sự được gọi show (không bị chặn bởi VIP guard). Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho `bypassVipGuard: true/false` qua `AdScreenState.showRewardedAd` trong lúc VIP active.
3. Demo trong `example/` + CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, kích hoạt VIP, bấm nút xem thêm quảng cáo thưởng trong demo, xác nhận hiện quảng cáo thật.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
