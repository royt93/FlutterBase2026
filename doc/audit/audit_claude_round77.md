# Audit Claude round 77 — SDK + example production review

- Ngày: 2026-11-05
- Package: `applovin_admob_sdk` 3.6.8
- Baseline: `5f81af021f6720fc8d6c86929ad1e368d2e55aa7` (`main`)
- Phạm vi: package, example, pub.dev archive, Android/iOS build, provider/ad lifecycle, consent, trial/VIP, policy, production readiness.

## Kết luận

**Chưa duyệt production-wide cho toàn bộ Android/iOS × AdMob/AppLovin. Có thể cân nhắc pilot giới hạn với platform/provider đã được ứng dụng kiểm thử thật.** R76-01 đã được sửa ở checkout và có regression test cho widget remount; native ad load trên thiết bị vẫn chưa được xác minh. Source và automated tests cho thấy SDK có nhiều lớp bảo vệ hữu ích; chúng không chứng minh mọi native lifecycle, memory profile, consent geography hay chính sách ứng dụng thực tế.

Không có cơ sở trong lượt này để gọi SDK độc lập là tuân thủ pháp luật mọi quốc gia. SDK chuyển tiếp một số consent signals; publisher vẫn phải cấu hình CMP/dashboard, disclosures, placements, app-ads.txt và quyền riêng tư theo thị trường, sản phẩm và inventory thực tế.

## Baseline và bản phát hành

- Pub.dev API tại thời điểm kiểm tra: latest `3.6.8`, published `2026-10-31T14:32:11.842110Z`; archive SHA-256 `3e354e40da0156ba94c0dc9d9a4b6f175e316b6c4e29f2cad0bdc9c57231e2c1`, khớp metadata.
- So sánh archive với checkout: `lib/` khác ở `lib/src/core/ad_manager.dart` (checkout có thêm session capture/guard trong đường abandoned UMP form); `example/lib/t257_profile_frame_benchmark.dart` khác (checkout có benchmark channel/status). Có `.DS_Store` chỉ ở checkout. Vì vậy kết quả local không mặc nhiên đại diện byte-for-byte cho pub.dev. Hai khác biệt cần được kiểm tra và phát hành riêng trước khi dựa vào chúng trong production.
- Platform example: Android minSdk 24, iOS deployment target 13.0. Manifest có Google test App ID và AD_ID permission; iOS `Info.plist` có Google test App ID, ATT usage description, SKAdNetwork entries và placeholder AppLovin SDK key. Không tìm thấy app-owned `PrivacyInfo.xcprivacy`; đây là việc cần rà theo API/SDK thực dùng, không tự nó chứng minh vi phạm. AppLovin IDs/key trong example là placeholder.

## Findings và giới hạn

### R76-01 — MINOR — Đã sửa trong checkout; native runtime còn chờ xác minh

`lib/src/widget/native_ad_widget.dart` tăng `_appLovinViewGeneration` khi `controllerRefresh()` qua `canLoadNative`, rồi truyền `ValueKey` cho `_AppLovinMaxNativeView`. AppLovin `MaxNativeAdView` vì vậy được unmount/remount; AdMob path không đổi. Regression tại `test/native_ad_widget_test.dart` bắt state cũ và xác nhận state mới khác sau refresh. Test đỏ khi tạm bỏ generation bump, xanh khi khôi phục. Hai focused widget files: 80 tests pass; SDK full suite: 2,843 tests pass; analyzer sạch và release readiness gate pass. Đây xác nhận widget lifecycle trong Flutter test, không chứng minh ad fill/load callback trên thiết bị. Giữ runtime verification riêng trước khi tuyên bố đã xác nhận đầy đủ AppLovin Native refresh.

### Giới hạn consent và quyền riêng tư

