# Audit độc lập `applovin_admob_sdk` 2.9.15 — round 34

Ngày audit: 2026-09-03  
Phạm vi: `packages/ad_sdk`, app mẫu, lockfile/native manifest và source dependency thực trong `~/.pub-cache`. Tôi không dùng kết luận audit cũ làm bằng chứng; các finding dưới đây được dựng lại từ code hiện tại.

## Kết luận ngắn

**Không nên đưa 2.9.15 vào production nếu bật trial 1 ngày hoặc dựa vào SDK để tự động tuân thủ GPP/US-state.** Có 1 BLOCKER và 5 MAJOR. Nếu tắt `firstInstallVipGrace`, tự xử lý toàn bộ GPP/CCPA bên host, không coi code VIP là one-time toàn cầu, khóa đường `bypassSafety`, và sửa logging app mẫu thì lõi load/show/dispose của các ad format có chất lượng khá tốt.

Kết quả kiểm chứng tĩnh: `flutter analyze` sạch; `flutter test` **1571/1571 pass**. Điều này không phủ định các finding: phần lớn là giới hạn thiết kế/offline persistence, tín hiệu privacy bị bỏ qua, hoặc platform-channel completion không được quan sát.

## Findings

### R34-01 — BLOCKER — Trial 1 ngày và ledger VIP vẫn bypass được bằng uninstall/reinstall trên Android

**Vị trí:**

- `packages/ad_sdk/lib/src/vip/_first_install_guard.dart:126-145,157-185`
- `packages/ad_sdk/lib/src/core/ad_manager.dart:2581-2598,2607-2638,2667-2668`
- `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:9-25,79-99`
- `packages/ad_sdk/example/android/app/src/main/res/xml/data_extraction_rules.xml:16-22`
- `packages/ad_sdk/example/android/app/src/main/res/xml/full_backup_content.xml:14-16`

**Cơ chế thật:** `FirstInstallGuard.hasAlreadyGranted()` trả thẳng `false` trên Android và `markGranted()` là no-op. Hàng rào duy nhất là cờ SharedPreferences được kỳ vọng được Google Auto Backup khôi phục. Auto Backup không phải primitive chống attacker: người dùng có thể tắt backup/sync, dùng tài khoản khác, xóa backup, sideload APK, hoặc cài trên profile/device khác. Khi prefs không được restore, `isFirstInstallGraceApplied()` lại false và `AdManager.initialize()` gọi `vip.addVip()` để cấp một cửa sổ mới. Ledger chống reuse signed key cũng trả `false`/no-op trên mọi nền tảng không phải iOS, nên cùng thao tác xóa dữ liệu/reinstall có thể dùng lại một `kid` trên Android.

App mẫu cấu hình backup đúng, nhưng package Flutter không thể ép app tiêu thụ giữ các XML đó; và ngay cả cấu hình đúng cũng chỉ best-effort.

**Tái hiện:** build release Android với `FirstInstallVipGrace.auto`; mở lần đầu và nhận 24 giờ VIP; tắt Google Backup (hoặc dùng thiết bị/profile không restore backup), uninstall, reinstall và mở lại. SharedPreferences mới không có hai cờ, guard Android luôn cho phép, trial được cấp lại. Tương tự, redeem một AVP2, reinstall không restore prefs rồi redeem lại cùng code.

**Fix đề xuất:** nếu yêu cầu thật sự là “không bypass bằng uninstall”, không thể đạt bằng state chỉ lưu local trên Android. Cần backend/Play Integrity + tài khoản/receipt, hoặc bỏ trial tự động trên Android. Nếu nhất quyết không backend, phải mô tả là best-effort và default `FirstInstallVipGrace.disabled`; không quảng bá như anti-bypass. Với signed code, cần redemption ledger phía server hoặc mã gắn với một định danh phần cứng/tài khoản có chứng thực và chính sách khôi phục rõ ràng.

### R34-02 — MAJOR — Code VIP hợp lệ không phải one-time toàn cầu; AVP1 còn không có expiry hay app binding

**Vị trí:**

- `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:86-120,149-162,199-223`
- `packages/ad_sdk/lib/src/vip/vip_manager.dart:1282-1313,1343-1360,1384-1409,1439-1445`
- `packages/ad_sdk/example/lib/main.dart:192-213`

