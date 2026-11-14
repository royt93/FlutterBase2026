Bằng chứng chạy walkthrough trên Pixel 7 Pro (2026-11-14)
Thiết bị: Google Pixel 7 Pro (serial 2B051FDH3006MU, Android 16)
App: Tạo mới bằng `flutter create`, cài tạm với applicationId `com.roy.admobwrapper.walkthrough`.
SDK: 3.7.1 từ pub.dev. Quảng cáo: Google test ad units.

PASS — Stage 1: Flutter 3.41.9, Android toolchain sẵn sàng.
PASS — Stage 2: `dart pub add applovin_admob_sdk:3.7.1`; pubspec ghi đúng `3.7.1`.
PASS — Stage 3: edits 1–4, thêm applicationId riêng theo yêu cầu test. Regex thay minSdk ban đầu sinh `24.minSdkVersion`; đã sửa thành `minSdk = 24` trước khi build.
PASS — Stage 4: permissions và Google test App ID. Test App ID chỉ dùng trong app tạm.
PASS — Stage 5: 5 snippet Dart. Lần đầu analyzer/build FAIL vì snippet privacy_screen.dart được chép sai, dùng method không tồn tại `showPrivacyOptionsForm`. Đã đọc đúng snippet Step 8.1, thay bằng `showPrivacyOptions()`, chạy lại build thành công. Không sửa guide trong quá trình test.
PASS — Stage 6: `flutter analyze` sạch; `flutter build apk --debug` tạo APK 160 MB.
PASS — Stage 7, một phần: Splash → Home; Google test banner hiện (`home.png`); rewarded test ad hiện (`rewarded_ad_showing.png`), log `🏆 type=coins amount=10`, UI tăng từ 0 lên 10 (`home_after_reward.png`); interstitial test ad hiện (`interstitial_ad_showing.png`). PrivacyScreen sau khi đóng interstitial xác nhận tại `stage89/privacy_options_screen.png`. Log không có FATAL EXCEPTION. App tạm đã gỡ.
PASS — Stage 8: UMP EEA debug test trên Pixel. Lượt đầu không đăng ký hash trả `notRequired`; Google log cho hash `9005AD1E37B82BBBCF70A3B34C485083`. Sau thêm hash vào `umpTestIdentifiers`, form hiện (`stage89/ump_eea_consent_form.png`). Consent: `status=obtained`, `canRequestAds=true`, `nonPersonalizedAds=false`. Do not consent: `status=obtained`, `canRequestAds=true`, `nonPersonalizedAds=true`. Mở Privacy Options lại form rồi chọn Consent đổi `nonPersonalizedAds` về false. Ảnh, log, build/analyze và giới hạn từng bước ở `stage89/README.txt`.
PASS (specific cold-start path only) — Stage 9: With Wi-Fi off, force-stopped and relaunched throwaway app. UMP update failed with `2:Error making request.`, banner lookup was aborted by reload gate, and interstitial load skipped with `no network`. After Wi-Fi returned, SDK logged `network back online → refilling ad slots + banners`, banner load succeeded and banner was visible (`stage89/cold_start_reconnected_banner.png`). This verifies one cold-start recovery path on one Pixel with test inventory, not every network condition.
NOT RUN — Stage 10: release build.

Bảo vệ app chủ: `packages_before.txt` và `packages_after_uninstall.txt` xác nhận chỉ `package:com.roy.admobwrapper` trước/sau Stage 1–7. Ở lượt bổ sung, danh sách trước cleanup gồm cả app tạm; sau đó chỉ còn `package:com.roy.admobwrapper`. Wi-Fi kết thúc ở `1` (on). Lệnh uninstall bổ sung trả `DELETE_FAILED_INTERNAL_ERROR` vì app tạm đã không còn cài tại thời điểm gọi; danh sách xác nhận app tạm vắng mặt.

Lưu ý: Một lượt thử trên một thiết bị, không phải kiểm định partner app hoặc production ad units. Logs đã lọc; raw log không lưu trong repo.

Two additional 30-second intervals with an already-loaded banner had no observed SDK load/refill/error while offline, but did not prove new-ad recovery. The separate cold-start path above did prove banner recovery after reconnect.

Stage 9 cold-start recovery passed on one Pixel test path; see stage89/cold_start_* evidence.
