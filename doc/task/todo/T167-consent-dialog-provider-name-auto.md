# T167 — Hộp thoại xin phép quảng cáo ghi sai tên đối tác khi app chỉ dùng 1 mạng

**Loại:** enhancement (đúng sự thật cho người dùng)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent consent+compliance
**Quyết định chủ dự án (2026-09-08):** Tự động theo cấu hình app (không chỉ ghi chú tài liệu)

## Vấn đề (giải thích thực tế)
Hộp thoại xin phép quảng cáo (GDPR) luôn ghi cứng dòng chữ "Ad partners: Google AdMob, AppLovin" — kể cả khi app chỉ thật sự dùng 1 trong 2 (ví dụ chỉ Google). Nếu không chỉnh, dòng chữ này nói sai sự thật với người dùng về việc ai đang nhận dữ liệu của họ, sai lệch so với thực tế xử lý dữ liệu.

Chủ dự án chọn phương án tự động thay vì chỉ ghi chú tài liệu cho dev tự nhớ đổi — nghĩa là hộp thoại phải tự nhận diện app đang dùng mạng nào và hiển thị đúng.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/consent/consent_dialog_strings.dart:16` — `adPartnersLabel` mặc định cứng `'Ad partners: Google AdMob, AppLovin'`, không phụ thuộc `AdConfig.provider` thực tế.

## Việc cần làm
1. Sửa `adPartnersLabel` (hoặc nơi nó được dùng trong `consent_dialog.dart`) để tự sinh danh sách đối tác dựa vào `AdConfig.provider` thực tế (chỉ AdMob / chỉ AppLovin / cả 2).
2. Giữ khả năng dev override thủ công nếu họ cần custom message khác (không phá vỡ tính linh hoạt hiện có).
3. Viết test: app config chỉ AdMob → dialog chỉ hiện "Google AdMob"; app config cả 2 → hiện cả 2 tên; app custom override → dùng đúng string dev cung cấp.
4. Cập nhật CHANGELOG.md và README.md (mục consent dialog).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/consent/consent_dialog_strings.dart dòng ~16: adPartnersLabel mặc định cứng 'Ad partners: Google AdMob, AppLovin' bất kể AdConfig.provider thực tế. Sửa để tự sinh danh sách đối tác dựa vào AdConfig.provider (kiểm tra giá trị enum admob/applovin/cả 2) khi dev KHÔNG tự override string này — nếu dev đã tự set custom string thì vẫn dùng đúng string đó, không ghi đè. Đọc consent_dialog.dart để biết chỗ gọi/dùng label này. Viết widget test cho 3 case: chỉ AdMob, chỉ AppLovin, cả 2 — xác nhận dòng chữ hiển thị đúng từng case; và case dev tự custom override vẫn giữ nguyên string của dev.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho cả 3 case cấu hình provider + case custom override.
3. CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device với app mẫu cấu hình chỉ 1 provider, mở hộp thoại consent, chụp bằng chứng dòng chữ đúng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
