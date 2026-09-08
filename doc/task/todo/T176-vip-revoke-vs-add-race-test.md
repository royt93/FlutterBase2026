# T176 — Thêm test bảo mật: thu hồi VIP và thêm VIP mới chạy cùng lúc

**Loại:** test-coverage (bảo mật)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent vip+monetization
**Quyết định chủ dự án (2026-09-08):** Thêm test ngay

## Vấn đề (giải thích thực tế)
Tính năng VIP (thu hồi quyền VIP khi phát hiện gian lận — `revokeAll()`) và tính năng thêm VIP mới (`addVip`/stack) có thể chạy cùng lúc — chưa có test riêng cho trường hợp cả 2 xảy ra đồng thời. Đây là phần bảo mật quan trọng (chống giả mạo/lợi dụng VIP).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/vip/vip_manager.dart:1763` (`revokeAll()`) và `:1667` (`_clampRevokedEntries()`) — chưa thấy test riêng tên rõ ràng cho "revokeAll đang chạy song song với addVip/stack".

## Việc cần làm
1. Đọc kỹ `revokeAll()`, `_clampRevokedEntries()`, `addVip`/`redeemVip` (stack) để hiểu đúng cấu trúc dữ liệu chia sẻ giữa các hàm này.
2. Viết test mô phỏng: gọi `revokeAll()` và `addVip(stack: true)` gần như đồng thời (interleave qua `Future`/microtask) — xác nhận không có state rác (VIP vừa bị revoke lại vô tình được add lại, hoặc ngược lại entry hợp lệ bị revoke nhầm).
3. Nếu phát hiện race thật, sửa theo hướng an toàn nhất (khoá tuần tự hoặc kiểm tra lại trạng thái trước khi ghi) — không đổi API công khai nếu tránh được.
4. Cập nhật CHANGELOG.md nếu có sửa code.

## Prompt để chạy loop-fix
```
Đọc kỹ packages/ad_sdk/lib/src/vip/vip_manager.dart: revokeAll() (dòng ~1763), _clampRevokedEntries() (dòng ~1667), và addVip/redeemVip (stack:true). Hiểu đúng cấu trúc dữ liệu (danh sách entries, danh sách revoked) được chia sẻ giữa các hàm. Viết test mô phỏng revokeAll() và addVip(stack: true) chạy gần như đồng thời (dùng Future.microtask/interleave để mô phỏng race thật, không chỉ gọi tuần tự) — xác nhận kết quả cuối cùng nhất quán: không có entry vừa bị revoke lại được coi là active, không có entry hợp lệ bị revoke nhầm. Nếu phát hiện race thật gây sai kết quả, sửa theo hướng khoá tuần tự hoặc re-check trạng thái trước khi ghi, ưu tiên không đổi API công khai.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Test race revokeAll-vs-addVip pass rõ ràng, không flaky (chạy lại nhiều lần để xác nhận ổn định).
3. Nếu có sửa code: CHANGELOG.md cập nhật, đây là phần bảo mật nên ghi rõ trong changelog.
4. Audit độc lập (đặc biệt kỹ vì đây là bảo mật VIP) — chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: nếu có sửa code, smoke test thật trên device qua `VipRedeemScreen` demo, thử revoke + add gần như cùng lúc (thao tác tay nhanh hoặc qua demo hook), xác nhận trạng thái VIP đúng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
