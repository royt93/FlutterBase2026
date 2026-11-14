Bằng chứng chạy Stages 1 đến 7 của Walkthrough trên Pixel 7 Pro (2026-11-14)
Thiết bị: Google Pixel 7 Pro (serial 2B051FDH3006MU, Android 16)
App: Tạo mới bằng `flutter create`, cài tạm với applicationId `com.roy.admobwrapper.walkthrough`.
SDK: 3.7.1 từ pub.dev. Quảng cáo: Google test ad units.

PASS — Stage 1: Flutter 3.41.9, Android toolchain sẵn sàng.
PASS — Stage 2: `dart pub add applovin_admob_sdk:3.7.1`; pubspec ghi đúng `3.7.1`.
PASS — Stage 3: edits 1–4, thêm applicationId riêng theo yêu cầu test. Regex thay minSdk ban đầu sinh `24.minSdkVersion`; đã sửa thành `minSdk = 24` trước khi build.
PASS — Stage 4: permissions và Google test App ID. Test App ID chỉ dùng trong app tạm.
PASS — Stage 5: 5 snippet Dart. Lần đầu analyzer/build FAIL vì snippet privacy_screen.dart được chép sai, dùng method không tồn tại `showPrivacyOptionsForm`. Đã đọc đúng snippet Step 8.1, thay bằng `showPrivacyOptions()`, chạy lại build thành công. Không sửa guide trong quá trình test.
PASS — Stage 6: `flutter analyze` sạch; `flutter build apk --debug` tạo APK 160 MB.
PASS — Stage 7, một phần: Splash -> Home; Google test banner hiện (`home.png`); rewarded test ad hiện (`rewarded_ad_showing.png`), log `🏆 type=coins amount=10`, UI tăng từ 0 lên 10 (`home_after_reward.png`); interstitial test ad hiện (`interstitial_ad_showing.png`). Log không có FATAL EXCEPTION. App tạm đã gỡ.
NOT VERIFIED — Màn PrivacyScreen: `privacy_screen.png` chụp trước khi interstitial đóng; không có ảnh xác nhận màn PrivacyScreen.

Chưa chạy:
- Stage 8 (UMP EEA): NOT RUN.
- Stage 9 (Wi-Fi offline/online): NOT RUN.
- Stage 10 (release build): NOT RUN.
- PrivacyScreen sau khi đóng interstitial: NOT VERIFIED.

Bảo vệ app chủ: danh sách gói trước cài và sau gỡ đều chỉ có `package:com.roy.admobwrapper`; app tạm là `com.roy.admobwrapper.walkthrough`, đã gỡ. Xem `packages_before.txt`, `packages_after_uninstall.txt`.

Lưu ý: Đây là một lượt thử app mới trên một thiết bị. Không phải kiểm định partner app hoặc production ad units. `logcat_filtered.txt` chứa log đã lọc; raw log không được lưu vào repo.
