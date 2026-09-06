# T131 — Enhancement: Tích hợp AppLovin bản Trung Quốc (China SDK)

- **REQ:** phát sinh từ đánh giá "go global" (2026-09-06, hỏi trực tiếp về khả
  năng release toàn cầu của `applovin_admob_sdk:^2.9.19/2.9.20`) — xem
  `doc/audit/audit_round41.md`. User chọn hướng "chỉ AppLovin cho TQ, tắt
  AdMob" (không thêm network nội địa TQ khác), và chọn "research + viết kế
  hoạch trước", chưa code.
- **Priority:** P3 (backlog, chưa launch TQ) · **Status:** 🔲 todo
- **Files (dự kiến, chưa xác nhận):** `lib/src/config/ad_config.dart`
  (thêm provider/flavor detection), `lib/src/adapter/applovin_adapter.dart`,
  `android/`/`ios/` build config (flavor riêng cho TQ), `pubspec.yaml`
  (`applovin_max` có build variant TQ riêng không, hay cùng package khác
  cấu hình native)

## Vấn đề

Ở Trung Quốc đại lục:
- **AdMob không chạy được** — phụ thuộc Google Play Services, bị chặn bởi
  GFW trên hầu hết ROM Android bán ở TQ (Huawei/Xiaomi/Oppo/Vivo không cài
  sẵn GMS).
- **AppLovin có SDK/luồng tích hợp riêng cho thị trường TQ** (không dùng
  GMS, thường cần app store TQ riêng — Huawei AppGallery/Xiaomi/Tencent
  MyApp thay vì Google Play — và có thể cần cấu hình mediation/CDN khác).
- SDK này (`applovin_admob_sdk`) hiện là **dual-provider chung 1 codepath**
  — chưa có flavor/build variant riêng cho TQ, chưa test trên ROM TQ thật.

**Ngoài phạm vi code — user phải tự lo, KHÔNG thể làm thay qua session này:**
- **ICP filing (备案)** — bắt buộc theo luật TQ cho app/website hoạt động
  tại TQ, là thủ tục hành chính/pháp lý với nhà mạng/chính quyền TQ, không
  phải việc code.
- Đăng ký tài khoản + submit lên các app store TQ (Huawei AppGallery,
  Xiaomi, Oppo, Vivo, Tencent MyApp...) — Google Play không hoạt động ở TQ.
- Cân nhắc yêu cầu lưu trữ dữ liệu nội địa TQ (PIPL) nếu app thu thập dữ
  liệu người dùng TQ — có thể cần hạ tầng server riêng, ngoài phạm vi SDK
  quảng cáo.

## Việc cần làm (khi bắt đầu — hiện CHƯA làm, đây là checklist cho lần sau)

- [ ] Đọc tài liệu chính thức AppLovin cho thị trường Trung Quốc (China SDK
      / MAX China) — xác nhận: có phải SDK native khác hẳn bản global
      không, hay chỉ khác cấu hình mediation?
- [ ] Xác định: cần build flavor Android riêng (`productFlavors` trong
      `android/app/build.gradle` của app tiêu thụ, KHÔNG phải trong package
      SDK này) để loại bỏ hoàn toàn `google_mobile_ads`/GMS dependency cho
      biến thể TQ không?
- [ ] Thiết kế cách `AdConfig`/`AdManager` chọn provider theo build
      flavor/target thay vì hard-code — có thể chỉ cần đảm bảo
      `AdProvider.appLovin` hoạt động độc lập hoàn toàn không đụng gì tới
      `google_mobile_ads` khi flavor TQ build (grep xem có import
      `google_mobile_ads` nào bị kéo vào transitively không tránh được).
- [ ] Test thật trên thiết bị Android ROM TQ (Huawei/Xiaomi thật, không
      GMS) — xác nhận app không crash khi thiếu GMS hoàn toàn (nhiều thư
      viện khác ngoài ads — Firebase, v.v — cũng có thể ngầm phụ thuộc GMS,
      cần audit riêng toàn bộ `pubspec.yaml` của app tiêu thụ, không chỉ
      SDK quảng cáo này).
- [ ] Viết mục riêng trong README (hoặc file mới `doc/CHINA_SETUP.md` theo
      đúng convention `SPLASH_SETUP.md`/`UMP_SETUP.md` đã có) hướng dẫn
      host app cách bật biến thể TQ.

## Ghi chú

Đây là **enhancement lớn, không phải bug** — SDK hiện tại hoạt động đúng
thiết kế cho các thị trường có GMS (đại đa số thế giới). Việc này chỉ cần
làm khi thực sự quyết định launch tại Trung Quốc đại lục. Ước tính effort
thật (native build variant + test thiết bị TQ + docs) lớn hơn nhiều so với
1 ticket đơn — có thể cần tách thành nhiều ticket con khi bắt đầu (native
build config, test device, docs) thay vì làm 1 lượt.
