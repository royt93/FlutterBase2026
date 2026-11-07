# T256 — iOS Physical Device Smoke Checklist (AdMob Focus)

## Mục đích
Xác minh trên iPhone thật rằng việc di chuyển sang `google_mobile_ads 9.2.0` và `ageRestrictedTreatment` không làm gián đoạn luồng consent, khởi tạo AdMob và tải quảng cáo test trên iOS.

## Chuẩn bị
1. Cắm iPhone thật, mở khóa màn hình, bật Developer Mode.
2. Kiểm tra `flutter devices` nhận diện được thiết bị với ID cụ thể.
3. Sử dụng Google Test App ID và Test Ad Unit IDs (không dùng production inventory).

## Các bước kiểm thử
1. **Kiểm tra ATT prompt:**
   - Cài đặt và mở example app lần đầu trên iOS.
   - Xác nhận hộp thoại ATT (App Tracking Transparency) xuất hiện đúng sau first frame splash screen.
   - Bấm "Ask App Not to Track" hoặc "Allow", đảm bảo app không bị crash.

2. **Kiểm tra UMP Consent (EEA Debug Mode):**
   - Chạy với `--dart-define=UMP_EEA_DEBUG=true` và truyền `UMP_TEST_ID` của iPhone (lấy từ console log khi chạy lần đầu).
   - Xác nhận form consent UMP xuất hiện.
   - Bấm Consent, kiểm tra UMP trả về `ConsentStatus.obtained` và `canRequestAds = true`.

3. **Kiểm tra AdMob Request Configuration (Age Treatment):**
   - Chạy test integration hoặc kiểm tra log xem `RequestConfiguration` gửi xuống native iOS có chứa đúng `ageRestrictedTreatment` không:
     - COPPA = true hoặc UnderAge = true -> `child` (index 1).
     - Không có cờ -> `unspecified` (index 0).
   - Xác nhận `testDeviceIdentifiers` không bị mất sau các lần cập nhật consent.

4. **Kiểm tra tải quảng cáo test AdMob:**
   - Thử tải 1 banner test và 1 interstitial test.
   - Xác nhận ad load thành công, hiển thị được trên màn hình iOS thật và dismiss bình thường.

## Tiêu chí đạt (Pass Criteria)
- Không có crash, không có uncaught exception.
- Luồng ATT -> UMP -> AdMob initialize chạy mượt mà, đúng thứ tự.
- Gửi đúng `ageRestrictedTreatment` tới native Google Mobile Ads SDK trên iOS.
