# Audit bảo mật & tuân thủ — `applovin_admob_sdk` (lens: Security & Compliance)

> Người audit: agent độc lập (read-only). Ngày: 2026-07-16.
> Phạm vi: `packages/ad_sdk/lib/src/` + host app `lib/mckimquyen/widget/vip/`, `splash/`, `common/const/ad_keys.dart`, `android/app/src/main/AndroidManifest.xml`.
> Phương pháp: đọc code hiện tại, đối chiếu với `doc/task/done/*.md` (T01–T43) và `README.md` để **không** báo lại lỗi đã fix, đồng thời **verify fix còn hiệu lực**.

## 1. Verdict tổng quan

SDK này ở trạng thái **tốt một cách bất ngờ** so với mặt bằng ad-SDK cây nhà lá vườn. Các lỗ hổng "kinh điển" của một app không-backend đã được xử lý ở mức đúng đắn về mặt kỹ thuật mật mã: VIP-by-code dùng **Ed25519 chữ ký bất đối xứng** (chỉ public key ship trong app → **không thể forge key mới** dù decompile), chứ **không phải** "base64 obfuscation" như CLAUDE.md mô tả (CLAUDE.md đã lỗi thời — code thật là `signed_vip_key.dart`). Trial 1 ngày có chống clock-rollback bằng `grantedAt` bất biến (T17) và anti-reinstall (iOS Keychain + Android Auto Backup). Consent flow ATT → UMP → init đúng thứ tự Apple/Google bắt buộc, kết quả UMP **có** được forward xuống cả AppLovin lẫn AdMob (không có tình trạng "UMP từ chối nhưng AppLovin không biết"), và cả 3 điểm `await` native đều có timeout 20s (T43).

Tuy nhiên, **theo đúng lens compliance**, vẫn còn các khoảng trống ở tầng **chính sách khu vực (CCPA/US-state privacy)** và **App Open ad lần mở đầu tiên** mà — với một app đang **ship production thật lên Play/App Store** — có thể trở thành rủi ro account-level. Không có finding nào Critical; có **2 High** và một số Medium/Low. Kết luận cuối: **Có điều kiện** (xem mục 4).

## 2. Bảng đối chiếu theo yêu cầu

| Yêu cầu | Trạng thái | Đánh giá ngắn |
|---|---|---|
| **Trial mode 1 ngày** | 🟡 Chấp nhận được, có giới hạn đã biết | Chống clock-rollback ✅ (T17, `vip_entry.dart:30`), anti-reinstall iOS Keychain ✅, **Android cố ý KHÔNG chống reinstall** (fail-open) — xóa app + cài lại = reset trial vô hạn trên Android. Đây là quyết định thiết kế có chủ đích, không phải bug. |
| **VIP by code, không server** | 🟢 Tốt (giới hạn đã biết & ghi rõ) | Ed25519 signed keys, không forge được key mới. One-time-use **per-device** (không phải toàn cục). Local storage có checksum FNV-1a (răn đe sửa tay) nhưng **không chống được máy đã root**. |
| **Consent mọi quốc gia (AdMob + AppLovin)** | 🟡 GDPR/EEA tốt, **CCPA/US-state yếu**, COPPA có gap khi always-child | UMP phân biệt đúng EEA (Google tự geo-detect). Forward xuống cả 2 provider ✅. **Nhưng CCPA (California `doNotSell`) không bao giờ được bật** vì host không gọi `setConsent`, và UMP không map US-state privacy. |
| **Tuân thủ policy AdMob/AppLovin** | 🟡 Phần lớn ổn, 1 điểm xám App Open | Safety caps production hợp lý (5/ngày, 3/giờ, 60s throttle, CTR 30%). Rewarded không auto-grant. Không ép click/ẩn close. **App Open hiện trên splash mỗi lần mở app** — điểm xám policy Google. |

## 3. Danh sách phát hiện

### [HIGH] F1 — Không có cơ chế CCPA / US-state privacy (California "Do Not Sell") nào được kích hoạt trong luồng production

- **File:** `lib/mckimquyen/widget/splash/splash_screen.dart` (toàn bộ luồng — **không** có lời gọi `setConsent(doNotSell: ...)` ở đâu trong `lib/`); `packages/ad_sdk/lib/src/core/ad_manager.dart:1096-1102` (`requestUmpConsent` chỉ map `hasUserConsent`, giữ nguyên `_consent.doNotSell` mặc định `false`); `packages/ad_sdk/lib/src/core/ad_consent.dart:33-35` (`doNotSell = false` mặc định).
- **Kịch bản:** Với user ở **California (hoặc các bang Mỹ có luật privacy: Virginia, Colorado, Connecticut...)**, UMP của Google trả về `ConsentStatus.notRequired` (vì không phải EEA) → code map thành `hasUserConsent: true` (`ad_manager.dart:1096`) → **ads cá nhân hóa được bật cho mọi user ngoài EEA, bao gồm California**, trong khi `doNotSell` vẫn `false`. Host app **không hề** có UI hay logic nào để user California opt-out khỏi "sale/share" dữ liệu. Grep toàn bộ `lib/` cho `doNotSell`/`isAgeRestrictedUser`/`setConsent` → **0 kết quả** (host không gọi).
- **Hậu quả thực tế:** Vi phạm CCPA/CPRA nếu app có traffic Mỹ đáng kể. Đây là rủi ro **pháp lý + Google/Apple policy** (cả hai đều yêu cầu app tôn trọng US-state privacy signals). Với app không-backend, cách tối thiểu là thêm entry point "Do Not Sell My Personal Information" gọi `setConsent(doNotSell: true)`. SDK **đã có sẵn plumbing** (`applyConsentToProviders` forward `setDoNotSell` cho AppLovin + RDP cho AdMob) — chỉ là host chưa dùng.
- **Lưu ý:** Đây là lỗ hổng ở **tầng host/tích hợp**, không phải bug SDK. SDK cung cấp đủ API; việc không wire là quyết định (hoặc thiếu sót) của host.

