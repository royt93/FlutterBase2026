# T185 — Mã số riêng cho từng lượt quảng cáo để đối chiếu tiền chính xác 100%

**Loại:** enhancement (nâng cấp exclusive-feature T150)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent vip+monetization
**Quyết định chủ dự án (2026-09-08):** Làm luôn (lưu ý: KHÔNG ảnh hưởng app example — chỉ thêm field mới nullable, không bắt buộc điền)

## Vấn đề (giải thích thực tế)
Hiện SDK đối chiếu tiền quảng cáo bằng cách đoán "quảng cáo nào chiếu gần giờ nào thì khớp tiền đó" (đã sửa lỗi đoán sai ở T150 — thêm `type` vào key so khớp). Ý tưởng nâng cấp tiếp: gắn 1 mã số riêng cho từng lượt quảng cáo để khớp CHÍNH XÁC 100% thay vì đoán theo cửa sổ thời gian — nhưng phải sửa cả 2 mạng quảng cáo (Google + AppLovin) cùng lúc để sinh mã số đồng bộ.

**Lưu ý bắt buộc:** T150 phải hoàn thành TRƯỚC task này (T150 giải quyết phần lớn vấn đề thực tế với chi phí thấp hơn nhiều; task này là nâng cấp thêm, không phải thay thế).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart:38` và toàn bộ cơ chế match — hiện dựa vào `(providerTag, placement, type, at)`.
- `AdShowEvent`/`AdRevenueEvent` (state event classes, đã export công khai) cần thêm field mới, VD `requestId`/`impressionId` (nullable, optional — không bắt buộc điền, không breaking).
- Cần cả `admob_adapter.dart` và `applovin_adapter.dart` sinh ID này lúc load/show và đính kèm vào cả `AdShowEvent` lẫn `AdRevenueEvent` tương ứng.

## Việc cần làm
1. Thêm field `requestId` (String?, nullable) vào `AdShowEvent` và `AdRevenueEvent` (`lib/src/state/ad_event.dart`).
2. Sửa `admob_adapter.dart` và `applovin_adapter.dart`: sinh 1 ID duy nhất (UUID hoặc tương đương) lúc load quảng cáo, gắn vào cả sự kiện show và sự kiện revenue của đúng lượt đó.
3. Sửa `revenue_integrity_ledger.dart`: nếu CẢ HAI sự kiện (show và revenue) đều có `requestId` khớp nhau, dùng khớp chính xác thay vì đoán theo cửa sổ thời gian; nếu 1 trong 2 (hoặc cả 2) không có `requestId` (VD adapter cũ chưa cập nhật, hoặc network không trả đủ thông tin), fallback về cách đoán cũ (đã có từ T150) — không được yêu cầu bắt buộc phải có `requestId` mới hoạt động.
4. Viết test cho cả 2 đường: có `requestId` (khớp chính xác) và không có (fallback đoán theo cửa sổ thời gian).
5. Xác nhận app mẫu (`example/`) không cần sửa gì — field mới nullable, optional, không breaking code hiện có.
6. Cập nhật CHANGELOG.md và README.md.

## Prompt để chạy loop-fix
```
Sau khi T150 đã hoàn thành (đọc lại doc/task/done/T150*.md để biết trạng thái match-key mới nhất), thêm field requestId (String?, nullable) vào AdShowEvent và AdRevenueEvent trong packages/ad_sdk/lib/src/state/ad_event.dart. Sửa packages/ad_sdk/lib/src/adapters/admob_adapter.dart và applovin_adapter.dart: sinh 1 UUID (hoặc ID tương đương) lúc load quảng cáo, đính kèm vào cả sự kiện show và sự kiện revenue tương ứng của đúng lượt đó (2 network SDK khác nhau, cần đọc kỹ callback flow của từng adapter để tìm đúng chỗ sinh/gắn ID). Sửa packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart: nếu cả pending show và revenue event đều có requestId khớp nhau, dùng khớp chính xác đó; nếu không, fallback về cách khớp theo (providerTag, placement, type, cửa sổ thời gian) đã có từ T150 — không được bắt buộc phải có requestId. Viết test cho cả 2 đường. Xác nhận example/ không cần sửa gì (field optional, không breaking).
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả đường khớp-chính-xác (có `requestId`) và đường fallback (không có, dùng logic T150); test xác nhận `example/` build/chạy bình thường không cần sửa.
3. CHANGELOG.md/README.md cập nhật, giải thích rõ đây là optional field, backward-compatible.
4. Audit độc lập (kiểm tra kỹ: không breaking API hiện có, không bắt buộc requestId) — chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device cả AdMob và AppLovin, xác nhận revenue khớp chính xác qua `requestId`, log/demo cho thấy rõ ID được sinh và khớp đúng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
