# Audit Codex round 26 — Flutter ad SDK 2.4.0

**Ngày audit:** 2026-08-31  
**Commit được audit:** `16802145c08cd00a1c291c4b94a60f4a7e276549`  
**Phạm vi:** `packages/ad_sdk/lib/`, `test/`, `example/`, `README.md`,
`CHANGELOG.md`, artifact pub.dev 2.4.0 và lịch sử Git liên quan đến package.  
**Nguyên tắc:** audit chỉ đọc; không sửa source SDK.

## Kết quả ngắn

Phát hiện **một finding mới, BLOCKER**, không có trong baseline round 23–25:
một AppLovin SDK key thật cùng tám MAX ad-unit ID đã được commit và vẫn đọc
được nguyên văn từ lịch sử Git. File đã bị xóa ở HEAD và không nằm trong
archive pub.dev, nhưng xóa file bằng commit thường không thu hồi bí mật đã lộ.

Không tìm thấy finding runtime mới đủ bằng chứng ở mức MAJOR/BLOCKER trong các
đường VIP, consent, offline gate, safety/caps, bốn loại quảng cáo và teardown
của hai adapter. Các deliberate non-fix của baseline không được flag lại.

## Finding mới

### R26-B1 — Credential AppLovin production vẫn nằm trong lịch sử Git

**Severity: BLOCKER**

**Vị trí:**

- `packages/ad_sdk/doc/archive/AD.MD` tại commit release `2433578`, dòng
  **98–106** (file đã bị xóa ở HEAD): chứa một AppLovin SDK key dài 86 ký tự và
  tám MAX ad-unit ID Android/iOS.
- `packages/ad_sdk/README.md:1893`: hiện khẳng định “nothing real is committed
  to source”, không đúng với lịch sử repository.
- `packages/ad_sdk/.pubignore:44–51`: chứng minh `doc/*` bị loại khỏi package
  publish; vì vậy đây **không** phải leak qua tarball pub.dev 2.4.0, nhưng cũng
  không xử lý leak trong Git.

**Mô tả:** commit HEAD có commit xóa file `0f503ba` với chính thông điệp
“leaked real AppLovin SDK key”. Tuy nhiên blob cũ vẫn lấy được bằng một lệnh
đọc Git thông thường từ commit release. Việc xóa ở working tree không đổi các
object/commit cũ và không vô hiệu hóa credential trên AppLovin dashboard.

**Kịch bản lỗi cụ thể:** người có quyền clone/fetch repository (hoặc bất kỳ ai
nếu repository/commit từng public) đọc blob ở commit cũ, lấy SDK key cùng ad
unit IDs, rồi dùng chúng trong app/build khác hoặc tự động hóa request bất
hợp lệ. Hậu quả có thể gồm traffic giả gắn vào tài khoản AppLovin, sai lệch
analytics/doanh thu, policy investigation hoặc khóa tài khoản. Dù AppLovin có
thêm ràng buộc package/bundle ở phía dashboard, credential đã lộ vẫn phải được
coi là compromised; không được dùng giả định đó thay cho rotation.

**Re-verify hai lần:** **Có.**

1. Đọc diff xóa của commit `0f503ba`, trong đó file và lý do xóa được xác nhận.
2. Đọc độc lập blob từ parent/release commit `2433578`, xác nhận lại đúng các
   dòng 98–106 và checksum SHA-256 của blob là
   `0f4ee01e050436fbf9118dfbcc53b30e4d542c143e100039289303ed2e29c2ad`.
   Giá trị credential không được chép lại vào báo cáo này.

**Điều kiện đóng finding:**

1. Rotate/revoke AppLovin SDK key và toàn bộ MAX ad-unit ID đã lộ trên
   dashboard; cập nhật production app bằng bộ mới.
2. Kiểm tra dashboard/audit log và traffic bất thường kể từ thời điểm commit
   đầu tiên chứa blob.
3. Nếu repository từng được chia sẻ/public, scrub history bằng quy trình có
   kiểm soát rồi thu hồi mọi clone/cache liên quan; lưu ý scrub history không
   thay thế rotation.
4. Sửa tuyên bố sai tại README dòng 1893 và thêm secret scanning/pre-commit/CI
   để ngăn tái diễn.

## Re-verification bảy yêu cầu sản phẩm

1. **AdMob + AppLovin, Android + iOS:** source có hai adapter và cấu hình ID
   theo platform. Không thấy regression mới. AppLovin vẫn thiếu bằng chứng
   automated end-to-end với key thật như baseline đã nêu.
2. **Online/offline:** load/show được gate theo connectivity, persisted consent
   được giữ khi UMP không kết luận được, reconnect có refill/debounce. Test
   resilience và consent-offline pass.
3. **Bốn loại ad và lifecycle:** banner/app-open/rewarded/interstitial có slot,
   callback guard, watchdog và dispose. Các per-widget banner/MREC/native
   resources được release; full-screen wrapper gỡ callback trước dispose.
   Không thấy leak/crash mới có thể tái hiện. Native RouteAware vẫn là
   deliberate non-fix đã document.
4. **Trial một ngày:** release default vẫn là 24 giờ; first-install guard và
   clock high-water logic hiện diện. Giới hạn clear-data Android được README
   mô tả đúng.
5. **VIP code offline, không backend:** Ed25519 offline verification, app
   binding/expiry/replay ledger/CRL vẫn hiện diện. Đây là đúng yêu cầu, không
   phải finding. Finding R26-B1 là credential quảng cáo, không phải private
   signing key VIP.
6. **Consent đa khu vực:** UMP/IAB reconciliation, COPPA gate và US do-not-sell
   được truyền tới cả hai provider theo code hiện tại. Việc cấu hình/publish
   consent message cho từng app ID vẫn là nghĩa vụ của host/dashboard.
7. **Policy:** caps/throttle/impression accounting và no-stacking guard không
   có regression mới thấy được; tuy nhiên credential production bị lộ là một
   rủi ro account trực tiếp và chặn production approval.

## Pub.dev và README

Đã kiểm tra trực tiếp API và archive pub.dev:

- Latest: **2.4.0**, publish lúc `2026-08-30T17:38:09Z`.
- Pub points: **150/160**.
- Archive 2.4.0 không chứa `doc/archive/AD.MD`; `pubspec.yaml` và
  `lib/src/core/ad_manager.dart` trong archive khớp working tree.
- Mục “Known limitations” nhìn chung khớp source/baseline: Android clear-data
  replay, cached AppLovin freshness, giới hạn test lifecycle và production
  history đều được nêu. Điểm không khớp là tuyên bố tại README:1893 rằng không
  có secret thật từng được commit.

## Kiểm chứng tự động

- `flutter analyze`: **No issues found**.
- `flutter test`: **1.336 tests passed**, exit code 0.
- Đây là unit/widget evidence trên host; không thay thế real-device Android/iOS
  với production dashboard configuration.

## Kết luận production

**Không approve đưa bản cấu hình hiện tại vào production.** BLOCKER R26-B1
phải được đóng trước: rotate/revoke toàn bộ AppLovin credential đã lộ và xác
minh app production dùng credential mới.

Sau khi có bằng chứng rotation, SDK có thể được **approve có điều kiện** cho
AdMob trên Android/iOS theo verdict baseline. Với AppLovin, ngoài rotation cần
thêm smoke test thật trên ít nhất một thiết bị Android và một thiết bị iOS cho
load/show/dismiss/reward, consent withdrawal và offline/reconnect bằng key/ad
units mới; theo dõi dashboard policy/crash/fill trong giai đoạn rollout nhỏ.
