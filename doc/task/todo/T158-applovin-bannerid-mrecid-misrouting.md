# T158 — Nhầm mã quảng cáo khi dev cấu hình trùng ID banner/MREC

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent adapters+adaptive, tự verify
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Nếu dev lỡ cấu hình trùng ID giữa 2 loại quảng cáo AppLovin (banner và MREC dùng chung 1 mã), khi 1 trong 2 loại bị lỗi, hệ thống nhận nhầm loại bị lỗi — không gây mất dữ liệu, chỉ làm quảng cáo đó hồi phục chậm hơn (phải chờ đến 30 giây watchdog thay vì hồi phục ngay). Chỉ xảy ra nếu dev cấu hình nhầm trùng ID.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:1944` — nhánh phân biệt banner/MREC trong `onAdLoadFailedCallback` dùng `id == _max?.mrecId && id != _max?.bannerId`; nếu `bannerId == mrecId`, điều kiện luôn `false` → mọi lỗi MREC bị route sai vào nhánh banner.

## Việc cần làm
1. Thêm cảnh báo/validate khi khởi tạo config: nếu `bannerId == mrecId` (và cả 2 đều được set), log warning rõ ràng cho dev biết đây là cấu hình dễ gây nhầm lẫn.
2. Cân nhắc sửa logic phân biệt để không phụ thuộc hoàn toàn vào so sánh ID trùng nhau (nếu khả thi, dựa thêm vào context/loại request đã gửi).
3. Thêm test cho case `bannerId == mrecId`.
4. Cập nhật CHANGELOG.md và README.md (khuyến cáo dev không nên đặt trùng ID banner/MREC).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/adapters/applovin_adapter.dart dòng ~1944: điều kiện "id == _max?.mrecId && id != _max?.bannerId" trong onAdLoadFailedCallback luôn false nếu bannerId==mrecId, khiến lỗi MREC bị route nhầm vào nhánh banner. Thêm validate lúc khởi tạo (ở nơi AdConfig/AppLovin ids được set) cảnh báo qua SafeLogger nếu bannerId==mrecId cả 2 đều non-null. Nếu có cách phân biệt banner/MREC không chỉ dựa vào so sánh ID (context khác của callback), cân nhắc sửa; nếu không khả thi, giữ nguyên logic nhưng đảm bảo có cảnh báo rõ ràng. Viết test cho case bannerId==mrecId xác nhận có warning log được phát ra.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho case `bannerId==mrecId`, xác nhận có cảnh báo log.
3. CHANGELOG.md/README.md cập nhật (khuyến cáo dev).
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device với config cố ý trùng ID, xác nhận có log cảnh báo hiện ra.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
