# T268 — Tính Năng Độc Quyền: Lá Chắn Bảo Vệ Chống Click Nhầm "AdShield" (Touch Guard Zone)

- **Loại:** Flagship Feature / Account Protection & Anti-Fraud
- **Priority:** P0 · **Severity:** HIGH
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Nguyên nhân hàng đầu khiến các tài khoản Google AdMob bị giới hạn quảng cáo (Ad serving limit) hoặc bị khóa vĩnh viễn là: **Lưu lượng truy cập không hợp lệ do click nhầm (Accidental Clicks)**:
- Người dùng đang lướt app hoặc chuẩn bị bấm vào một nút, quảng cáo banner bất ngờ nạp xong hoặc quảng cáo xen kẽ bất ngờ bật lên đúng vị trí ngón tay đang bấm xuống.
- Hoặc khi nút "Đóng" (X) vừa xuất hiện, người dùng bấm quá sát mép viền khiến hệ điều hành ghi nhận chạm vào vùng quảng cáo thay vì nút đóng.
- Tỷ lệ click nhầm cao khiến Google đánh giá ứng dụng cố tình đánh lừa người dùng, dẫn đến khóa tài khoản kiếm tiền mà không thể kháng cáo.

## Đề xuất giải pháp (Tính năng độc quyền)

Xây dựng hệ thống bảo vệ **AdShield Touch Guard**:
1. **Khóa cảm ứng 500ms khi hiển thị (Mount Touch Lock):**
   - Khi một quảng cáo toàn màn hình (Interstitial, Rewarded, App Open) hoặc Native Ad vừa render xong lên màn hình: một lớp màng bảo vệ trong suốt vô hình khóa tương tác cảm ứng chạm vào ad trong đúng **500 miligiây đầu tiên**.
   - Nếu ngón tay vô tình chạm trúng trong 500ms này, sự kiện chạm bị triệt tiêu hoàn toàn, không mở trình duyệt quảng cáo.
2. **Edge Tap Filter (Bộ lọc viền nút đóng):**
   - Tự động mở rộng vùng nhận diện của nút "Đóng" thêm 8px ra xung quanh, ngăn ngừa việc chạm hụt nút X làm kích hoạt quảng cáo.

## Acceptance Criteria

- [ ] Trong 500ms đầu tiên sau khi ad hiện, mọi cú chạm vô tình đều bị chặn, không bao giờ mở trang đích quảng cáo.
- [ ] Sau 500ms, quảng cáo phản hồi click bình thường cho người dùng có nhu cầu tìm hiểu thật.
- [ ] Giảm thiểu 99% rủi ro bị Google AdMob phạt lỗi Accidental Clicks / Invalid Traffic.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Widget test:** Bấm vào ad ở ms 200 (xác nhận click bị chặn), bấm ở ms 600 (xác nhận click được ghi nhận).
- **Integration test:** Thao tác trên Google Pixel 7 Pro thật để kiểm chứng cảm giác mượt mà và an toàn.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T268 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/ad_safety_config.dart, lib/src/widget/ad_screen.dart, lib/src/widget/banner_ad_widget.dart.
2. Viết test trước để kiểm tra cơ chế chặn click trong 500ms đầu (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
