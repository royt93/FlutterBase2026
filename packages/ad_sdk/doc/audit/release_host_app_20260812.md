# Phát hành host app 2026.08.12+20260812 — critical ad-dialog fix + backlog cleanup

**Version:** `2026.07.19+20260719` → `2026.08.12+20260812`.

## Tóm tắt

| Việc | Kết quả |
|---|---|
| `flutter analyze` (root + ad_sdk) | sạch, 0 issue |
| `flutter test` (root) | 175/175 pass |
| `flutter test` (ad_sdk) | 700/700 pass (không đổi so lần trước) |
| AdMob test App ID còn sót trong native config? | không — 0 match ở `AndroidManifest.xml`/`Info.plist` |
| Device smoke test (Pixel 7 Pro) | xem mục 3 |

Commit chính: `162fe30`, `c010a57`, `0d0e25a`.

## 1. Fix quan trọng nhất — AdLoadingDialog bị strand khi có modal race lên trên

`packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart`: dialog dùng `DialogRoute` +
`Navigator.removeRoute()` (identity-based) thay `Navigator.pop()` (pop nhầm route
đang ở trên cùng). Trước fix: 1 modal không liên quan (ví dụ bottom sheet gắn nhãn
phòng của WiFi stressor) race lên trên buffer dialog giữa lúc đang hiện → pop() đóng
nhầm modal, dialog bị strand vĩnh viễn trên màn hình, chặn UI. Verify: 3 AI review độc
lập + adversarial widget test (`ad_loading_dialog_test.dart`) + smoke thật trên Pixel 7
Pro (log `removeRoute` chạy sạch qua 1 chu kỳ ad thật). Không ép được đúng race gốc
live (buffer chỉ rộng ~1s, ADB timing không đủ chính xác) nhưng widget test cover đúng
path đó.

## 2. Backlog dọn trong chu kỳ này

17 ticket (P03,P04,P05,P06,P07,P13,P24,P25,P34,P36,P39,P42,P45,P46,P50,P53) +
3 ticket vòng audit sau (P35 nested `MaterialApp` gây theme conflict, P37 upload speed
không check HTTP status → báo Mbps giả, P38 schedule rollback không cancel alarm đăng
ký 1 phần) + 3 ticket dọn vì stale/đã fix ngầm (P08, P17, P26) → tổng 23 ticket đóng,
28 ticket còn lại trong `doc/task/todo/`.

Full audit trail: xem 3 report agent trong phiên chat (dialog fix, backlog regression
check, remaining-backlog re-prioritize) — không lưu file riêng, đã tổng hợp vào commit
message + mục này.

## 3. Device smoke test

Chạy trên Pixel 7 Pro (`2B051FDH3006MU`), APK debug build từ version `2026.08.12+20260812`.

- Gradle build cục bộ ban đầu fail (`Could not deserialize analysis from a file` —
  transform cache `~/.gradle/caches/8.13` hỏng, không liên quan code). Fix: `./gradlew
  --stop` + xoá `~/.gradle/caches/8.13` + build lại — không phải lỗi của app.
- Cold launch (`am start` sau khi cài) → HOME → resume (`am start` lại): không có
  `FATAL`/`AndroidRuntime` exception nào của `saigonphantomlabs`/`admobwrapper` trong
  logcat.
- Màn hình chính WiFi stressor render đúng theme tối (không còn theme đỏ của
  `MaterialApp` con cũ — xác nhận trực quan fix P35), banner ad load bình thường
  ("Quảng cáo thử nghiệm" — AdMob test creative, đúng vì đang test build, không phải
  production release).
- Không chạy full stress-test cycle (không cần lặp lại race-condition live re-test —
  đã đóng ở phiên trước, xem ghi chú trong task list).

## 4. Store listing check (native config)

- `AndroidManifest.xml`: có `com.google.android.gms.ads.APPLICATION_ID`,
  `applovin.sdk.key`, permission `AD_ID`/`INTERNET`/`ACCESS_NETWORK_STATE` — đủ.
- AdMob đang active (`AdProvider.admob` trong `splash_screen.dart`) và native config
  **không** còn App ID test của Google (`~3347511713`/`~1458002511`) — không bị
  `check-admob-test-id` cảnh báo.
- `android/local.properties` (gitignored) sẽ tự sync `flutter.versionName`/
  `flutter.versionCode` từ `pubspec.yaml` ở lần `flutter build` kế tiếp — không cần
  sửa tay.
- Chưa kiểm tra Play Console / App Store Connect listing text (screenshot, mô tả) —
  ngoài phạm vi repo, cần làm thủ công nếu muốn cập nhật.
