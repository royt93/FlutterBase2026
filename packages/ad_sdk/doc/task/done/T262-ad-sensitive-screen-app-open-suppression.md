# T262 — Chặn App Open Ads Trên Các Màn Hình Nhạy Cảm (Thanh Toán, Đăng Nhập, Camera)

- **Loại:** Enhancement / UX & Policy
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (verified again 2026-10-23; TECNO integration 1/1 pass after fixing async event wait; full SDK suite 2,753/2,753 pass)

## Bối cảnh & Vấn đề

App Open Ad tự động hiển thị khi người dùng chuyển từ ứng dụng khác quay lại (app resume):
- Mặc dù SDK đã có cơ chế `isDialogOnTop` và `isCustomOverlayOnScreen` để tránh chèn ad lên popup, nhưng trên các màn hình đặc thù có tính chất nhạy cảm cao:
  - Màn hình thanh toán (VNPAY, Momo, Stripe, IAP checkout).
  - Màn hình quét QR / Camera đang hoạt động.
  - Màn hình nhập mã OTP / mật khẩu ngân hàng.
- Khi người dùng chuyển sang app ngân hàng để lấy mã OTP rồi quay lại, App Open Ad bất ngờ nhảy ra che khuất màn hình. Điều này vừa gây ức chế tột độ, vừa có nguy cơ vi phạm chính sách của Google về việc quảng cáo gây gián đoạn luồng tác vụ quan trọng của người dùng.

## Giải pháp triển khai

- Host bọc flow nhạy cảm bằng `AdSensitiveScreen(child: ...)`; SDK không tự đoán màn nào đang checkout, mở camera, nhập OTP hoặc mật khẩu.
- App Open resume bị bỏ qua khi ít nhất một wrapper còn mount. Wrapper cuối cùng dispose thì resume behavior trở lại bình thường. Nếu wrapper nằm bên dưới route khác, gate vẫn đóng; đây là lựa chọn fail-safe có thể suppress thêm.
- Gate được kiểm tra ngay khi resume và kiểm tra lại trong loading-buffer callback/fallback timer, tránh route nhạy cảm xuất hiện trong lúc chờ mà ad vẫn bật lên.
- Không chặn Interstitial, Rewarded hoặc các fullscreen format khác.

## Acceptance Criteria

- [x] `AdSensitiveScreen` public wrapper giữ gate hoạt động qua nhiều/nested wrapper và xóa gate khi wrapper cuối cùng dispose.
- [x] App Open resume bị chặn trước show/refill khi sensitive screen đang mount; normal resume trở lại khi wrapper đã dispose.
- [x] Loading-buffer và fallback-timer callback recheck sensitive state trước presentation.
- [x] `flutter analyze` sạch; focused observer/manager/API-golden tests pass.
- [x] TECNO KJ7 integration test pass với AdMob test IDs; xác nhận log `App Open skipped — active route is marked as sensitive`.
- [x] Full SDK suite re-run 2026-10-23: 2,753/2,753 pass. Release size gate pass at 2048 KB after reducing only the new wrapper doc comment to keep its tracked file below the next `du -k` block; behavior and gate threshold unchanged.

## Kế hoạch kiểm thử và evidence

- Widget lifecycle: `test/ad_route_observer_test.dart` — nhiều wrapper, unmount cuối, normal state.
- Unit/widget resume: `test/ad_manager_core_test.dart` — direct skip, fallback timer race, loading-buffer race, resume sau khi sensitive screen đóng.
- Public API: `test/api_golden_test.dart`; golden cập nhật cho `AdSensitiveScreen`.
- Device integration: `example/integration_test/t262_sensitive_screen_blocks_appopen_test.dart`, chạy trên TECNO KJ7 Android 14 ngày 2026-10-22; pass, dùng test IDs, debug first-install grace disabled. Test log xác nhận sensitive gate; route bình thường sau đó không còn sensitive skip. Không claim ad được show vì slot không ready/consent không coverage.
- Reverification 2026-10-23: focused SDK manager/observer/API-golden coverage **305/305 pass**; sensitive-screen group **4/4 pass**; full SDK suite **2,753/2,753 pass**; `flutter analyze --no-pub` clean; release size gate passed (ceiling unchanged).
- Integration race found and fixed in the test only: a single `pump()` did not wait for `_resumeAdWorkAfterConsent()` and async `events` delivery, so one TECNO run checked `skips` too early and failed at the sensitive-skip assertion. The test now subscribes before lifecycle resume and awaits the matching `sensitive_screen` event with a 10s timeout inside `tester.runAsync()`. SDK consent/safety guards were not changed. Final TECNO KJ7 Android 14 run **1/1 pass**, log `/tmp/t262_tecno_final_check.log`; earlier event-wait verification also passed (`/tmp/t262_tecno_event_wait_verify.log`). These tests exercise a mounted wrapper and synthetic lifecycle transitions on device, not a real bank/camera app round trip or a loaded App Open impression after leaving the sensitive route. No actual ad-show success is claimed while the slot is idle or consent coverage absent.
- Real background/foreground smoke 2026-10-23: `example/integration_test/t262_sensitive_real_appopen_test.dart` passed on TECNO KJ7 Android 14 with Google test IDs, UMP requested before init, and normal safety enabled. The test requires `canRequestAds=true` and an App Open slot at `ready`; missing fill fails rather than silently passing. Host ADB Home/relaunch while payment was mounted produced `sensitive_screen`, left the slot ready, and emitted no show event. After wrapper disposal, the first normal resume was correctly blocked by the cold-start one-shot; a second normal Home/relaunch presented the native test ad. UIAutomator showed `Test Ad` and `Continue to app`; tapping the observed close control delivered a successful App Open show/dismiss event. Final run passed 1/1; log `/tmp/t262_host_lifecycle_tecno_retry.log`. The first host-driven attempt failed because it expected show on the cold-start-blocked resume; no SDK or safety bypass was added.
- Host-assisted test is opt-in: `flutter test integration_test/t262_sensitive_real_appopen_test.dart -d <TECNO-device-id> --dart-define=T262_HOST_LIFECYCLE=true`. At `T262_HOST sensitive_ready`, send Home, wait for background, and relaunch the existing activity. At `T262_HOST normal_ready`, repeat; if the cold-start guard blocks that resume, perform another Home/relaunch. At `T262_HOST showing`, dismiss using the observed native test-ad close control. Default suite skips this host-assisted case. This verifies real OS lifecycle with a test payment screen, not a third-party banking/camera application or iOS.
- Local logs: `/tmp/t262_unit_verify.log`, `/tmp/t262_full_sdk_test.log`, `/tmp/t262_analyze.log`, `/tmp/t262_size.log` (local, not committed).
- Example usage: `AdSensitiveScreen(child: CheckoutPage())` (cùng cách dùng cho camera/OTP/password flows).

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T262 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/ad_screen_route_logger.dart, lib/src/core/ad_manager.dart.
2. Viết test trước để kiểm tra chặn App Open trên màn nhạy cảm (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
