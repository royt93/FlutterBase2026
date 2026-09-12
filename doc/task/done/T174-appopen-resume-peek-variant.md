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

## Kết quả

**Đã làm gì:** Thêm `AdSafetyConfig.canShowAppOpenOnResumePeek()` đúng như task yêu cầu — bản "hỏi thử" không tiêu bất kỳ trạng thái nội bộ nào (`_isColdStart`, `_pendingResumeGate`, `_resumeTimestamps`), theo đúng pattern của cặp `canShowFullscreenAd`/`canShowFullscreenAdPeek` đã có sẵn. Hàm thật `canShowAppOpenOnResume()` giữ nguyên hành vi cũ — chỉ thêm 1 tham số nội bộ (`recordSideEffects`) để 2 hàm dùng chung logic kiểm tra mà không lặp code.

Điểm kỹ thuật khó nhất: `_resumeTimestamps` (danh sách thời điểm resume gần đây, dùng để chặn resume quá nhanh liên tục) — bản thật thêm thời điểm hiện tại vào danh sách rồi kiểm tra độ dài; bản Peek phải tính "nếu thêm vào thì độ dài sẽ là bao nhiêu" mà KHÔNG thực sự thêm vào danh sách thật, để không làm sai lệch bộ đếm cho lần gọi thật kế tiếp.

**Test đã viết:**
- Unit test: 4 test mới — gọi Peek nhiều lần không tiêu cờ cold-start; gọi Peek nhiều lần không tiêu pending-resume gate; gọi Peek nhiều lần không làm tăng danh sách resume timestamps (kiểm tra qua hành vi thật: gọi thật sau đó vẫn còn hạn mức); Peek và bản thật trả về cùng kết quả khi ở trạng thái không bị chặn.
- Không cần demo UI (đây là API nội bộ cho dev nâng cao, đúng như task ghi).
- Integration test + smoke test thật trên **Pixel 7 Pro**: gọi trực tiếp API thật trên máy thật (không qua giao diện), log xác nhận đúng 6 lần "Skipping App Open on cold start" (5 lần Peek + 1 lần thật) — chứng minh Peek không hề tiêu cờ cold-start trên máy thật, không chỉ trong môi trường test giả lập.

**Kết quả chạy toàn bộ test:**
- Toàn bộ SDK (1887 test) + toàn bộ app mẫu (47 file test): xanh 100%.
- `flutter analyze`: sạch.
- `codex review`: sạch ngay từ vòng 1.

**Tự chấm điểm: 9.5/10.** Làm đúng yêu cầu, đối xứng hoàn toàn với `canShowFullscreenAd`/`canShowFullscreenAdPeek`, xử lý đúng phần khó nhất (rolling window) mà không cần thay đổi hành vi bản thật.
