# T283 — Xác minh tích hợp package hosted trong app partner mẫu

- **Loại:** Verification / Partner integration
- **Priority:** P1 · **Severity:** MEDIUM
- **Confidence:** Evidence gap
- **Status:** done (2026-11-15; hosted 3.7.1 partner consumer smoke passed; scope is Android + AdMob only)
- **Evidence:** Baseline trước T283: consumer Flutter 3.41.9 từng analyze/build nhưng chưa cài APK và chưa lưu log. T283 sau đó đã chạy hosted 3.7.1, install/launch/banner smoke và lưu evidence như acceptance bên dưới; guide đã cập nhật. Round 79 example device evidence không thay thế consumer app; không đổi smoke này thành 3.7.4 khi chưa chạy hosted consumer lại.
- **Dependencies:** Flutter toolchain đáp ứng floor package đang publish; Android device; Google test App ID và test ad units

## Bối cảnh & vấn đề

SDK phát hành cho partner tích hợp. Partner guide ghi nhận một app Flutter mới đã chạy `flutter analyze` và build APK từ package hosted, nhưng không cài APK, không lưu log, và không chứng minh init/UMP/ad load trong app consumer độc lập. Smoke trên SDK example không chứng minh app partner theo integration contract dùng đúng cấu hình. Cần validation tái lập, không dùng host app thật hoặc ad inventory production.

## Phạm vi

1. Tạo app consumer disposable ngoài repo; dependency `applovin_admob_sdk` lấy từ pub.dev hosted source, không path dependency.
2. Dùng Google test App ID/test units; theo README contract: navigator key/observers, init trong splash, consent flow phù hợp và test-only provider config.
3. Build, cài, chạy trên Android device; xác nhận SDK init, AdMob adapter state, ít nhất một inline test ad hiển thị, không crash. Lưu `pubspec.lock`, lệnh, device/OS, log và ảnh.
4. Không dùng app ID `com.roy.admobwrapper`, không ghi production IDs/credentials vào repo; không sửa package source trong lúc chạy consumer test.
5. Nếu toolchain/UMP geography cản test, ghi blocker; không biến `notRequired` thành EEA proof.

## Acceptance criteria

- [x] Consumer resolves `applovin_admob_sdk 3.7.1` from hosted pub.dev; lockfile confirms `source: hosted`, URL `https://pub.dev`, SHA-256 `b775e3ca03c08adfa1fd5ae29c3b94681d8c70444f37aef0ef2febd807503342`.
- [x] Consumer `flutter analyze`, `flutter test`, and Android debug APK build pass. `flutter test` ran the disposable consumer's local widget smoke test; it is not SDK test-suite coverage.
- [x] Installed/launched on Samsung S24 Ultra `R5CX613VZBR` (SM-S928B, Android 17) using disposable application ID `com.roy.admobwrapper.t283smoke`. Logs confirm UMP `notRequired`, `initSuccess=true`, AdMob adapter init, consent applied, Banner and App Open load success. Screenshot shows Google 320x50 test banner with test-ad label. No `FATAL EXCEPTION` in captured fatal log.
- [x] Evidence saved under `/tmp/ad-sdk-smoke-t283/`: `pubspec.lock` SHA-256 `668b19287bbcad53cd83dfc540ee03803b0a12ea01f1c900761bb202cb2cba96`; APK SHA-256 `4d4d4a79639f9c74583e6b55cfa78cb9e5f9f7bada2e50503e7b67af1109daeb`; log SHA-256 `6d88fe440ed7d2d481c8051fe94c89471e329f555af4c4337f94466710c66952`; screenshot SHA-256 `41fa549e3e203946b9216cf22709940c21fffd6490ff0d9d61e7520ba063751a`. Fatal log is empty (SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
- [x] Smoke xác nhận Android partner integration path; không tuyên bố iOS, AppLovin, production inventory, EEA/legal setup hoặc host app thật.
- [x] SDK unit tests N/A: validation-only hosted consumer smoke; no SDK source changed. Consumer-local widget smoke passed as recorded above.
- [x] SDK widget/golden N/A: no SDK widget, rendering, or public API changed.
- [x] Interruption/network-conditioning, memory/profile, frame-jank, and mediation N/A: none were changed or claimed by this smoke. IAP remains host-owned and out of scope.
- [x] Used disposable application ID `com.roy.admobwrapper.t283smoke`; did not install over, clear, or uninstall `com.roy.admobwrapper`.

## Kế hoạch kiểm thử

- **Unit:** N/A for validation-only consumer smoke; no SDK code changed.
- **Widget:** N/A for SDK package; consumer template UI only displayed bootstrap status and SDK banner.
- **Integration:** Hosted dependency, AdMob test App ID/ad units, bootstrap/consent/provider init and banner surface passed on the consumer app.
- **Device smoke:** S24U, disposable ID, logs/screenshot and hashes saved; no ad click/CTA interaction.

## Prompt vòng lặp (Loop Prompt)

```markdown
Thực hiện T283 như partner release verification. Đọc ticket, `README.md`, `doc/AD_PROMPT_FLUTTER.MD` và integration-test README. Tạo disposable consumer project ngoài repo, resolve SDK từ hosted pub.dev (không path dependency), kiểm tra lockfile source/version. Dùng Google test App ID/ad units và application ID riêng; triển khai đúng README init/navigation/consent contract. Chạy analyze/build/install trên Android device, quan sát init + AdMob test ad callback/impression nếu có; lưu commands, lockfile, device/OS, logs, screenshot và SHA-256. Không chạm production inventory/credentials hoặc `com.roy.admobwrapper`; không tuyên bố EEA/iOS/AppLovin/host-app readiness. Nếu test không tái lập, ghi blocker thay vì pass. Với unit/widget/golden/interruption/network-conditioning/memory-profile/frame-jank/mediation/IAP, chạy lớp có thể bị ảnh hưởng; ghi N/A và lý do cho phần còn lại. IAP thuộc host app, ngoài SDK scope. Nếu xác nhận lỗi runtime, dừng validation-only và tạo regression ticket. Audit độc lập kết quả, score /10. Chỉ push khi có source change được yêu cầu, test áp dụng + device evidence pass, score >9/10; docs-only verification không push.
```
