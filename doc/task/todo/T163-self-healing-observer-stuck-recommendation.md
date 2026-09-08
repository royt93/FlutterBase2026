# T163 — Tính năng "tự sửa khi quảng cáo kém" bị câm vĩnh viễn sau vài lần đổi qua đổi lại

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy, tự verify đúng code thật
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Tính năng "tự sửa khi quảng cáo kém" (`SelfHealingObserver`) theo dõi xem nên gợi ý chuyển sang mạng quảng cáo nào. Nếu nó gợi ý "chuyển sang Google", rồi sau đó gợi ý "chuyển sang AppLovin" (vì Google tạm thời kém hơn) — hệ thống chặn không cho lặp lại gợi ý đã từng đưa. Vấn đề: nếu sau này Google tốt lại và cần gợi ý quay về Google lần nữa, hệ thống sẽ IM LẶNG MÃI MÃI không gợi ý nữa cho vị trí đó (vì cả 2 chiều đã từng được gợi trước đó), dù thực sự cần đổi lại.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/self_healing_observer.dart:91,95,110,113` — `_alreadyObserved` (một `Set<String>`) chỉ được thêm vào (`add`), không bao giờ bị xoá/evict — mỗi cặp `(placement, hướng gợi ý)` chỉ được phép gợi ý đúng 1 lần trong suốt vòng đời.

## Việc cần làm
1. Thiết kế lại cơ chế chống lặp: thay vì chặn vĩnh viễn theo key tĩnh, cân nhắc TTL (hết hạn sau X ngày) hoặc chỉ chặn lặp lại gợi ý GIỐNG HỆT gần đây (không chặn nếu đã có ít nhất 1 gợi ý ngược lại xen giữa).
2. Viết test: gợi ý A → B → (mô phỏng thời gian trôi qua hoặc điều kiện thực tế đổi) → cần gợi ý A lại — xác nhận hệ thống không còn câm.
3. Cập nhật CHANGELOG.md, ghi rõ giới hạn mới của cơ chế chống lặp (TTL bao lâu, hoặc điều kiện gì mở khoá lại).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/monetization/self_healing_observer.dart: _alreadyObserved (Set<String>, dòng ~91) chỉ add() không bao giờ evict, khiến sau khi 1 vị trí đã nhận đủ 2 chiều gợi ý (A rồi B), hệ thống không bao giờ gợi ý lại cho vị trí đó nữa dù sau này thực sự cần đổi lại. Đọc kỹ toàn bộ logic file để hiểu đúng invariant hiện tại trước khi sửa (đừng phá vỡ mục đích chống dedupe 2 gợi ý sát nhau). Thiết kế cơ chế TTL hoặc "chỉ chặn lặp lại gợi ý giống hệt gần đây trong X ngày" thay vì chặn vĩnh viễn theo key tĩnh. Viết unit test: mô phỏng gợi ý A rồi B rồi (sau khi TTL hết hạn hoặc điều kiện mở khoá) cần A lại — xác nhận không còn bị chặn.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả chống-dedupe-sát-nhau (giữ nguyên hành vi cũ có ích) VÀ mở khoá lại sau TTL/điều kiện.
3. CHANGELOG.md cập nhật rõ ràng cơ chế mới.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device qua demo mô phỏng nhiều vòng lỗi/hồi phục mạng quảng cáo, xác nhận gợi ý tiếp tục hoạt động qua nhiều vòng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