### [HIGH] F2 — App Open ad hiển thị trên splash ở mọi lần mở app (điểm xám policy Google App Open)

- **File:** `lib/mckimquyen/widget/splash/splash_screen.dart:85-129` (load + show App Open sau khi SDK init xong, trên splash, với `bypassSafety: true` tại `:129`).
- **Kịch bản:** Google policy về App Open ad quy định **không được** hiện App Open che phần "app đang tải nội dung lần đầu" theo cách gây nhầm lẫn; App Open dành cho các lần chuyển foreground/background, không phải để chặn cold-start đầu tiên. Ở đây App Open hiện ngay trên splash sau init, dùng `bypassSafety: true` (bỏ qua toàn bộ frequency cap). Điểm **giảm nhẹ** đáng kể: **first-install VIP grace 24h** (mặc định) khiến user **mới cài** KHÔNG thấy App Open trong ngày đầu — nên kịch bản tệ nhất "App Open đè lên lần mở app đầu tiên của user mới" thực tế bị chặn. Nhưng với user cũ, mỗi cold-start đều có App Open.
- **Hậu quả thực tế:** Rủi ro policy strike/limited-ad-serving từ AdMob nếu review viên coi splash App Open là "interrupting app load". Đây là mô hình **phổ biến và nhiều app dùng được**, nhưng vẫn là vùng xám — cần theo dõi AdMob policy center sau khi ship. `bypassSafety: true` ở splash là hợp lý (đã whitelist đúng 1 chỗ), không phải lạm dụng.

### [MEDIUM] F3 — One-time-use của signed VIP key chỉ per-device, không toàn cục → 1 key hợp lệ bị leak dùng được trên vô số máy

