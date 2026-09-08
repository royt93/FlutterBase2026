# T161 — Xin quyền theo dõi quảng cáo trên iPhone (ATT) có thể bị gọi trùng lặp

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Quyền xin phép theo dõi quảng cáo trên iPhone (ATT) — nếu app vô tình gọi xin quyền này 2 lần liên tiếp trước khi lần đầu kịp trả lời (VD do bug hoặc người dùng thao tác nhanh), hiện chưa có chặn — có thể gây hiển thị lạ trên hộp thoại xin quyền của iPhone, hoặc hành vi native không xác định.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/att_consent.dart:95` — `requestAttIfNeeded()` không có guard chống gọi đồng thời/lặp trước khi lần gọi trước resolve (status vẫn `notDetermined` cả 2 lần).

## Việc cần làm
1. Thêm cờ/`Completer` chặn gọi trùng: nếu đang có 1 lần gọi `requestAttIfNeeded()` chưa resolve, lần gọi sau chờ chung kết quả thay vì gọi native lần nữa.
2. Thêm test mô phỏng gọi 2 lần liên tiếp trước khi native trả lời, xác nhận chỉ gọi native đúng 1 lần.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/att_consent.dart dòng ~95: requestAttIfNeeded() không có guard chống gọi đồng thời — nếu gọi 2 lần trước khi lần đầu resolve, có thể gọi native requestAuthorization() 2 lần chồng nhau. Thêm Completer/cờ nội bộ: nếu đang có request đang chờ, lần gọi sau await chung Future đó thay vì gọi native lần nữa. Viết unit test: gọi requestAttIfNeeded() 2 lần liên tiếp (không await lần đầu), mock native trả lời sau, xác nhận native chỉ được gọi đúng 1 lần và cả 2 lời gọi Dart đều nhận đúng kết quả.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho gọi trùng lặp trước khi resolve.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên iPhone thật (không phải simulator vì ATT dialog không hiện trên simulator), bấm nhanh liên tục nút trigger ATT, xác nhận chỉ hiện 1 hộp thoại.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
