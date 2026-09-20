# Audit round 68 — báo cáo độc lập (nguồn: agy / Gemini 3.1 Pro)

## Phương pháp
Quá trình audit tập trung vào 6 yêu cầu chức năng cốt lõi của user đối với SDK quảng cáo (bản `3.0.3`, HEAD branch `main` trên git worktree). Sử dụng phương pháp đọc hiểu mã nguồn (Static Code Analysis) kết hợp với tìm kiếm các mẫu lỗi phổ biến (memory leak, concurrency, state synchronization, security gaps) trên toàn bộ thư mục `packages/ad_sdk/lib/`, `packages/ad_sdk/tool/`. Các file quan trọng được kiểm tra chéo với những đánh giá của các round trước đó (Round 56, 58, 65, 66, 67) để đảm bảo không báo cáo lại các accepted risks (như cơ chế chống bypass trial trên Android/iOS hay việc AppLovin thiếu API COPPA).

## Phát hiện

### [MAJOR] Nguy cơ rò rỉ private key do thiếu cấu hình `.gitignore`
- **File**: `packages/ad_sdk/tool/vip_keygen.dart`:27 và `packages/ad_sdk/.gitignore` (cũng như `.gitignore` ở root).
- **Mô tả cơ chế lỗi**: 
  Script `tool/vip_keygen.dart` được cung cấp để sinh cặp khóa Ed25519 dùng cho việc ký offline các mã VIP (VIP keys). Theo thiết kế, private key sẽ được ghi vào file `.vip-private-key` ngay tại thư mục hiện tại. Mặc dù ở Round 55, script này đã được cập nhật để ghi file với quyền `0600` (chỉ owner có quyền đọc) và in ra log nhắc nhở "never commit", nhưng file này **hoàn toàn không được thêm vào `.gitignore`**. 
  Điều này dẫn đến một rủi ro bảo mật vận hành (Operational Security Risk) cực kỳ nghiêm trọng: một lập trình viên khi chạy script này để tạo key mới, sau đó vô tình chạy `git add .` hoặc dùng công cụ GUI (như VSCode, IntelliJ) để stage tất cả thay đổi, file `.vip-private-key` sẽ bị commit và push thẳng lên repository. Nếu repository này là public, hoặc có nhiều người truy cập, private key sẽ bị lộ lọt.
- **Hậu quả**: Khi private key bị lộ, bất kỳ ai (kể cả kẻ tấn công decompiling/phát hiện ra repo) cũng có thể tự do tạo ra vô hạn mã VIP hợp lệ (`AVP1`, `AVP2`). Hệ thống client-side validation bằng public key của SDK sẽ hoàn toàn tin tưởng các mã này, dẫn tới hệ thống kiếm tiền qua tính năng VIP bị vô hiệu hóa hoàn toàn mà không cần backend can thiệp.
- **Kịch bản tái hiện**: 
  1. Chạy lệnh `dart tool/vip_keygen.dart` trong thư mục `packages/ad_sdk/`. File `.vip-private-key` sẽ được sinh ra.
  2. Chạy `git status --porcelain`. Sẽ thấy dòng `?? .vip-private-key` xuất hiện (Untracked files).
  3. Chạy `git add .` sẽ đưa trực tiếp file này vào staged area để commit.

### Đánh giá các khu vực chức năng khác (PASSED)
- **Đa provider (Parity)**: Xử lý callbacks giữa AdMob và AppLovin đồng nhất. Các khác biệt nhỏ (như `loadAppOpenAd` ở AppLovin bridge bypass AdManager watchdog) là có chủ ý.
- **Offline / Network Resilience**: Guard `_connectivityReady` kết hợp với `_connectivitySub` hoạt động xuất sắc. Không có hiện tượng treo UI hay load vô hạn (Splash Screen có watchdog `_hardCap` 8s). Tự động retry khi có mạng lại.
- **Quản lý Vòng đời (Memory/Lifecycle & Ad Overlap)**:
  - Tất cả các `Timer` (như `_retryTimer` trong Native Ad, `_widthCorrectionDebounce` trong Banner), `AnimationController` (trong Shimmer, Dialog, Toast) và `ValueListenable` listener đều được `cancel()` / `dispose()` / `removeListener()` đầy đủ và đúng quy trình, không gây leak.
  - Ngăn chặn triệt để tình trạng "ad chồng ad" thông qua mutex chung `_fullscreenBusyReason` (ngay cả các luồng tải on-demand cũng re-check mutex trước khi present ad).
  - Banner và MREC kết hợp `RouteAware` hoạt động mượt mà khi push/pop route.
- **Bảo vệ Trial/VIP (Clock Rollback Guard)**: 
  Logic bảo vệ giờ máy tại `AdPreferences._keyVipMaxObservedClockMs` được tích hợp chặt chẽ. Hàm `verifySignedVipKey` lấy mốc thời gian từ `_effectiveNow()` thay vì `DateTime.now()` nên thủ thuật chỉnh lùi giờ trên máy sẽ bị vô hiệu hóa. Chấp nhận rủi ro reinstall bypass theo đúng doc.
- **Consent (GPP, ATT)**:
  - Logic parse GPP (GDPR/US Privacy) trong `_GppBitReader` đã xử lý chuẩn xác bằng `.split('.').first` để chỉ parse `.CoreSegment` (Fix từ Round 56), bỏ qua `.GPCSegment` dư thừa, tránh `FormatException`.
  - Flow xin phép iOS ATT (App Tracking Transparency) timeout an toàn (20s) và giáng cấp xuống `notDetermined` để init AdMob UMP, không gây block launch app.

## Khuyến nghị production

SDK bản `3.0.3` hiện tại **KHÔNG NÊN** được release production app nếu chưa sửa lỗi `.gitignore`.
**Blocker cần fix trước khi release:**
- **Thêm ngay `*.vip-private-key` hoặc `.vip-private-key` vào `.gitignore`** tại root hoặc thư mục package để khóa hoàn toàn rủi ro commit nhầm private key.

*Nếu blocker trên được khắc phục, codebase này (đặc biệt là phần module Ad / Lifecycle / State Management) cực kỳ vững chắc, đáp ứng hoàn toàn mọi tiêu chuẩn khắt khe về memory safety, concurrency, và tuân thủ policy của Google/AppLovin, SẴN SÀNG để ship lên production.*
