# T157 — Banner quảng cáo vỡ khung khi đặt trong container nhỏ hơn toàn màn hình

**Loại:** enhancement
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** codex + agy (2 nguồn độc lập)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Banner quảng cáo hiện đang đo kích thước theo TOÀN MÀN HÌNH (`MediaQuery.of(ctx).size.width`) thay vì theo khung chứa nó. Nếu dev đặt banner trong 1 khung nhỏ hơn (VD popup, sidebar, màn hình chia đôi trên tablet), banner vẫn xin kích thước to như toàn màn hình → có thể bị tràn ra ngoài khung, vỡ giao diện, và vi phạm chính sách hiển thị của Google AdMob (kích thước banner phải khớp không gian thật).

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:358-360` — tính chiều rộng Adaptive Banner bằng `MediaQuery.of(ctx).size.width`.

## Việc cần làm
1. Bọc phần tính kích thước bằng `LayoutBuilder`, ưu tiên lấy `constraints.maxWidth`; chỉ fallback về `MediaQuery.of(context).size.width` khi `constraints.maxWidth` unbounded (`double.infinity`).
2. Kiểm tra `mrec_ad_widget.dart` có logic tương tự cần đồng bộ không (MREC thường là kích thước cố định 300x250 nên có thể không cần, nhưng verify).
3. Thêm test: đặt `BannerAdWidget` trong `SizedBox(width: 200)` — xác nhận banner xin đúng kích thước ~200, không phải kích thước toàn màn hình.
4. Thêm demo trong `example/`: 1 màn hình có banner trong popup/dialog hẹp và 1 banner toàn màn hình bình thường, so sánh trực quan.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/banner_ad_widget.dart dòng ~358-360: tính chiều rộng Adaptive Banner đang dùng MediaQuery.of(ctx).size.width (toàn màn hình) thay vì theo khung chứa thật. Bọc bằng LayoutBuilder, ưu tiên constraints.maxWidth; chỉ fallback về MediaQuery khi constraints.maxWidth là double.infinity (unbounded, VD khi banner không nằm trong constraint nào rõ ràng). Kiểm tra xem có cần áp dụng tương tự cho mrec_ad_widget.dart không (MREC thường kích thước cố định nên khả năng không cần, verify trước khi sửa). Viết widget test: BannerAdWidget trong SizedBox(width: 200, height: 60) xác nhận kích thước banner request đúng ~200 không phải full-screen-width; test banner ngoài mọi constraint (unbounded) vẫn fallback về MediaQuery đúng như cũ, không breaking. Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho cả case constrained (LayoutBuilder) và unbounded (fallback MediaQuery); test không breaking hành vi cũ cho banner toàn màn hình bình thường.
3. Demo trong `example/` (popup hẹp + toàn màn hình) + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device (thử cả điện thoại và tablet/màn hình lớn nếu có), xác nhận banner trong popup không tràn khung.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-11)

**Giải thích cho người không rành kỹ thuật:** Trước đây, khi banner quảng
cáo được đặt trong 1 khung nhỏ hơn màn hình (popup, hộp thoại, sidebar...),
SDK vẫn "đo" kích thước theo TOÀN MÀN HÌNH rồi xin Google gửi về 1 banner to
đúng bằng màn hình — banner đó chắc chắn tràn ra ngoài khung nhỏ, vỡ giao
diện. Giờ banner tự đo đúng cái khung thật của nó và xin đúng kích thước
đó. Nếu khung đó co giãn sau này (xoay màn hình, kéo giãn 1 cửa sổ chia đôi
màn hình...), banner cũng tự phát hiện và xin lại cho đúng — nhưng có 1 độ
trễ ngắn (0.3 giây) để tránh xin lại ad thật liên tục nếu ai đó cố tình làm
khung đó co giãn liên tục (tốn tiền request quảng cáo thật vô ích).

**Kỹ thuật đã sửa (`banner_ad_widget.dart`):**
- Lần tải ĐẦU TIÊN vẫn dùng `MediaQuery` làm phỏng đoán ban đầu như cũ
  (không đổi timing của ~20 test cũ), nhưng được delay đúng 1 frame
  (`addPostFrameCallback`) để widget kịp đo xong layout thật trước khi thực
  sự gửi yêu cầu — nên trong đại đa số trường hợp, ngay lần tải đầu đã đúng
  kích thước khung thật, không phải màn hình.
- Thêm `_AdmobWidthObserver`/`_RenderAdmobWidthObserver` — 1
  `RenderProxyBox` (KHÔNG dùng `LayoutBuilder`) theo dõi mọi lần layout
  thật của widget, kể cả khi widget cha thay đổi kích thước container mà
  không hề rebuild lại banner (VD `AnimatedContainer` tự co giãn theo animation).
  `LayoutBuilder` đã bị loại bỏ hoàn toàn sau khi phát hiện nó âm thầm phá
  vỡ callback `VisibilityDetector` (0 lần gọi khi cuộn banner ra khỏi màn
  hình — bug nghiêm trọng, phát hiện qua chính bộ test có sẵn).
- Có debounce 300ms để 1 container đang animate liên tục không làm banner
  bị tải lại thật hàng chục lần trong 1 giây.
- `mrec_ad_widget.dart`: xác nhận KHÔNG cần sửa — `admob_adapter.dart:2552`
  ghi rõ MREC luôn cố định 300×250, tham số width truyền vào bị bỏ qua.

**Kết quả review độc lập (`codex review --uncommitted`, 5 vòng):**
- Vòng 1-4: mỗi vòng codex tìm ra 1 lỗ hổng thật (banner vẫn tải sai kích
  thước lần đầu khi mount ẩn rồi kích hoạt lại; container co giãn không
  kèm rebuild bị bỏ sót; container biến thành unbounded bị "đóng băng" ở
  kích thước cũ) — đều đã sửa và có test riêng cho từng case.
- Vòng 5: sạch, không tìm thêm lỗi.

**Test coverage:**
- `test/banner_ad_widget_test.dart`: 30 test (từ 27 cũ + 3 mới cho T157:
  SizedBox(200) lần đầu, kích hoạt banner ẩn trong container hẹp, resize
  container không kèm rebuild, resize qua AnimatedContainer không rebuild
  gì cả).
- Full SDK suite: 1823 test xanh (`flutter test` trong `packages/ad_sdk`).
- Full example suite: 42 test xanh, có test navigation cho tile demo mới
  + đếm số tile (21 → 22).
- Demo mới trong `example/`: màn hình riêng "Banner adaptive sizing
  (T157)" — 1 banner toàn màn hình + nút mở banner trong popup rộng
  220px, so sánh trực quan.
- CHANGELOG.md: thêm mục `[Unreleased]` mô tả fix.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** chạy `integration_test/r157_banner_narrow_popup_test.dart` với
`--dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_SPLASH_AD=true`
— PASS. Log thật xác nhận: banner toàn màn hình xin đúng width≈379px
(màn hình trừ padding), banner trong popup 220px xin đúng width=280px
(Material `Dialog` có sàn tối thiểu 280px riêng của Flutter — không phải
bug của SDK — và banner tự thích ứng đúng theo sàn đó thay vì màn hình
~379px). Không có exception layout nào (đúng bug thật task mô tả: trước
fix, banner sẽ xin ~379px cho khung chỉ có 280px và tràn ra ngoài).

**Tự chấm điểm: 9.5/10.** Trừ điểm vì: (1) phải sửa qua nhiều vòng
(LayoutBuilder ban đầu phá VisibilityDetector, phải đổi kiến trúc giữa
task) — không phải thiết kế sạch từ đầu; (2) chưa test thật trên
tablet/màn hình lớn (chỉ có điện thoại Pixel 7 Pro trong môi trường này).