**Cơ chế thật:** Ed25519 verification là đúng và public key trong binary không cho phép forge chữ ký mới. Tuy nhiên replay chỉ bị chặn bằng ledger **theo từng thiết bị/install**. Một AVP2 hợp lệ có thể được chia sẻ và redeem một lần trên mỗi thiết bị; không có server nên không tồn tại atomic global claim. Tệ hơn, verifier vẫn chấp nhận AVP1: payload chỉ có `seconds|keyId`, không có thời hạn redeem và không có bundle ID. Ba code demo công khai cũng là AVP1. Network gate trước verification không thay đổi tính chất này; nó không liên hệ bất kỳ authority nào để claim code.

**Tái hiện:** mint một AVP2 hợp lệ rồi redeem trên hai điện thoại khác nhau: mỗi máy có prefs/Keychain riêng nên đều qua `isVipKeyIdRedeemed`. Với AVP1, copy code sang app khác dùng cùng public key hoặc giữ code vô thời hạn; verifier không có trường để từ chối theo app/expiry.

**Fix đề xuất:** tuyên bố rõ code là multi-device bearer token, hoặc thêm backend claim một lần. Ngừng mint và mặc định từ chối AVP1 trong major version kế tiếp; bắt buộc AVP2 có bundle binding không rỗng, expiry ngắn, và CRL rotation. Nếu không thể thêm backend, phát code theo account/device và chấp nhận rằng chống replay toàn cầu là bất khả thi.

### R34-03 — MAJOR — Đồng bộ GPP bỏ qua opt-out quảng cáo nhắm mục tiêu và toàn bộ section theo bang

**Vị trí:**

- `packages/ad_sdk/lib/src/core/iab_storage.dart:94-102,204-253`
- `packages/ad_sdk/lib/src/core/ad_manager.dart:5099-5139,5155-5164`
- `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:705-719`

**Cơ chế thật:** `usPrivacyOptedOut()` ưu tiên chuỗi legacy `IABUSPrivacy_String`; nếu vắng thì chỉ đọc `IABGPP_7_String` (US National). Code tự ghi nhận rõ không decode các section state-specific. Ngay trong US National, parser skip sáu notice field rồi chỉ đọc `SaleOptOut` và `SharingOptOut`; nó không đọc `TargetedAdvertisingOptOut` nằm ngay sau chúng. Vì vậy tín hiệu “không bán/chia sẻ nhưng opt out targeted advertising” trả về false, và CMP chỉ ghi California/Colorado/Virginia state section mà không ghi section 7 trả về null. `_reconcileDeviceUsPrivacy()` chỉ siết `doNotSell` khi kết quả đúng bằng true; các trường hợp trên tiếp tục để AppLovin `setDoNotSell(false)` và AdMob không gửi RDP.

**Tái hiện:** seed GPP US National với sale=2, sharing=2, targetedAdvertisingOptOut=1, không có USP; resume app. Hàm trả false ở dòng 248. Hoặc chỉ seed `IABGPP_8_String` cho California; dòng 240 không đọc nó và reconciliation không làm gì.

**Fix đề xuất:** dùng thư viện GPP được duy trì hoặc implement đầy đủ header + section IDs áp dụng (US National và US-state); coi `TargetedAdvertisingOptOut == 1` là tín hiệu hạn chế quảng cáo phù hợp, đồng thời phân biệt sale/share/targeting thay vì ép tất cả vào một bool nếu provider cần semantics khác. Thêm test vector chính thức cho từng section/bang và test end-to-end rằng cả hai provider nhận trạng thái siết.

### R34-04 — MAJOR — SDK đánh dấu privacy AppLovin “đã apply” dù method-channel là fire-and-forget

**Vị trí:**

- `packages/ad_sdk/lib/src/core/ad_consent.dart:142-175,214-232`
- `packages/ad_sdk/lib/src/adapters/applovin_bridge.dart:10-25,59-68`
- dependency thật `~/.pub-cache/hosted/pub.dev/applovin_max-4.6.4/lib/applovin_max.dart:191-210`