- `applovin_max` consent setters là `void` fire-and-forget (`lib/src/adapters/applovin_bridge.dart:60-64`; gọi tại `applovin_adapter.dart:861-863`); SDK không xác nhận native đã ghi consent. README ghi rõ khả năng hiếm gặp write thất bại sau khi người dùng rút consent.
- GPP decoding hiện chỉ cover US National sale/sharing opt-outs, không cover đầy đủ targeted-advertising/state-specific signals (pub.dev README). Không tuyên bố “mọi quốc gia” chỉ dựa trên UMP/IAB plumbing.
- Google UMP yêu cầu cập nhật consent mỗi lần mở app, gọi form khi cần, gate request bằng `canRequestAds()` và hiện privacy-options entry point khi bắt buộc. SDK có privacy-options API, nhưng host phải đưa entry point ra UI và cấu hình UMP message đúng app ID.
- Banner placement, disclosure/label và vùng tránh nút bấm do host quyết định. AdMob cảnh báo banner gần nút/nội dung tương tác làm tăng accidental clicks.

### Trial, VIP, offline, memory

- Trial release mặc định 24 giờ. iOS Keychain chống reinstall tốt hơn; Android dựa vào Auto Backup và có thể reset trial/redeemed ledger khi clear data, backup tắt hoặc account khác. Không có backend nên không thể bảo đảm chống replay/abuse trên thiết bị do người dùng kiểm soát. Đây là giới hạn thiết kế đã công khai, không phải finding mới.
- Signed VIP dùng Ed25519, expiry/bundle binding và CRL; xác minh chữ ký có thể offline, nhưng kích hoạt key yêu cầu mạng theo product decision. Grant đã cấp hoạt động offline.
- Đọc source cho thấy widgets và timers/subscriptions chủ yếu có cleanup rõ; chưa có leak cụ thể được chứng minh trong lượt này. Không có native heap/memory profile hoặc lặp load-show-dismiss-dispose trên thiết bị; không tuyên bố “không leak”.
- AppLovin không có freshness check tương đương AdMob cho ad đã cache; creative cũ có thể còn được provider giữ.

## Kiểm thử

| Kiểm tra | Kết quả | Giới hạn |
|---|---|---|
| Pub.dev archive | Version/hash xác minh; diff nêu trên | Checkout không đồng nhất hoàn toàn với published archive |
| SDK `flutter analyze lib/ test/ example/lib/` | Pass, 0 issues | Static analysis |
| `./tool/release_readiness_gate.sh all` | Pass | Gate local |
| SDK `flutter test --reporter=compact` | 2,843 passed | Không chứng minh native runtime matrix |
| Example `flutter analyze` | Pass, 0 issues | Static analysis |
| Example `flutter test --reporter=compact` | 72 passed | Widget/demo tests, không phải provider native QA |
| `example`: `flutter build apk --debug` | Pass | Debug build, không phải release signing hoặc ad serving |
| `example`: `flutter build ios --simulator --debug` | Pass | Simulator build, không phải iOS device/ATT/ad lifecycle runtime |
| Physical-device integration, offline/reconnect, AppLovin QA, memory profile | Chưa chạy | Thiết bị đang không truy cập được; AppLovin IDs/key chưa được cung cấp cho run này; không dùng production inventory |

## Production decision

**Không dùng kết quả audit này làm phê duyệt vô điều kiện hoặc đảm bảo compliance.** Pilot có giám sát có thể được cân nhắc cho đúng tổ hợp đã kiểm thử thật; rollback, crash/fill/policy monitoring và owner cấu hình CMP/privacy là bắt buộc. Chưa có cơ sở phê duyệt iOS/AppLovin chỉ từ simulator build và unit tests. Với AppLovin Native refresh, widget remount đã có regression coverage nhưng cần xác minh ad load trên thiết bị trước khi coi runtime đã được chứng minh. Trước production, chạy online/offline/reconnect, consent withdrawal/UMP privacy options, ad dismiss/reward/teardown và memory stress trên thiết bị thật của từng tổ hợp phát hành; dùng test IDs/QA keys.

## Nguồn chính sách tham chiếu

- [Google UMP for Flutter](https://developers.google.com/admob/flutter/privacy)
- [AdMob ad placement guidance](https://support.google.com/admob/answer/6128877)
- [Apple privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
- [Apple third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
- [Pub.dev package release](https://pub.dev/packages/applovin_admob_sdk)
