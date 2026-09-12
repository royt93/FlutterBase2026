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

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** Hộp thoại xin phép quảng cáo
(GDPR) luôn ghi "Ad partners: Google AdMob, AppLovin" — nhưng thật ra SDK
này CHỈ CHO PHÉP app dùng ĐÚNG 1 trong 2 mạng tại 1 thời điểm (không bao
giờ dùng cả 2 cùng lúc, đã xác minh qua code thật) — nghĩa là dòng chữ
này nói sai với 100% app dùng SDK, không phải trường hợp hiếm. Giờ hộp
thoại tự nhận diện đúng app đang dùng mạng nào (AdMob hoặc AppLovin) và
chỉ ghi đúng tên đó.

**Kỹ thuật đã sửa:**
- `consent_dialog_strings.dart`: default của `adPartnersLabel` đổi từ
  chuỗi cứng sang chứa token `{providers}`
  (`ConsentDialogStrings.autoProvidersToken`).
- `consent_dialog.dart`: `showConsentDialog` nhận thêm tham số
  `autoProviderNames` — nếu label có token, thay token bằng tên mạng thật;
  nếu dev tự set string riêng KHÔNG có token, giữ nguyên (không ghi đè).
- `consent_manager.dart`: thêm `noteProvider()` + field nhớ provider đã
  biết gần nhất; `showDialog()` dùng nó để tính `autoProviderNames`.
- `ad_manager.dart`: gọi `consentMgr.noteProvider(config.provider)` NGAY
  SAU init thành công (không điều kiện) — không chỉ khi hộp thoại
  auto-show thật sự chạy.

**Kết quả review độc lập (`codex review --uncommitted`, 2 vòng):**
- Vòng 1: sạch.
- Vòng 2: phát hiện 1 lỗ hổng thật — nếu người dùng cũ (đã trả lời
  consent từ phiên TRƯỚC) mở lại hộp thoại từ màn hình Cài đặt riêng của
  app (cách dùng có tài liệu, không cần truyền `config`), và phiên HIỆN
  TẠI chưa từng gọi `showDialog` kèm config lần nào (vì auto-show bị bỏ
  qua khi đã hỏi rồi) — dòng chữ vẫn quay lại ghi cả 2 tên. Sửa bằng cách
  gọi `noteProvider()` ngay lúc init xong, không đợi đến lúc hộp thoại
  thật sự hiện ra. Có test riêng cho đúng kịch bản này.

**Test coverage:**
- `test/consent_dialog_widget_test.dart`: thêm 5 test — chỉ AdMob, chỉ
  AppLovin, không truyền gì (giữ hành vi cũ, tương thích ngược), custom
  string không có token giữ nguyên, custom string CÓ token vẫn được thay
  thế đúng.
- `test/consent_manager_test.dart`: thêm 3 test — provider admob, provider
  appLovin, và kịch bản "re-show không kèm config" (đúng lỗ hổng codex
  vòng 2 tìm ra).
- Không sửa/breaking test cũ nào trong toàn bộ file liên quan consent.
- Full SDK suite: 1865 test xanh.
- Full example suite: 43 test xanh.
- CHANGELOG.md + README.md cập nhật.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** file mới
`example/integration_test/r167_consent_dialog_provider_name_test.dart` —
gọi trực tiếp `ConsentManager.showDialog` thật (qua `AdManager().consentManager`
thật, đã init thật) để không phụ thuộc trạng thái "đã hỏi chưa" có thể
sai lệch giữa các lần chạy test trên cùng thiết bị. Chạy 2 lần: 1 lần với
`--dart-define=AD_PROVIDER_ADMOB=true` (chỉ AdMob) — xác nhận đúng "Ad
partners: Google AdMob"; 1 lần mặc định (chỉ AppLovin) — xác nhận đúng
"Ad partners: AppLovin". Cả 2 lần PASS.

**Tự chấm điểm: 9.5/10.**