- **File:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:475-528` (`redeemSignedKey`), `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:66-70` (ghi rõ trong doc-comment).
- **Kịch bản:** Attacker không forge được key mới (Ed25519 ✅), nhưng nếu **một** key promo hợp lệ (vd `PROMO30`) bị chia sẻ công khai (forum, group), **mỗi thiết bị** đều redeem được 1 lần → VIP miễn phí không giới hạn số máy. Redeemed-kid ledger (`_redeemed_key_ledger.dart`) chỉ chặn **cùng máy** redeem lại.
- **Hậu quả thực tế:** Mất doanh thu VIP theo diện rộng nếu key bị leak. Không thể revoke 1 key đã mint (không có server). **Đây là giới hạn nội tại của mô hình offline** đã được ghi rõ trong T18 — không thể fix nếu không có backend. Giảm nhẹ: mint key với `--days` ngắn + `kid` riêng cho từng đợt để giới hạn thiệt hại; theo dõi bất thường qua analytics.

### [MEDIUM] F4 — VIP entries lưu plaintext JSON trong SharedPreferences; checksum chỉ răn đe, không chống root

- **File:** `packages/ad_sdk/lib/src/vip/vip_entry.dart:50-60` (toJson plaintext), `packages/ad_sdk/lib/src/utils/ad_preferences.dart` (`getVipEntriesRaw`/`setVipEntriesRaw` + checksum FNV-1a — T30).
- **Kịch bản:** Trên máy **đã root (Android) / jailbreak (iOS)**, user có thể sửa trực tiếp file prefs để tự tạo `VipEntry` với `expiresAt` năm 2099 → VIP vĩnh viễn miễn phí, không cần key. Checksum FNV-1a (T30) chỉ chống "sửa tay ngây thơ" — attacker biết thuật toán (mã nguồn public) sẽ tính lại checksum cùng lúc.
- **Hậu quả thực tế:** Mất doanh thu VIP trên nhóm máy root/jB (thiểu số user). Đã được ghi nhận có chủ đích trong T30 ("Giới hạn đã biết"). Chấp nhận được cho app không-backend — chống root thật sự cần server-side entitlement. `grantedAt` anti-rollback (T17) không giúp gì ở đây vì attacker set cả `grantedAt` lẫn `expiresAt`.

### [MEDIUM] F5 — App always-child-directed sẽ init AppLovin 1 lần ở install đầu (COPPA gap)

- **File:** `packages/ad_sdk/lib/src/core/ad_consent.dart:85-93` (chỉ warning khi mid-session); gate init thật ở `applovin_adapter.dart` (T40) chỉ đọc `isAgeRestrictedUser` **đã persist từ session trước**.
- **Kịch bản:** App **luôn** nhắm trẻ em nhưng không có consent dialog nào set flag → ở lần cài đầu tiên `isAgeRestrictedUser` mặc định `false` → AppLovin init bình thường 1 lần (AppLovin MAX 4.x **không** có runtime child-directed API nào để tắt IDFA sau đó). AdMob thì OK vì `tagForChildDirectedTreatment` set per-request.
- **Hậu quả thực tế:** Với **app hiện tại (WiFi stress tester) KHÔNG child-directed → không áp dụng, rủi ro = 0**. Nhưng nếu SDK tái dùng cho app trẻ em, đây là vi phạm COPPA/Families policy thật. Đã ghi rõ trong T40 "Known limitation" + README compliance checklist. Cần thêm field `AdConfig.audienceMode` tường minh trước khi dùng cho app child-directed.

### [LOW] F6 — Host commit ad unit IDs + AppLovin SDK key thật vào source

- **File:** `lib/mckimquyen/common/const/ad_keys.dart:26-41` (AppLovin `sdkKey` + banner/inter/appOpen/rewarded IDs thật, per-platform).
- **Kịch bản:** Đây là **chuẩn** cho một app production (ad unit ID không phải secret — chúng vốn public trong bytecode mọi app). AppLovin SDK key cũng không phải credential nhạy cảm (không cấp quyền ghi dashboard). Không phải lỗ hổng thực sự.
- **Hậu quả thực tế:** Rủi ro thấp. Chỉ cần đảm bảo **không** ai copy nhầm các ID này sang app khác (sẽ ghi nhận sai attribution). Đối lập: SDK `example/` app đã đúng (dùng `String.fromEnvironment` placeholder — T41), không leak gì.

### [LOW] F7 — `vipKeyValidator == null` = demo mode chấp nhận mọi key (chỉ ảnh hưởng luồng `redeemVip` cũ, không phải `redeemSignedKey`)

- **File:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:534-539` (`_runValidator`: nếu validator null → return true sau delay 400ms).
- **Kịch bản:** Luồng `redeemVip()` (cũ, dựa validator) sẽ cấp VIP cho **bất kỳ** chuỗi nào nếu validator null. **Nhưng** host thật (`vip_screen.dart` → `VipRedeemScreen`) dùng `redeemSignedKey()` (Ed25519), KHÔNG dùng `redeemVip()` với validator null. Nên đường production an toàn.
- **Hậu quả thực tế:** Rủi ro chỉ hiện thực nếu tương lai có ai gọi `redeemVip()` mà quên set validator. Đề xuất: assert chặn `validator == null` trong release build (đã đề cập ý tưởng này ở T18 acceptance criteria nhưng chưa thấy enforce trong code `_runValidator`).

## 4. Kết luận: Có nên dùng SDK này cho production ngay bây giờ không?

**CÓ ĐIỀU KIỆN.**

Nền tảng bảo mật/compliance của **SDK core** đủ vững để ship (VIP không forge được, trial chống rollback + anti-reinstall, consent đúng thứ tự và forward đủ 2 provider, timeout guard đầy đủ). Không có finding Critical. Các giới hạn của mô hình offline (F3, F4) đã được ghi nhận có chủ đích và chấp nhận được cho app không-backend.

**Điều kiện bắt buộc trước khi ship rộng (blocking):**
1. **F1 (CCPA/US-state):** Nếu app có traffic Mỹ → wire một entry point "Do Not Sell/Share" gọi `setConsent(doNotSell: true)` cho user opt-out (SDK đã có plumbing sẵn, chỉ cần vài dòng ở host). Nếu **chắc chắn** chỉ nhắm VN/EEA và chặn US → có thể defer nhưng phải khai báo rõ trong Play/App Store data-safety.
2. **F2 (App Open splash):** Ship được nhưng **phải theo dõi AdMob Policy Center** trong vài tuần đầu; nếu bị flag "interrupting app load", chuyển App Open sang chỉ chạy khi resume từ background (không chạy trên cold-start splash).

**Điều kiện có điều kiện (non-blocking, tùy scope):**
3. **F5 (COPPA):** Chỉ cần xử lý nếu SDK được tái dùng cho app nhắm trẻ em — app WiFi stress tester hiện tại KHÔNG cần.
4. **F3/F4:** Chấp nhận cho không-backend; chỉ nâng cấp lên server-validated nếu doanh thu VIP đủ lớn để lo bị crack.

Ngoài ra, lưu ý phi-kỹ-thuật từ chính README: SDK này **single maintainer, no SLA, gần như chưa có lịch sử production bên thứ ba** — nên theo đúng khuyến nghị của README, hãy pilot traffic nhỏ + theo dõi dashboard AdMob/AppLovin (fill rate, policy flags, revenue) vài tuần trước khi tích hợp toàn diện.
