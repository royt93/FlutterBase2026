# T174 — Thêm hàm "hỏi thử không tiêu lượt" cho quảng cáo mở lại app

**Loại:** enhancement (API ergonomics)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state
**Quyết định chủ dự án (2026-09-08):** Làm luôn cho đồng bộ

## Vấn đề (giải thích thực tế)
Có 1 hàm kiểm tra "có nên hiện quảng cáo mở lại app không" (`canShowAppOpenOnResume`) — gọi hàm này sẽ tiêu tốn 1 "lượt dùng" nội bộ (one-shot `_isColdStart`, poison `_pendingResumeGate`/`_resumeTimestamps`), không thể hỏi thử rồi hỏi lại. Hiện chỉ có 1 chỗ trong SDK dùng đúng cách. Chủ dự án chọn làm luôn cho đồng bộ với cặp hàm tương tự đã có cho quảng cáo thường (`canShowFullscreenAd`/`canShowFullscreenAdPeek`).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_safety_config.dart:683` — `canShowAppOpenOnResume()` không có biến thể "peek" (không side-effect) như cặp `canShowFullscreenAd`/`canShowFullscreenAdPeek`.

## Việc cần làm
1. Thêm `canShowAppOpenOnResumePeek()` — kiểm tra điều kiện tương tự nhưng KHÔNG tiêu side-effect (`_isColdStart`, `_pendingResumeGate`, `_resumeTimestamps`).
2. Đảm bảo `canShowAppOpenOnResume()` (bản thật, có side-effect) vẫn giữ nguyên hành vi cũ — không đổi hành vi tại điểm gọi hiện tại.
3. Viết test cho `Peek` variant: gọi nhiều lần liên tiếp không thay đổi trạng thái nội bộ; gọi bản thật sau đó vẫn hoạt động đúng.
4. Cập nhật CHANGELOG.md (API mới, public).

## Prompt để chạy loop-fix
```
Thêm hàm mới packages/ad_sdk/lib/src/core/ad_safety_config.dart: canShowAppOpenOnResumePeek() — bản "chỉ xem trước, không side-effect" của canShowAppOpenOnResume() (dòng ~683), theo đúng pattern cặp canShowFullscreenAd/canShowFullscreenAdPeek đã có sẵn trong cùng file (đọc kỹ cặp đó để copy đúng cách tách side-effect ra khỏi điều kiện kiểm tra). Đảm bảo hàm thật canShowAppOpenOnResume() không đổi hành vi. Viết unit test: gọi canShowAppOpenOnResumePeek() nhiều lần liên tiếp, xác nhận _isColdStart/_pendingResumeGate/_resumeTimestamps không bị thay đổi; gọi xen giữa với canShowAppOpenOnResume() thật, xác nhận bản thật vẫn hoạt động đúng như trước khi thêm hàm mới.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho `Peek` variant (gọi lặp lại không side-effect) + test bản thật không bị breaking.
3. CHANGELOG.md cập nhật (API mới).
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, không cần demo UI riêng (API nội bộ/tiện ích cho dev nâng cao) nhưng xác nhận qua log rằng gọi Peek nhiều lần không ảnh hưởng hành vi App Open thật.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
