# Audit độc lập `applovin_admob_sdk` — Codex Round 5

**Ngày:** 2026-08-22  
**Version:** local `pubspec.yaml` = 2.3.0; pub.dev latest = 2.3.0 (theo premise đã được yêu cầu xác nhận).  
**Phạm vi:** `packages/ad_sdk/lib`, example Android/iOS, cấu hình native, test và các commit mới được nêu. Package là Dart package, không có native implementation riêng ở `packages/ad_sdk/android`/`ios`; native integration nằm ở plugin dependencies và example host.

## Gate

- `cd packages/ad_sdk && flutter analyze` → **0 issues**, exit 0.
- `cd packages/ad_sdk && flutter test` → **891/891 tests passed**, exit 0.

Gate xanh không thay thế on-device verification: test unit dùng bridge/channel fake; Android/iOS integration suites cần emulator/simulator theo `CLAUDE.md` và không nằm trong gate bắt buộc của vòng này.

## Blocker

Không tìm thấy Blocker mới có evidence đủ chắc chắn.

## Major

### M1 — Signed VIP activation vẫn không hoạt động offline, trái yêu cầu sản phẩm

**Evidence:** `lib/src/vip/vip_manager.dart:680-690` kiểm tra `_isConnectedCheck()` và trả `VipRedeemStatus.invalid` trước khi parse/verify; Ed25519 local chỉ bắt đầu tại `lib/src/vip/vip_manager.dart:696-723`; ledger/CRL/grant local nằm tại `lib/src/vip/vip_manager.dart:735-771`. README đồng thời thừa nhận connectivity gate ở `README.md:885-890`, trong khi example gọi đây là “no network” tại `example/lib/main.dart:1224-1230`.

**Vấn đề:** một code hợp lệ không thể activate khi máy mất mạng, dù signature, expiry, CRL cache và replay ledger đều là local. Đây là vi phạm trực tiếp yêu cầu “VIP activation by code must work offline”, không phải giới hạn kỹ thuật.

**Minimum fix:** bỏ connectivity precondition khỏi `redeemSignedKey`; verify Ed25519 + expiry/bundle + cached CRL + ledger hoàn toàn local. Network chỉ dùng để refresh CRL và không được chặn redemption.

### M2 — Chuyển COPPA AppLovin sang `true` khóa ads vĩnh viễn trong session, không có đường phục hồi hợp lệ

**Evidence:** `setConsent` đóng `_canRequestAds` khi provider AppLovin và `isAgeRestrictedUser=true` tại `lib/src/core/ad_manager.dart:2302-2309`; khi một consent mới chuyển cờ về `false`, hàm chỉ apply provider flags tại `:2310-2312`, không mở lại gate. Getter tổng hợp tiếp tục trả false tại `lib/src/core/ad_manager.dart:1041-1042` và adapter reload phụ thuộc gate này tại `:1987-1991`.

**Vấn đề:** thay đổi profile/đính chính tuổi trong cùng process khiến cả banner, app-open, interstitial và rewarded AppLovin ngừng hoạt động đến khi destroy/re-init. Hai provider không còn parity về lifecycle consent; reference host không được cảnh báo rằng thay đổi COPPA trên MAX bắt buộc re-init.

**Minimum fix:** định nghĩa state machine rõ ràng. Với MAX, khi child flag đổi theo bất kỳ chiều nào, dispose adapter và re-initialize sau khi consent mới đã persist; không đơn giản set gate `true` trên adapter cũ. Thêm test `false→true→false` cho AppLovin.

### M3 — UMP retry có thể chạy chồng nhiều consent flow

**Evidence:** periodic backstop gọi `unawaited(requestUmpConsent())` khi `_umpAttemptFailed` còn true tại `lib/src/core/ad_manager.dart:3866-3878`; connectivity path cũng gọi unawaited cùng API tại `lib/src/core/ad_manager.dart:3949-3958`. `requestUmpConsent` tại `lib/src/core/ad_manager.dart:2342-2454` không có in-flight mutex; `_umpAttemptFailed` chỉ được cập nhật khi flow kết thúc (`:2449-2453`).

