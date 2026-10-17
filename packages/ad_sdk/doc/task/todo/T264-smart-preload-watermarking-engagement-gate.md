# T264 — Cơ Chế Nạp Trước Thông Minh Dựa Trên Mức Độ Tương Tác Của Người Dùng (Smart Preload Watermarking)

- **Loại:** Feature / Monetization Optimization
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Hiện tại, ngay khi ứng dụng khởi chạy xong splash, SDK tự động gửi request nạp trước (preload) cho Interstitial và Rewarded ad:
- Thống kê thị trường cho thấy khoảng 15-25% người dùng mở app nhầm hoặc chỉ kiểm tra nhanh rồi đóng app trong vòng dưới 10 giây (Bounce users).
- Các quảng cáo nạp trước cho nhóm người dùng này không bao giờ được hiển thị, dẫn đến:
  1. Lãng phí băng thông mạng của người dùng.
  2. Tăng số lượng ad request mà không có impression, làm tụt tỷ lệ hiển thị (Show Rate) và khiến thuật toán của Google AdMob / AppLovin hạ điểm chất lượng inventory (eCPM bị giảm sút).

## Đề xuất giải pháp

1. Thêm cơ chế **Engagement-Gated Preload**:
   - Chỉ nạp trước App Open và Banner ngay lập tức.
   - Trì hoãn việc nạp trước Interstitial / Rewarded cho đến khi người dùng thỏa mãn một trong các điều kiện tương tác:
     - Đã ở trong app liên tục >15 giây.
     - Hoặc đã thực hiện ít nhất 2 lần chuyển màn hình (route navigation).
     - Hoặc host app chủ động gọi `AdManager().markUserEngaged()`.
2. Có cờ cấu hình `AdConfig.smartPreloadEnabled` (mặc định `true`, có thể tắt để nạp ngay như cũ).

## Acceptance Criteria

- [ ] Giảm thiểu tối đa các ad request vô ích từ người dùng bounce tức thì.
- [ ] Khi người dùng tương tác đủ thời gian hoặc chuyển route, ad bắt đầu nạp ngầm mượt mà.
- [ ] Nâng cao chỉ số Show Rate và bảo vệ eCPM trên dashboard của sàn quảng cáo.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Giả lập dòng thời gian tương tác, kiểm tra thời điểm kích hoạt request nạp quảng cáo.
- **Widget test:** Tương tác chuyển màn hình và xác nhận ad slot chuyển sang trạng thái `loading`.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T264 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/ad_manager.dart, lib/src/state/ad_slot.dart.
2. Viết test trước để kiểm tra cổng kích hoạt nạp trước thông minh (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
