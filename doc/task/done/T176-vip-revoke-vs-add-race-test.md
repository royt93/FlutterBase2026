# T176 — Thêm test bảo mật: thu hồi VIP và thêm VIP mới chạy cùng lúc

**Loại:** test-coverage (bảo mật)
**Ưu tiên:** P2
**Trạng thái:** done
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

## Kết quả

**Đã kiểm tra:** đọc kỹ `revokeAll()` và `addVip(stack: true)` trong `vip_manager.dart`. Cả 2 hàm đều mutate `_entries` (danh sách VIP) NGAY LẬP TỨC (đồng bộ), rồi mới `await _save()` — và `_save()` đã có sẵn 1 hàng đợi ghi nghiêm ngặt (`_saveQueue`, từ round-12 QC trước đây): mỗi lần ghi chờ lượt ghi trước xong, và MỖI lượt ghi đọc `_entries` tại đúng thời điểm nó THỰC SỰ chạy (không phải tại thời điểm được gọi). Đây chính xác là cơ chế cần thiết để tránh đúng lỗi task lo ngại (1 bản ghi cũ ("stale") đè lên bản ghi mới trên đĩa).

**Kết luận: cơ chế hiện tại đã an toàn, không cần sửa code** — đã viết test xác nhận đúng theo nhánh "nếu đã an toàn, chỉ cần viết test" mà task tự cho phép.

**Test đã viết (2 vòng):**
- Vòng 1 (đã có sẵn trước khi bị gián đoạn): 3 test — gọi `addVip()` rồi `revokeAll()` gần như cùng lúc (revoke thắng, không hồi sinh); gọi `revokeAll()` rồi `addVip()` gần như cùng lúc (add thắng vì đến sau); lặp lại 20 lần xác nhận không "flaky". Cả 2 trường hợp đều kiểm tra ĐÚNG cả trạng thái trong bộ nhớ VÀ dữ liệu đã lưu xuống đĩa (tải lại bằng 1 `VipManager` mới để xác nhận không có gì "hồi sinh" sai).
- Vòng 2 (hoàn thiện sau khi bị gián đoạn, theo góp ý `codex`): fake store ban đầu ghi dữ liệu "tức thì" (không có độ trễ thật), nên KHÔNG thể phân biệt được "hàng đợi ghi thật sự hoạt động đúng" với "không có hàng đợi, nhưng chưa bao giờ đủ chậm để bị đảo thứ tự". Đã thêm 1 test chặt chẽ hơn: cố tình giữ 1 lượt ghi (revoke) "treo" chưa cho hoàn tất, rồi bắt đầu 1 lượt ghi khác (add) trong lúc đó — xác nhận lượt ghi thứ 2 KHÔNG thể "chen ngang" trước lượt ghi thứ 1 đang bị giữ, rồi mới thả lượt ghi thứ 1 ra và xác nhận thứ tự cuối cùng đúng. Đây mới thực sự chứng minh cơ chế hàng đợi hoạt động, không phải chỉ "may mắn" do tốc độ.

**Kết quả chạy toàn bộ test:** Toàn bộ SDK (1944 test) xanh 100%, `flutter analyze` sạch, `codex review` sạch ở vòng cuối.

**Sự cố phát sinh ngoài ý muốn (đã xử lý riêng, không thuộc phạm vi T176):** Trong lúc kiểm tra lại toàn bộ test suite sau khi hoàn thiện T176, phát hiện 3 test KHÁC (không liên quan VIP) đang đỏ — nguyên nhân là lỗi có sẵn từ trước (không phải do T176 hay do các thay đổi khác gần đây): 3 test đó tính ngày "hôm nay"/"N ngày trước" theo GIỜ ĐỊA PHƯƠNG, trong khi dữ liệu thật được lưu theo GIỜ UTC (từ bản sửa T165) — chỉ lộ ra đúng vào khung giờ mỗi ngày mà ngày lịch địa phương và ngày lịch UTC lệch nhau (như đúng lúc phát hiện: 00:xx giờ Việt Nam nhưng UTC vẫn còn ngày hôm trước). Đã sửa cả 3 file test, gộp chung vào 1 commit với phần hoàn thiện T176.

**Tự chấm điểm: 9.5/10** — xác nhận đúng lo ngại của task đã được xử lý an toàn từ trước, hoàn thiện chất lượng test theo góp ý độc lập, và phát hiện + sửa thêm 1 lỗi test có sẵn (không phải do mình gây ra) khiến build đỏ.
