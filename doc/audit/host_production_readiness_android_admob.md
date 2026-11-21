# Production readiness — Android + AdMob host

Dùng trang này cho **quyết định mở rollout production** sau pilot. Đây không phải kết quả kiểm định của SDK và không thay `host_pilot_quickstart_android_admob.md` (staging/test) hay `pilot_checklist_android_admob.md` (các gate kỹ thuật).

## 1. Bắt buộc trước rollout

- [ ] **Release đã duyệt:** xác nhận version SDK, `source: hosted`, checksum/archive từ nguồn tin cậy và release note. Không dùng local path/dependency override.
- [ ] **App/publisher ownership:** package name, AdMob App ID trong manifest, ad unit IDs, domain + `app-ads.txt`, UMP message/privacy URL đều thuộc đúng publisher/app và đã publish/active.
- [ ] **Build thật:** release-signed artifact, R8/ProGuard, `minSdk >= 24`, Kotlin Gradle Plugin `>= 2.3.0`; cold install, upgrade từ bản trước và rollback artifact đã chuẩn bị. Google test IDs không được nằm trong release config.
- [ ] **Consent:** UMP là consent owner; ordering ATT/UMP/init phù hợp audience/region; privacy options mở lại được; ad requests tuân gate và non-personalized outcome khi user từ chối consent quảng cáo cá nhân hóa. Không suy ra legal compliance chỉ từ test geography.
- [ ] **Ad UX:** placements được chủ sản phẩm/publisher duyệt, không đặt nơi dễ click nhầm; App Open không chồng dialog/VIP, cold-start skip được tính đến; interstitial có điểm chuyển cảnh hợp lý; rewarded chỉ cấp quyền lợi khi `earned == true`; SSV có thể dùng cho rewarded thường nếu server cần xác thực (không áp dụng cho Rewarded Interstitial của SDK này).
- [ ] **Host handling:** timeout `clearSdkData()` là `TimeoutException`/**chưa xác nhận xóa**, không phải success; retry xếp sau storage đang kẹt. Host không được báo xóa thành công khi Future timeout.
- [ ] **Pilot sign-off:** host hoàn tất quickstart/checklist trên đúng app + release-shaped build với test ads; mọi mục ghi `PASS`/`FAIL`/`NOT RUN`, owner chấp nhận từng `NOT RUN` và rủi ro còn lại trước mở rộng.

## 2. Giám sát và rollback

- [ ] Định nghĩa baseline trước rollout: crash/ANR, load success/failure/error-code theo format, impressions, reward `earned`, consent outcome, request volume và server-side revenue (nếu dùng).
- [ ] Alert/rollback owner, ngưỡng, rollout cohort và thời gian đánh giá do publisher chọn; ghi ai có quyền dừng ad serving.
- [ ] Rollout theo cohort nhỏ, tăng dần chỉ khi không có no-go. Test ads không dự đoán fill/revenue production; đánh giá bằng telemetry host + cảnh báo AdMob, không bằng một screenshot.
- [ ] Telemetry tối thiểu, host-owned: aggregate ngắn hạn; không log/upload GAID/IDFA, raw TCF/consent string, user-level timeline, auth token hoặc dữ liệu thanh toán. Đặt retention/access/deletion owner trước pilot.

## 3. Dừng rollout nếu

Crash/ANR tăng rõ; request trước consent gate; ad xuất hiện khi VIP/trial/dialog guard đáng ra phải chặn; reward cấp khi `earned=false`; policy/invalid-traffic warning; click nhầm; host báo xóa dữ liệu thành công sau timeout; hoặc không thể phân biệt lỗi release với cấu hình/consent của host.

## 4. Kết quả ký nhận

| Owner | Tên/nhóm | Quyết định | Ngày |
|---|---|---|---|
| Host engineering | | GO / NO-GO | |
| Product / monetization | | GO / NO-GO | |
| Privacy / compliance (nếu áp dụng) | | GO / NO-GO | |
| On-call / rollback owner | | GO / NO-GO | |

Ghi link artifact/checklist/log đã redacted và mọi giới hạn chưa xác minh; không ghi dữ liệu cá nhân vào bảng ký nhận.