**Vấn đề:** reconnect và timer có thể cùng khởi động UMP trong lúc retry trước chưa hoàn tất, tạo hai request/form hoặc đua ghi `_lastUmpResult`, gate và consent persistence. Đây là consent UX/policy risk, đặc biệt với form bắt buộc.

**Minimum fix:** dùng một shared in-flight `Future<UmpConsentResult>`/mutex cho mọi caller; retry phải join future đang chạy. Chỉ schedule lần kế tiếp sau completion và test timer + reconnect đồng thời.

## Minor

### m1 — `SimpleEventBus` chưa cô lập exception ở nhánh replay cho late listener

**Evidence:** `fire()` có try/catch từng listener tại `lib/src/core/event_bus.dart:30-40`, nhưng `listen()` gọi trực tiếp `listener(last)` không guard tại `:20-24`.

**Vấn đề:** commit mới bảo vệ broadcast thông thường, nhưng một listener đăng ký muộn sau init event vẫn có thể throw ra caller và làm gián đoạn startup/subscription. Contract replay chính là lý do bus giữ `_lastEvent`.

**Minimum fix:** dùng cùng helper guarded-dispatch cho cả `fire()` và replay trong `listen()`; thêm test listener replay ném lỗi rồi subscriber sau vẫn hoạt động.

### m2 — Bundle binding AVP2 fail-open khi không đọc được bundle ID

**Evidence:** verification chỉ reject mismatch khi `currentBundleId != null && currentBundleId.isNotEmpty` tại `lib/src/vip/signed_vip_key.dart:205-222`; `redeemSignedKey` biến lỗi đọc package thành `null` rồi vẫn verify tại `lib/src/vip/vip_manager.dart:696-720`.

**Vấn đề:** Ed25519 vẫn chống forge, nhưng key AVP2 đã mint riêng cho app A có thể replay sang app B nếu PackageInfo lỗi/không khả dụng. Điều này làm app binding trở thành best-effort thay vì security boundary.

**Minimum fix:** nếu payload AVP2 có bundle allow-list không rỗng thì thiếu bundle ID phải reject; chỉ AVP1 hoặc AVP2 không bind mới được tiếp tục.

### m3 — Example mô tả sai contract replay của EventBus

**Evidence:** example nói EventBus “only delivers” cho listener đăng ký trước tại `example/lib/main.dart:424-429`; implementation thực tế replay `_lastEvent` tại `lib/src/core/event_bus.dart:14-24`; `CLAUDE.md` cũng mô tả replay nhưng vẫn yêu cầu subscribe sớm để phản ứng tức thời.

**Vấn đề:** reference integration chứa giải thích sai, khiến consumer hiểu nhầm contract và che khuất nhánh replay đang thiếu exception isolation (m1).

**Minimum fix:** sửa comment thành “subscribe trước init để phản ứng ngay; late subscription nhận event gần nhất qua replay”.

## Info / xác nhận thiết kế

