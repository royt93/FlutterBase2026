# T150 — Sổ sách đối chiếu tiền quảng cáo ghép nhầm giữa các loại quảng cáo khác nhau

**Loại:** bug
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** 3/3 nguồn độc lập xác nhận (subagent vip+monetization, codex, agy) — độ tin cậy rất cao
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Hệ thống ghi sổ sách đối chiếu tiền quảng cáo (`RevenueIntegrityLedger`, T145) đang ghép nhầm: nếu app hiện 2 loại quảng cáo khác nhau (VD banner nhỏ + quảng cáo toàn màn hình) ở cùng 1 vị trí gần nhau, tiền trả về của loại này có thể bị tính nhầm khớp cho loại kia. Hậu quả: báo cáo "thất thoát tiền quảng cáo" có thể báo sai, che mất chỗ thật sự đang mất tiền.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart:67-83` — struct `_PendingShow` chỉ lưu `(providerTag, placement, at)`, KHÔNG có `type` (`AdSlotType`), dù cả `AdShowEvent`/`AdRevenueEvent` đều đã mang sẵn `type`.
- Khi app dùng cùng `AdPlacement` cho 2 format khác nhau (VD cả hai đều `AdPlacement.unspecified`), `AdRevenueEvent` của format A khớp FIFO nhầm vào `_PendingShow` của format B — "xoá" nhầm entry đang chờ, ẩn mất đúng gap thật (revenue thiếu ở format B) trong khi format A bị báo sai.
- Test hiện tại (`test/revenue_integrity_ledger_test.dart`) chỉ test khác-placement, không test khác-type-cùng-placement — helper `_show()`/`_revenue()` hard-code `AdSlotType.interstitial`.

## Việc cần làm
1. Thêm `type` (`AdSlotType`) vào key so khớp của `_PendingShow` — match phải đúng cả `providerTag + placement + type`.
2. Kiểm tra `dispose()` và mọi chỗ khác trong file có giả định ngầm nào dựa trên key cũ (không có type) — sửa đồng bộ.
3. Thêm log SafeLogger khi 1 revenue event không khớp được pending show nào (đã có sẵn cơ chế incident, đảm bảo log rõ ràng gồm cả `type`).
4. Thêm test: 2 pending show cùng `providerTag+placement` nhưng khác `type` — xác nhận revenue event chỉ khớp đúng type của nó, không "trả nợ thay" nhầm.
5. Thêm demo trong `example/` (`RevenuePanel` hoặc trang debug tương tự): mô phỏng show đồng thời banner + interstitial cùng placement, cho thấy revenue khớp đúng từng loại.
6. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart: struct _PendingShow (dòng ~67-83) hiện chỉ match theo (providerTag, placement), thiếu type (AdSlotType) dù AdShowEvent/AdRevenueEvent đều có sẵn field type. Thêm type vào _PendingShow và vào điều kiện so khớp trong _onEvent (indexWhere) — match phải đúng cả 3: providerTag + placement + type. Kiểm tra mọi nơi khác dùng _PendingShow trong file (dispose, incident label...) để đồng bộ. Viết test mới trong test/revenue_integrity_ledger_test.dart: pending show của interstitial VÀ banner cùng providerTag+placement, sau đó revenue event tới cho banner — xác nhận chỉ pending show của banner bị xoá/khớp, pending show của interstitial vẫn còn treo đúng như thật. Test hiện tại hard-code AdSlotType.interstitial trong helper _show()/_revenue() — sửa helper để nhận type làm tham số. Thêm log SafeLogger. Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho case khác-type-cùng-placement (cả 2 chiều: banner rồi interstitial, và ngược lại); test cũ khác-placement vẫn phải xanh.
3. Log SafeLogger đầy đủ khi revenue không khớp pending nào.
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập (đặc biệt lưu ý: bug này đã 3/3 nguồn xác nhận, audit lần này tập trung xác nhận fix KHÔNG phá vỡ hành vi cũ cho case chỉ-1-loại-quảng-cáo) — chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, hiện đồng thời banner + interstitial cùng vị trí, xác nhận revenue panel/log khớp đúng từng loại.
8. Thành công: commit + push. Thất bại: quay lại bước 1.
