# T256 — iOS Physical Device Smoke Checklist (AdMob Focus)

## Mục đích
Xác minh trên iPhone thật rằng việc di chuyển sang `google_mobile_ads 9.2.0` và `ageRestrictedTreatment` không làm gián đoạn luồng consent, khởi tạo AdMob và tải quảng cáo test trên iOS.

## Chuẩn bị
1. Cắm iPhone thật, mở khóa màn hình, bật Developer Mode.
2. Kiểm tra `flutter devices` nhận diện được thiết bị với ID cụ thể.
3. Sử dụng Google Test App ID và Test Ad Unit IDs (không dùng production inventory).

## Các bước kiểm thử
1. **ATT:** Cài mới example trên iPhone thật. Ghi trạng thái prompt; chọn Allow và Ask App Not to Track trong lượt cài mới riêng, bảo đảm không crash. Ghi rõ ATT choice không đồng nghĩa với UMP consent.
2. **UMP EEA:** Chạy `--dart-define=UMP_EEA_DEBUG=true` với `UMP_TEST_ID` của iPhone. Kiểm đủ Consent, Do not consent và Manage options. Sau mỗi lựa chọn, ghi `ConsentStatus`, `canRequestAds`, `nonPersonalizedAds` và IAB TCF/GPP values có liên quan; kiểm Privacy Options mở lại và đổi lựa chọn được. Không dùng production inventory.
3. **Ad gate:** Xác nhận AdMob không khởi tạo/request trước khi consent gate cho phép. Sau accept/decline/privacy-options, kiểm ad request tuân theo trạng thái thực tế; không suy ra personalization permission chỉ từ `canRequestAds=true`.
4. **Age treatment:** COPPA/UnderAge true phải gửi `ageRestrictedTreatment=child` (index 1); không có cờ gửi `unspecified` (index 0). Xác nhận `testDeviceIdentifiers` còn nguyên sau cập nhật consent.
5. **AdMob test ads:** Sau khi gate cho phép, tải banner và interstitial test; xác nhận load/show/dismiss, không click creative.

## Pilot gates
- Chỉ closed pilot Android + AdMob sau khi host config checklist hoàn tất; đây không phải bằng chứng iOS hay AppLovin.
- Ghi SDK/app version, thiết bị/OS, geography, ATT/UMP choice, redacted test IDs, logs/screenshots và actual network state.
- Dừng pilot nếu crash/ANR tăng rõ, ads request trước gate, ad hiển thị khi VIP active, reward sai, policy/invalid-traffic warning, hoặc click nhầm do placement.
- Theo dõi crash/ANR, fill/load errors, impressions/revenue, reward `earned=true`, consent withdrawal và offline/reconnect; cần rollback/tắt ad serving trước khi mở rộng.
- Không tuyên bố compliance toàn thị trường từ test geography; publisher vẫn chịu trách nhiệm cấu hình UMP, privacy disclosure, app-ads.txt, audience và ad placement.

## Tiêu chí đạt (Pass Criteria)
- ATT → UMP → AdMob ordering đúng; không crash/uncaught exception.
- Consent accept, decline và Privacy Options được kiểm riêng; state/IAB values và ad gate khớp lựa chọn.
- Native iOS nhận đúng `ageRestrictedTreatment`; test-device IDs còn nguyên.
- Test ads chỉ request sau khi gate cho phép; banner/interstitial load/show/dismiss thành công.