**Cơ chế thật:** `AppLovinMAX.setHasUserConsent()` và `setDoNotSell()` trả `void`, nhưng bên trong gọi `MethodChannel.invokeMethod()` rồi bỏ Future. `try/catch` ở `applyConsentToProviders()` chỉ bắt lỗi đồng bộ; lỗi platform bất đồng bộ không thể đi vào catch. Code vẫn set `appLovinApplied = true`, và nếu write AdMob thành công thì cập nhật `_lastAppliedToProviders`. Resume reconciliation sau đó có thể tin rằng cả hai provider đã nhận withdrawal dù AppLovin channel vừa lỗi/engine đang detach; Future bị bỏ còn có thể tạo unhandled async error.

Pre-init bridge có cùng contract `void`, nên `await _bridge.initialize()` không chứng minh hai privacy call trước đó hoàn thành thành công; thứ tự gửi message thường được giữ nhưng failure/completion không được quan sát.

**Tái hiện:** dùng binary messenger handler cho channel `applovin_max` trả `PlatformException` ở `setDoNotSell`, còn AdMob update thành công. `applyConsentToProviders()` hoàn tất và cache consent mới như đã áp dụng; lỗi AppLovin xuất hiện ngoài Future đang await.

**Fix đề xuất:** upstream/fork bridge phải trả `Future<void>` cho các setter và `await` chúng; chỉ cập nhật `_lastAppliedToProviders` sau completion. Nếu không thể đổi plugin API, gọi trực tiếp method channel qua wrapper có Future, hoặc xác minh lại bằng `hasUserConsent()`/`isDoNotSell()` với timeout và retry. Có test platform-channel error thực, không chỉ fake synchronous void method.

### R34-05 — MAJOR — `bypassSafety` là backdoor public cho App Open không có enforcement

**Vị trí:** `packages/ad_sdk/lib/src/core/ad_manager.dart:5910-5939,5987-6025`.

**Cơ chế thật:** bất kỳ host call site nào cũng có thể truyền `bypassSafety: true`; khi đó daily/hour/session caps, minimum interval và placement cap đều bị bỏ. `placement` và `callSiteTag` do chính host cung cấp, không chứng minh đang ở splash. Audit trail chỉ ghi sau sự kiện, ở RAM, nên restart xóa bằng chứng và cũng reset khả năng giám sát. Invalid-traffic pause vẫn được giữ, nhưng không giải quyết việc show App Open liên tục ngoài load screen — rủi ro placement/invalid traffic rõ ràng.

**Tái hiện:** từ một page thường, lặp `loadAppOpenAd` rồi `showAppOpenAd(bypassSafety: true, placement: AdPlacement.splash)` sau mỗi dismiss. Không có check route/splash-active/cold-start-once; các cap bị bỏ qua.

**Fix đề xuất:** bỏ bool public; cung cấp API splash riêng chỉ hợp lệ khi `markSplashActive()` đang true, chỉ một lần mỗi cold start, và vẫn giữ hard minimum interval/daily cap. Nếu cần escape hatch nội bộ, dùng capability token private do splash controller cấp và persist audit/counter chống restart.

### R34-06 — MAJOR — App mẫu vô hiệu hóa mặc định logging an toàn và lưu raw GAID trong release

**Vị trí:**

- `packages/ad_sdk/example/lib/main.dart:264-265`
- `packages/ad_sdk/lib/src/config/ad_config.dart:388-392`
- `packages/ad_sdk/lib/src/core/ad_manager.dart:2225-2231`

**Cơ chế thật:** `AdConfig` mặc định chỉ verbose trong debug chính vì debug log có `GAID=<raw advertising id>`. App mẫu lại ép `AdLogLevel.verbose` không phụ thuộc `kDebugMode` và chuyển log vào `LogBuffer`. Nếu developer dùng example làm integration template hoặc build bản release demo, raw advertising identifier bị giữ trong RAM/hiển thị ở log viewer và có thể đi tiếp qua callback `onLog`. Đây cũng đi ngược “hợp đồng tích hợp an toàn” mà example được kỳ vọng minh họa.

**Tái hiện:** build release app mẫu trên Android, mở app để init, rồi mở Log Viewer: dòng `GAID=...` được tạo vì verbose vẫn bật.

**Fix đề xuất:** dùng `logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning`; tốt hơn nữa, không bao giờ log raw GAID ở library, kể cả verbose—hash/redact mặc định và chỉ expose qua API explicit cho test-device setup.

## Các vùng đã kiểm tra và không phát hiện lỗi blocking mới

