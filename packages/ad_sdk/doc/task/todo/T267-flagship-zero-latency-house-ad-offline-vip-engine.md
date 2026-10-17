# T267 — Tính Năng Độc Quyền: Động Cơ Quảng Cáo Nội Bộ Tức Thì & Upsell VIP Ngoại Tuyến (Zero-Latency House Ad & Offline VIP Engine)

- **Loại:** Flagship Feature / Monetization & UX
- **Priority:** P0 · **Severity:** HIGH
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Khi người dùng sử dụng ứng dụng trong điều kiện không có mạng (offline) hoặc khi sàn quảng cáo hết kho (no-fill):
- Hiện tại, widget banner hoặc native ad sẽ tự động co lại (collapse) hoặc để lại một khoảng trống biến mất đột ngột làm giật layout (layout shift) của ứng dụng.
- Về mặt kinh doanh: Đây là một khoảng không gian bị lãng phí hoàn toàn, không tạo ra bất kỳ giá trị nào cho nhà phát triển.

## Đề xuất giải pháp (Tính năng độc quyền)

Xây dựng **Zero-Latency House Ad & Offline VIP Upsell Engine**:
1. Cho phép host app khai báo danh sách **House Ads** nội bộ (quảng bá chéo các game/app khác của studio) kèm banner asset offline được đóng gói sẵn trong app.
2. Hoặc cấu hình **VIP Upsell Card**: hiển thị một thẻ giao diện cực đẹp: *"Nâng cấp VIP ngay để trải nghiệm mượt mà không quảng cáo cả khi có mạng lẫn mất mạng!"* kèm nút bấm mở ngay màn hình nhập mã `VipRedeemScreen`.
3. Khi provider báo lỗi mạng hoặc `no-fill`, SDK lập tức chuyển sang hiển thị House Ad hoặc VIP card với độ trễ **0ms**, hoàn toàn không gây giật layout màn hình.

## Acceptance Criteria

- [ ] Khi thiết bị offline hoặc no-fill, tự động hiển thị House Ad hoặc VIP Upsell Card mượt mà không giật layout.
- [ ] Cho phép host app dễ dàng tùy biến giao diện card, hình ảnh và action điều hướng.
- [ ] Không tốn thêm bất kỳ request mạng nào khi offline.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Widget test:** Mô phỏng provider trả về no-fill, kiểm tra House Ad card hiện ra thay thế ngay lập tức.
- **Golden test:** Chụp ảnh pixel-perfect của House Ad card và VIP upsell card.
- **Interruption & Offline test:** Chạy trên Pixel 7 Pro khi tắt mạng hoàn toàn, xác nhận card nội bộ hiển thị mượt mà.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T267 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/banner_ad_widget.dart, lib/src/widget/native_ad_widget.dart, lib/src/vip/vip_redeem_screen.dart.
2. Viết test trước để kiểm tra cơ chế hiển thị House Ad khi rớt mạng / no-fill (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
