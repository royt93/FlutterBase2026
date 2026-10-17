# T268 — Rà Soát & Phòng Ngừa Click Nhầm Theo Chính Sách AdMob (Accidental Clicks Prevention & Layout Safety)

- **Loại:** Enhancement / Policy Compliance & Account Safety
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Chính sách của Google AdMob về "Lưu lượng truy cập không hợp lệ" (Invalid Traffic) nghiêm cấm các hành vi dẫn tới click nhầm (Accidental Clicks):
- Đặt quảng cáo quá sát các nút bấm điều hướng hoặc thanh cuộn khiến ngón tay vô tình chạm trúng khi thao tác.
- Quảng cáo nạp chậm làm đẩy lệch bố cục màn hình (Layout Shift) đúng lúc người dùng chuẩn bị bấm vào nội dung app.
- **Cảnh báo kỹ thuật:** Tuyệt đối KHÔNG sử dụng các kỹ thuật chặn cảm ứng nhân tạo (như phủ lớp màng trong suốt đè lên ad platform view) vì Google coi việc can thiệp vào tầng chạm của native ad là hành vi che khuất/sửa đổi quảng cáo trái phép.

## Đề xuất giải pháp (Tuân thủ chính sách AdMob)

1. **Khóa chiều cao tối thiểu tránh Layout Shift:**
   - Trong `BannerAdWidget`, `MrecAdWidget` và `NativeAdWidget`, đảm bảo placeholder luôn giữ đúng diện tích dự kiến trong suốt quá trình loading (đã kết hợp với `ShimmerView` ở T257).
2. **Khuyến nghị & Cảnh báo khoảng cách an toàn (Proximity Guard):**
   - Hướng dẫn và kiểm tra khoảng đệm tối thiểu (margin >= 8-16dp) giữa banner/native ad và các nút bấm tương tác quan trọng của host app.
3. **Chống kích hoạt hiển thị bất ngờ:**
   - Khi người dùng đang thao tác cuộn nhanh hoặc gõ bàn phím, trì hoãn hiển thị ad toàn màn hình cho đến khi tác vụ người dùng kết thúc.

## Acceptance Criteria

- [ ] Giữ vững diện tích khung ad trong lúc nạp, loại bỏ hiện tượng giật layout (Cumulative Layout Shift = 0).
- [ ] Tuân thủ 100% Google Publisher Policies về Unintended Clicks (không can thiệp platform touch channel trái phép).
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Widget test:** Kiểm tra layout không bị co giật khi chuyển từ Shimmer sang Loaded.
- **Integration test:** Thao tác cuộn trên Pixel 7 Pro và xác nhận banner không nhảy vị trí.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T268 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/banner_ad_widget.dart, lib/src/widget/native_ad_widget.dart.
2. Viết test trước để kiểm tra tính ổn định layout (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