- **Lifecycle ads:** App Open/interstitial/rewarded/rewarded-interstitial có slot state, shared fullscreen mutex, show/load watchdog, callback one-shot và cleanup khi dispose. Banner/MREC keyed instance cleanup và route/TickerMode pause có đủ đường dispose. Native AppLovin/AdMob dispose theo widget instance; `AnimationController` của shimmer được dispose.
- **Online/offline:** connectivity subscription có generation token, cancel khi destroy, debounce reconnect và periodic refill; load path kiểm tra network và có watchdog nên không treo UI vô hạn. Fallback optimistic khi detector hỏng vẫn có thể gây request thất bại/backoff nhưng không crash/hang.
- **Consent khác:** UMP chạy trước init ở flow chuẩn; withdrawal TCF được reconcile theo hướng tighten-only; COPPA chặn hẳn AppLovin vì plugin 4.x không có child API và forward đúng GMA tag; ATT được gọi từ splash trước UMP trong example. Điểm chưa đạt là GPP (R34-03) và completion AppLovin (R34-04).
- **Example contract:** `setNavigatorKey` trước `runApp` (`main.dart:54-56`), đăng ký cả hai observer (`:77-78`), init trong splash (`:724-798`), listener/timer splash được remove/cancel (`:831-857`), và App Open có buffer + splash marking. Integration cơ bản đúng.
- **Mediation/platform:** package là Dart facade dựa vào plugin native; AdMob waterfall lấy `ResponseInfo.adapterResponses` được cả Android/iOS plugin 7.0.0 serialize. `gma_mediation_applovin` là optional ở host, không có trong example; fixture pinning chứng minh combo iOS có thể resolve với `gma_mediation_applovin 2.5.2` + override `applovin_max 4.6.0`. Vì vậy example không phải bằng chứng runtime cho AppLovin-as-AdMob-mediation.
- **Secrets:** không tìm thấy Ed25519 private seed hard-code trong working tree hay qua tìm kiếm lịch sử theo các marker private-key/seed. Public key trong binary là đúng thiết kế và không giúp forge. Rủi ro còn lại là replay bearer token, không phải lộ public key.
- **Test ad IDs:** các ID Google public test chỉ nằm trong example; package core không hard-code ad-unit production/test. AppLovin example dùng placeholder/env define.

## Dependency/native SDK

Lock/source thực resolve:

- `google_mobile_ads 7.0.0` → Android `play-services-ads 24.9.0`, UMP 4.0.0; iOS `Google-Mobile-Ads-SDK 12.14.0`.
- `applovin_max 4.6.4` → AppLovinSDK 13.6.3.
- Fixture mediation phải override `applovin_max` xuống 4.6.0/AppLovinSDK 13.5.0 để khớp adapter 2.5.2.

Tại ngày audit, Google đã phát hành Android legacy 25.4.0 và iOS 13.9.0. iOS 13.0.0 có fix crash iOS 26 iPad trong một placement cụ thể; 13.4.0 có cải thiện thread-safety native-ad rendering; Android 25.3.0/iOS 13.3.0 chuyển sang age-restricted treatment API mới. Không tìm thấy CVE công khai cụ thể chứng minh các version đang pin bị khai thác bảo mật, nên tôi không nâng việc “cũ” thành finding riêng. Tuy vậy khoảng cách major này làm tăng maintenance/privacy risk và pinning wall khiến nâng cấp khó. Nguồn: [Google iOS release notes](https://developers.google.com/admob/ios/rel-notes), [Google Android release notes](https://developers.google.com/admob/android/rel-notes).

## Khuyến nghị production

Không approve nguyên trạng. Điều kiện tối thiểu để cân nhắc:

1. Tắt trial Android hoặc chuyển entitlement/redeem sang backend có authority; không tuyên bố chống reinstall bằng Auto Backup.
2. Implement đầy đủ GPP US-state/targeted-advertising opt-out và test provider propagation.
3. Làm AppLovin privacy setters awaitable/verifiable, retry withdrawal thất bại.
4. Khóa `bypassSafety` vào một cold-start splash capability không thể giả mạo bằng tham số.
5. Không ship/copy config verbose của example; bỏ raw GAID khỏi log.
6. Lập ma trận build/device thật cho Android+iOS, cả provider trực tiếp và AdMob→AppLovin mediation, rồi nâng native SDK trong một pinning wall mới đã được build thực.
