# T187 — Thêm số liệu đối chiếu tiền vào màn hình debug tổng hợp

**Loại:** enhancement
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent vip+monetization
**Quyết định chủ dự án (2026-09-08):** Làm

## Vấn đề (giải thích thực tế)
Màn hình debug tổng hợp (`AdDiagnostics`, xem sức khỏe SDK 1 chỗ — waterfall/fill-rate/arbitrator/regression-alert) chưa hiển số "lượt đang chờ đối chiếu tiền" (`RevenueIntegrityLedger.pendingCount`) và "số lần thất thoát tiền gần đây" (từ `IncidentRecorder`, filter theo tag `revenue_integrity_missing:*`) — thêm vào dễ hơn cho dev debug "vì sao doanh thu thấp hôm nay" ở 1 chỗ duy nhất. Ngoài ra, snapshot hiện gộp CTR (click-through-rate) mọi loại quảng cáo, trong khi gate CTR-anomaly thật (round 39) chỉ tính riêng fullscreen — nên thêm field `fullscreenClickThroughRate` để khớp đúng số SDK thật sự dùng.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_manager.dart:1041-1052` (`getStatusSnapshot`) — `clickThroughRate` gộp mọi loại ad.
- `packages/ad_sdk/lib/src/monetization/ad_diagnostics.dart` + `revenue_integrity_ledger.dart` — chưa có field `pendingRevenueChecks`/`recentRevenueIntegrityIncidents`.

## Việc cần làm
1. Thêm 2 field vào `AdDiagnostics` snapshot: `pendingRevenueChecks` (từ `RevenueIntegrityLedger.pendingCount`, cần thêm getter nếu chưa có) và `recentRevenueIntegrityIncidents` (đếm/liệt kê từ `IncidentRecorder` filter tag phù hợp).
2. Thêm field `fullscreenClickThroughRate` vào `getStatusSnapshot()`, tính riêng cho fullscreen (đối chiếu đúng gate CTR-anomaly round-39 dùng logic gì).
3. Viết test cho các field mới.
4. Cập nhật debug overlay (nếu có hiển thị snapshot này) để show thêm số liệu mới.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Thêm getter pendingCount vào packages/ad_sdk/lib/src/monetization/revenue_integrity_ledger.dart nếu chưa có (đếm số _PendingShow hiện đang treo). Thêm 2 field mới vào AdDiagnostics snapshot (ad_diagnostics.dart): pendingRevenueChecks (từ RevenueIntegrityLedger.pendingCount) và recentRevenueIntegrityIncidents (đếm/liệt kê IncidentRecorder theo đúng tag revenue_integrity_missing:* mà revenue_integrity_ledger.dart đã dùng để ghi incident). Thêm field fullscreenClickThroughRate vào ad_manager.dart's getStatusSnapshot() (dòng ~1041-1052) — đọc kỹ logic CTR-anomaly gate thật (round-39) để tính đúng công thức chỉ cho fullscreen ad, không gộp banner/mrec/native. Viết unit test cho từng field mới. Nếu có debug overlay hiển thị AdDiagnostics, thêm dòng hiển thị các field mới vào đó.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho `pendingRevenueChecks`, `recentRevenueIntegrityIncidents`, `fullscreenClickThroughRate`.
3. Debug overlay cập nhật (nếu áp dụng) + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, tạo tình huống có pending revenue check + incident, xác nhận số liệu debug hiển thị đúng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