- **UMP fail-closed đã sửa đúng hướng:** auto flow đóng gate trước adapter init (`lib/src/core/ad_manager.dart:1919-1932`); chỉ `MissingPluginException` mở gate (`:1950-1967`), lỗi khác giữ đóng (`:1968-1975`). Đây là đóng finding lịch sử, không re-litigate. Tuy nhiên M3 là race retry độc lập.
- **Reactive visible ads đã sửa:** consent notifier là single write path (`lib/src/core/ad_manager.dart:1014-1032`); banner/native/MREC subscribe và dispose khi gate đóng (`lib/src/widget/banner_ad_widget.dart:72-105`, `lib/src/widget/native_ad_widget.dart:64-94`, `lib/src/widget/mrec_ad_widget.dart:49-82`). AdMob load success khôi phục `visible=true` cho banner/MREC (`lib/src/adapters/admob_adapter.dart:1392`, `:1525`). Finding stale-mounted-ad lịch sử được đóng cho gate UMP.
- **Không stack fullscreen:** mutex kiểm tra app-open/interstitial/rewarded/rewarded-interstitial và modal tại `lib/src/core/ad_manager.dart:1059-1074`; các show path consult mutex, gồm app-open `:2825`, interstitial `:3069`, rewarded `:3311`, rewarded-interstitial `:3521`.
- **Clock-tamper fix mới hợp lý trong giới hạn local clock:** `addVip` dùng `_effectiveNow()` tại `lib/src/vip/vip_manager.dart:492-520`; drift clamp nằm tại `:224-240`; resume re-anchor tại `lib/src/core/ad_manager.dart:3739-3744`. Không thể bảo đảm chống rollback tuyệt đối qua reinstall/process boundary nếu không có trusted time/backend.
- **Trial 1 ngày có giới hạn nền tảng được disclose:** iOS dùng Keychain và Android dựa Auto Backup (`lib/src/vip/_first_install_guard.dart:17-56`); example bật backup + extraction rules (`example/android/app/src/main/AndroidManifest.xml:8-15`). Android vẫn bypass được khi backup chưa chạy/tắt backup/đổi account; đây không phải anti-tamper tuyệt đối.
- **Replay ledger:** iOS có Keychain ledger; non-iOS trả false và dựa SharedPreferences/Auto Backup (`lib/src/vip/_redeemed_key_ledger.dart:47-76`). Vì vậy Android reinstall replay vẫn là giới hạn thực tế.
- **QA hashes:** 8 hash cố định được merge với host list qua set de-duplicate (`lib/src/config/ad_config.dart:211-227,273-281`) và AdMob init sử dụng effective list (`lib/src/adapters/admob_adapter.dart:432-445`). Đây giảm invalid traffic cho fleet nội bộ, nhưng là public persistent identifiers và mọi consumer đều đăng ký chúng; cần quy trình loại hash khi thiết bị rời QA.
- **Monetization arbitrator:** cả hai nhánh chỉ nudge khi `ecpm > 0` (`lib/src/monetization/monetization_arbitrator.dart:139-152`), đóng regression eCPM chưa có dữ liệu.
- **Android/iOS example:** manifest có INTERNET/NETWORK/AD_ID và GMA test App ID (`example/android/app/src/main/AndroidManifest.xml:1-6,42-47`); iOS có GMA test App ID, AppLovin key placeholder và ATT usage text (`example/ios/Runner/Info.plist:48-58`). Example dùng ATT→UMP→initialize đúng thứ tự (`example/lib/main.dart:431-471`) và chỉ bypass safety cho splash app-open (`:475-493`). AppLovin chạy thật vẫn đòi host cung cấp SDK key; CI không chứng minh path MAX native trên cả hai OS.
- **Provider parity có giới hạn được thiết kế:** AppLovin adapter khai báo rewarded-interstitial là no-op/idle trong interface (`lib/src/core/ad_provider_adapter.dart:227-233`), nên ngoài bốn ad type sản phẩm yêu cầu không có parity cho surface mở rộng này. Bốn type yêu cầu có orchestration ở cả hai provider.

## Lịch sử ngắn

- Đã đóng trong Round 5: UMP “mọi exception đều fail-open”; stale GAID qua destroy/re-init; mounted banner/MREC/native không phản ứng gate; AdMob banner/MREC reload xong vẫn hidden; eCPM=0 nudge; exception của một listener chặn các listener kế tiếp trong `fire()`.
- Vẫn mở sau khi tự đọc source: VIP redemption offline (M1). Các giới hạn trial/replay Android và trusted-clock không thể được giải quyết tuyệt đối nếu vẫn cấm backend.
- Finding cũ đã đóng không được đưa lại thành lỗi mới; phần Info chỉ ghi evidence xác nhận trạng thái.

## VERDICT

**KHÔNG nên dùng SDK 2.3.0 vào production app theo đúng bộ yêu cầu sản phẩm hiện tại.** Điều kiện tối thiểu để đổi verdict: (1) signed VIP code redeem được hoàn toàn offline; (2) sửa lifecycle COPPA AppLovin hai chiều; (3) serialize mọi UMP request/retry; (4) fail-closed bundle binding khi bundle ID không đọc được; và (5) chạy lại analyze/test cùng on-device integration Android + iOS cho cả AdMob và MAX.

Nếu sản phẩm chính thức bỏ yêu cầu activation offline và chấp nhận rõ các giới hạn Android/trusted-clock, M1 có thể được hạ theo quyết định sản phẩm; với yêu cầu hiện tại, gate 891/891 xanh không đủ để ship.
