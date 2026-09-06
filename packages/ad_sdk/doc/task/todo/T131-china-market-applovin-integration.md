# T131 — Enhancement: Chuẩn bị monetization AppLovin cho thị trường Trung Quốc

- **REQ:** phát sinh từ đánh giá "go global" (2026-09-06, hỏi trực tiếp về khả
  năng release toàn cầu của `applovin_admob_sdk:^2.9.19/2.9.20`) — xem
  `doc/audit/audit_round41.md`. User chọn hướng "chỉ AppLovin cho TQ, tắt
  AdMob", và chọn "research + viết kế hoạch trước", chưa code.
- **Priority:** P3 (backlog, chưa launch TQ) · **Status:** 🔲 todo
- **Cập nhật 2026-09-06 (research pass):** research ban đầu (round trước) nói
  "AppLovin cần SDK riêng cho TQ" — **KHÔNG chính xác**, đã research lại kỹ
  hơn bằng web search thật, xem phần "Research findings" bên dưới. Sửa lại
  toàn bộ mô tả vấn đề + việc cần làm cho khớp thực tế.

## Research findings (2026-09-06, verified qua search — chưa test thật)

**Điều ĐÚNG (giữ nguyên từ đánh giá trước):**
- AdMob **không chạy được** ở TQ đại lục — phụ thuộc Google Mobile Ads +
  Google Play Services đầy đủ, bị chặn bởi GFW, hầu hết ROM Android bán ở TQ
  (Huawei/Xiaomi/Oppo/Vivo) không cài sẵn GMS.

**Điều đã SỬA (research trước sai):**
- **AppLovin KHÔNG có một "SDK riêng cho Trung Quốc" tách biệt khỏi bản
  global.** Cùng 1 SDK MAX (`applovin_max` package hiện tại), không cần đổi
  sang bản khác.
- SDK core của AppLovin **có phụ thuộc nhẹ vào 1 module GMS** —
  `com.google.android.gms:play-services-ads-identifier` (chỉ để đọc Google
  Advertising ID/AAID) — không phải toàn bộ Google Play Services stack như
  AdMob cần. Trên thiết bị không có GMS, việc đọc AAID thường fail-safe (trả
  null/bỏ qua) thay vì crash — đây là pattern chuẩn mọi SDK quảng cáo phải
  xử lý (thiết bị Amazon Fire, TQ, v.v. vốn không có GMS từ trước). **Chưa
  tự verify điều này bằng test thật trên thiết bị TQ** — chỉ dựa trên hiểu
  biết chung về cách AAID thường được xử lý, cần confirm ở bước test.
- **Việc thật cần làm cho TQ là ở tầng MEDIATION NETWORK, không phải core
  SDK:** Pangle (ByteDance, mediation network AppLovin hỗ trợ) đã **ngừng
  phục vụ traffic Trung Quốc đại lục** từ 1 phiên bản adapter nhất định trở
  đi. Để kiếm tiền từ traffic TQ, cần cấu hình thêm **CSJ** (network TQ nội
  địa của ByteDance, tương đương Pangle nhưng dành riêng cho thị trường TQ)
  làm mediation network thay thế/bổ sung — traffic ngoài TQ vẫn dùng Pangle
  bình thường.
- Chưa tìm thấy tài liệu AppLovin nào yêu cầu build flavor/variant Android
  riêng cho TQ ở tầng AppLovin — nghi ngờ ban đầu về việc này phần lớn
  không cần thiết, **nhưng chưa xác nhận 100%** (search không tìm ra trang
  "China integration guide" cụ thể của AppLovin, có thể tài liệu không công
  khai đầy đủ, cần hỏi trực tiếp AppLovin support nếu làm thật).

**Nguồn:** search qua AppLovin support center (`support.applovin.com` /
`support.axon.ai` — AppLovin dường như đang rebrand docs sang domain
"Axon by AppLovin", cả 2 domain đều còn hoạt động, redirect qua lại) +
tài liệu công khai về Pangle/CSJ switch. Chưa fetch được trang "China
integration" cụ thể (bị 404/redirect vòng vòng) — thông tin trên tổng hợp
từ search snippet, **nên tự verify lại trực tiếp trên trang AppLovin support
trước khi bắt tay code thật**, đừng chỉ tin ticket này.

## Vấn đề (đã cập nhật)

Nếu launch tại TQ đại lục:
1. Phải **tắt AdMob provider** cho traffic/build TQ (không chạy được, không
   phải tuỳ chọn).
2. Nếu muốn kiếm tiền tốt từ traffic TQ qua AppLovin, cần **thêm CSJ
   mediation adapter** (network TQ nội địa) — không phải đổi cả SDK.
3. Vẫn cần: ICP filing, đăng ký app store TQ (Huawei AppGallery/Xiaomi/Oppo/
   Vivo/Tencent MyApp — Google Play không hoạt động ở TQ) — **hoàn toàn
   ngoài phạm vi code, user tự lo, không thể làm thay qua session.**
4. Cân nhắc PIPL (lưu trữ dữ liệu nội địa TQ nếu thu thập dữ liệu người
   dùng TQ) — có thể cần hạ tầng server riêng, ngoài phạm vi SDK quảng cáo.

## Việc cần làm (khi bắt đầu — hiện CHƯA làm, checklist cho lần sau)

- [ ] Verify trực tiếp với AppLovin support (hoặc rep tài khoản AppLovin
      nếu có) — xác nhận chính xác: MAX SDK core có hoạt động bình thường
      trên thiết bị hoàn toàn không GMS không (không chỉ suy luận từ AAID
      module), và CSJ adapter setup chính xác thế nào.
- [ ] Thêm CSJ adapter vào cấu hình mediation của app tiêu thụ (KHÔNG phải
      trong package SDK này — pinning wall/mediation adapter là việc ở tầng
      consuming app theo đúng convention CLAUDE.md đã ghi).
- [ ] Thiết kế cách app tiêu thụ tắt AdMob cho build/traffic TQ — có thể chỉ
      cần `AdConfig(provider: AdProvider.appLovin)` sẵn có, không cần
      code mới trong SDK này (dual-provider đã hỗ trợ chọn 1 provider từ
      trước — kiểm tra lại xem có đúng vậy không trước khi giả định cần
      code mới).
- [ ] Test thật trên thiết bị Android ROM TQ (Huawei/Xiaomi thật, không
      GMS) — xác nhận app không crash khi thiếu GMS hoàn toàn (audit riêng
      toàn bộ `pubspec.yaml` của app tiêu thụ xem có dependency nào khác
      — Firebase, v.v — ngầm cần GMS không, ngoài phạm vi AppLovin/AdMob).
- [ ] Nếu mọi thứ xác nhận không cần code mới trong SDK này (nhiều khả
      năng đúng vậy dựa trên research) — chỉ cần viết hướng dẫn setup vào
      README hoặc file mới `doc/CHINA_SETUP.md` (đúng convention
      `SPLASH_SETUP.md`/`UMP_SETUP.md` đã có), không cần sửa code SDK.

## Ghi chú

Sau research, effort thật **có thể nhỏ hơn nhiều** so với ước tính ban đầu —
nghi ngờ chính "cần build flavor/SDK riêng" chưa được xác nhận là đúng.
Việc lớn nhất thực ra nằm ngoài code (ICP filing, app store TQ, CSJ
mediation account). Đừng bắt đầu code cho tới khi bước verify-với-AppLovin-
support ở trên xác nhận rõ ràng KHÔNG cần thay đổi gì trong SDK/build
config trước.
