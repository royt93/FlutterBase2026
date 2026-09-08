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
