# T268 — Rà Soát & Phòng Ngừa Click Nhầm Theo Chính Sách AdMob (Accidental Clicks Prevention & Layout Safety)

- **Loại:** Enhancement / Policy Compliance & Account Safety
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (đã rà SDK và thêm hướng dẫn cho app tích hợp; bố cục từng app vẫn cần kiểm riêng)

## Kết quả rà soát hiện tại (2026-10-18)

- SDK giữ sẵn chỗ cho banner 50dp và MREC 250dp; native ad dùng chiều cao theo template hoặc do app chọn. Banner dùng `AnimatedSize` khi đổi trạng thái. Những biện pháp này giúp ổn định phần bố cục thuộc SDK, nhưng chưa chứng minh quảng cáo không làm nội dung dịch chuyển trong mọi app.
- Đã có test cho banner/MREC khi tải thành công, lỗi, mất mạng hoặc đổi màn hình; `InFeedAdListView` cũng trì hoãn tải native ad mới khi người dùng đang cuộn. Ba nhóm test liên quan pass (98 tests), analyzer sạch. Device test Pixel 7 Pro `example/integration_test/t141_in_feed_native_ad_list_view_test.dart` kiểm tra danh sách khi cuộn.
- Đã bổ sung checklist cho app tích hợp tại `doc/AD_PROMPT_FLUTTER.MD`, Step 7: đặt quảng cáo tách khỏi nút bấm, kiểm tra bố cục trước/sau khi quảng cáo tải, kiểm tra lúc cuộn và mở bàn phím, không phủ lớp hoặc chặn thao tác trên quảng cáo.
- Mỗi app tự sắp xếp các nút và quảng cáo; SDK không thể biết quảng cáo có nằm sát nút trong toàn bộ màn hình của app hay không. Vì vậy, app tích hợp cần tự kiểm tra bố cục trên thiết bị thật.
- T268 không thêm lớp chặn thao tác, khoảng cách tự động, hoặc quy tắc toàn cục trì hoãn mọi quảng cáo toàn màn hình. App Open đã tránh hiển thị chồng lên hộp thoại; các app vẫn cần chọn thời điểm phù hợp cho interstitial và keyboard/scroll.

## Bối cảnh & Vấn đề

Chính sách của Google AdMob về "Lưu lượng truy cập không hợp lệ" (Invalid Traffic) nghiêm cấm các hành vi dẫn tới click nhầm (Accidental Clicks):
- Đặt quảng cáo quá sát các nút bấm điều hướng hoặc thanh cuộn khiến ngón tay vô tình chạm trúng khi thao tác.
- Quảng cáo nạp chậm làm đẩy lệch bố cục màn hình (Layout Shift) đúng lúc người dùng chuẩn bị bấm vào nội dung app.
- **Cảnh báo kỹ thuật:** Tuyệt đối KHÔNG sử dụng các kỹ thuật chặn cảm ứng nhân tạo (như phủ lớp màng trong suốt đè lên ad platform view) vì Google coi việc can thiệp vào tầng chạm của native ad là hành vi che khuất/sửa đổi quảng cáo trái phép.

## Phạm vi & Acceptance Criteria

- [x] Banner/MREC giữ trước vùng chỗ dự kiến khi chờ quảng cáo; banner chuyển trạng thái có `AnimatedSize`. Native ad dùng chiều cao theo template hoặc cấu hình của app.
- [x] Không thêm lớp phủ hoặc chặn thao tác chạm lên quảng cáo native.
- [x] Bổ sung hướng dẫn để app tích hợp đặt quảng cáo tách khỏi nút bấm và kiểm tra bố cục trước/sau khi quảng cáo tải trong `doc/AD_PROMPT_FLUTTER.MD`, Step 7.
- [x] `flutter analyze` sạch; ba nhóm test widget liên quan pass 98 tests; có device test cuộn trên Pixel 7 Pro.
- [ ] Chưa đo mức dịch chuyển với quảng cáo thật trên các app và kích thước màn hình đại diện. Không thể kết luận mọi app có `CLS = 0` từ source SDK.
- [ ] Mỗi app tích hợp vẫn phải kiểm tra quảng cáo có gần nút bấm hay không trên bố cục thật của app đó.

## Kiểm thử đã có và phần app cần tự kiểm

- `test/banner_ad_widget_test.dart`: placeholder, trạng thái tải/lỗi, co và mở lại banner.
- `test/mrec_ad_widget_test.dart`: placeholder, offline/reconnect, trạng thái route và active.
- `test/in_feed_ad_list_view_test.dart`: trì hoãn tải native ad mới trong lúc cuộn và xử lý danh sách khi cuộn.
- `example/integration_test/t141_in_feed_native_ad_list_view_test.dart`: smoke test danh sách cuộn trên thiết bị.
- App tích hợp cần chụp/đo vị trí quảng cáo trước và sau khi quảng cáo thật tải; xem quảng cáo có nằm sát controls không. SDK không thể thay bước kiểm tra này.

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
