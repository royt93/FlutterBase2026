# Audit độc lập — `applovin_admob_sdk`

**Lens:** Architecture, Provider Parity & Production Readiness
**Ngày:** 2026-07-16 · **Chế độ:** read-only (không sửa source)
**Cơ sở đối chiếu:** `doc/task/done/T01–T43`, `packages/ad_sdk/README.md` (Known limitations), `doc/feature.md` (Blockers/Checklist/Deferred).

---

## 1. Verdict tổng quan

Về mặt **kiến trúc và provider parity**, đây là một SDK trưởng thành hơn hẳn mức "wrapper mỏng" thông thường: có một abstract contract `AdProviderAdapter` sạch sẽ, hai adapter (AdMob + AppLovin) implement đầy đủ interface, error handling nhất quán (try/catch + `SafeLogger` + slot state machine, không rò exception ra caller), 553/553 test pass, `flutter analyze` sạch. Các race condition khó (consent→init→VIP→first-load, splash hard-cap, ATT/UMP timeout) đã được phát hiện và fix có chủ đích (T29/T40/T42/T43), verify được bằng đọc code hiện tại — tài liệu **khớp** với thực trạng.

Tuy nhiên **production-readiness thì chưa xanh hoàn toàn**, và đa số rủi ro còn lại nằm ở **lớp cấu hình/publish, không phải code**: (a) app đang chạy bằng **local `path` override**, chưa publish `1.0.24` lên pub.dev; (b) **CHANGELOG chưa có mục T43** dù checklist release yêu cầu; (c) host app trộn **ad-unit AppLovin production thật + AdMob test ID**, và **thiếu `applovin.sdk.key` meta-data** trong `AndroidManifest.xml`; (d) UMP form chưa configure (blocker đã biết). Không có finding **Critical** ở tầng code; các finding cao nhất là **High** ở tầng publish/native-config phải xử lý trước khi release doanh thu thật.

**Kết luận ngắn:** dùng được cho production **có điều kiện** — xem mục 4.

---

## 2. Bảng đối chiếu (các mục thuộc lens)

| Hạng mục | Android | iOS | Nhận định |
|---|---|---|---|
| **Provider AdMob** hoạt động | ✅ (test App ID `~3347511713` + test unit) | ✅ (test App ID `~1458002511`) | Adapter đầy đủ; nhưng đang là provider phụ (swap-ready). App ID/unit ID **test** — có chủ đích (T32), phải đổi trước khi bật thật. |
| **Provider AppLovin** hoạt động | ⚠️ code OK, thiếu `applovin.sdk.key` manifest | ✅ (Info.plist có `AppLovinSdkKey`) | Provider **chính** (`AdProvider.appLovin`). MAX init programmatic bằng `cfg.sdkKey` nên chạy được, nhưng manifest thiếu key là lệch integration guide → xem F3. |
| **Banner** parity | ✅ AdMob: adaptive size, load-on-mount, dispose-before-refresh, `visible` notifier | ✅ AppLovin: preload widget-AdView, autoRefresh pause theo route | Hai cơ chế khác nhau (AdMob widget-coupled, AppLovin native AdView) nhưng đều được che sau `BannerListenables` chung. Đúng chuẩn. |
| **App Open** parity | ✅ watchdog 90s + foreground-hung heuristic (Android) | ✅ watchdog 90s, iOS bỏ heuristic foreground | Parity đầy đủ ở cả 2 adapter, kể cả reload-after-show-fail (`beginReload`). |
| **Interstitial / Rewarded** parity | ✅ | ✅ | AppLovin có reload-on-display-fail; AdMob có expiry 1h + reuse-if-fresh. **Không có watchdog inter/rewarded ở cả 2** — accepted risk đã chốt (không re-report). |
| **Reward SSV** parity | ✅ `custom_data` | ✅ `ServerSideVerificationOptions` (userId+customData) | AdMob giàu field hơn (userId + customData riêng); AppLovin chỉ 1 string `custom_data` → adapter fallback `ssvCustomData ?? ssvUserId`. Parity "đủ dùng", có ghi rõ giới hạn. SDK không tự verify (đúng thiết kế). |
| **Revenue callback** parity | ✅ `setPaidEventListener` (fullscreen) + `onPaidEvent` (banner) | ✅ `MaxAd.revenue` mọi callback | Cả 2 emit `AdRevenueEvent`. AppLovin skip khi `revenue<=0` (test mode) — hợp lý. |
| **Consent (GDPR/CCPA/COPPA)** | ✅ AdMob per-request `npa`/RDP/`tagForChildDirectedTreatment` | ✅ AppLovin static `setHasUserConsent`/`setDoNotSell` | COPPA cho **AppLovin**: MAX 4.x không có runtime API → gate init khi `isAgeRestrictedUser` (T40). Gap "app luôn child-directed, install #1" đã ghi rõ — app hiện không child-directed nên chấp nhận được. |
| **Monetization Arbitrator** | opt-in, provider-agnostic | như Android | Không phải bộ chọn provider/fallback waterfall — chỉ là heuristic eCPM-threshold quyết định show-ad-vs-nudge-VIP, session-only, phải host tự bật. Đúng như class doc. **Không có auto-fallback AdMob↔AppLovin runtime** — xem F5. |
| **Native config compliance** | ⚠️ thiếu `applovin.sdk.key`; permissions OK | ⚠️ 50 SKAdNetworkID (README nói ~70) | Xem F3, F4. |

---

## 3. Danh sách phát hiện

> Đã loại các mục đã-biết-có-chủ-đích: test Ad Unit/App ID (T32), thiếu watchdog inter/rewarded (accepted 2026-07-14), COPPA install-#1 gap (T40), UMP form chưa config (Blocker), `dependency_overrides` pin GMA/AppLovin (Deferred, retest ~2026-10). Các mục dưới là **phát hiện mới hoặc lệch tài liệu-vs-code** đã verify.

### High

**F1 — CHANGELOG thiếu mục cho T43 (ATT/UMP timeout), chặn checklist publish.**
`packages/ad_sdk/CHANGELOG.md:18` mục `[1.0.24] - 2026-07-10` chỉ ghi T42 (consent-on-init). Fix **T43** (2026-07-15, bọc `Future.timeout(20s)` quanh 3 await ATT/UMP — xác nhận có trong code: `ad_manager.dart:799` init-timeout 20s + `att_consent.dart`) **không xuất hiện** trong bất kỳ mục 1.0.24 nào. `doc/feature.md` (Checklist mục 3) yêu cầu tường minh "Xác nhận CHANGELOG đã có mục cho 1.0.24 gồm T42 **và T43**". Ngoài ra có mục lạ `## [2.0.0] - Unreleased` (CHANGELOG.md:622) không tương ứng version pubspec (`1.0.24`).
→ *Rủi ro:* publish `1.0.24` với changelog không phản ánh đúng nội dung fix; người tiêu thụ SDK không biết ATT/UMP timeout đã được vá. Phải cập nhật CHANGELOG trước `flutter pub publish`.

**F2 — SDK chưa publish; app đang chạy local `path` override.**
`pubspec.yaml:53-54` active `applovin_admob_sdk: path: packages/ad_sdk`; dòng hosted `# applovin_admob_sdk: ^1.0.23` (pubspec.yaml:51) đang comment. `packages/ad_sdk/pubspec.yaml:3` là `version: 1.0.24` — **chưa tồn tại trên pub.dev** (README.md:99 xác nhận public line mới tới 1.0.23; 1.0.21/1.0.22 chưa từng publish). Nghĩa là toàn bộ fix T21→T43 **chỉ sống trong repo**.
→ *Rủi ro:* nếu release app bằng bản hosted `1.0.23` hiện tại (như CLAUDE.md mô tả contract), app sẽ **thiếu** T42 (consent bị quên mỗi lần mở app) và T43 (ATT/UMP treo) — hai lỗi nghiêm trọng đã fix nhưng chỉ có ở local path. Bắt buộc publish `1.0.24` **rồi** flip pubspec trước release, hoặc release thẳng bằng path override (kém chuẩn cho một app store build).

**F3 — `AndroidManifest.xml` host thiếu `applovin.sdk.key` meta-data.**
`grep applovin android/app/src/main/AndroidManifest.xml` → không có match. Provider chính là AppLovin (`splash_screen.dart:218 provider: AdProvider.appLovin`). CLAUDE.md nêu rõ "AppLovin also needs `applovin.sdk.key` meta-data". Hiện MAX được init programmatic (`applovin_adapter.dart:162 _bridge.initialize(cfg.sdkKey)` với `sdkKey` từ `ad_keys.dart:26`), nên **hôm nay vẫn chạy được** — nhưng đây là lệch integration guide chính thức của AppLovin, và một số phiên bản `applovin_max`/mediation adapter đọc key từ manifest lúc `Application.onCreate`. iOS thì Info.plist **có** `AppLovinSdkKey` (dù comment nói runtime không dùng).
→ *Rủi ro:* fragile — nếu bản `applovin_max` tương lai yêu cầu manifest key, hoặc mediation adapter native khởi tạo sớm hơn Dart, banner/ad có thể im lặng không fill trên Android. Nên thêm `applovin.sdk.key` vào manifest cho khớp guide.

### Medium

**F4 — iOS `SKAdNetworkItems` chỉ có 50 entry, README yêu cầu ~70.**
`ios/Runner/Info.plist` đếm được 50 `SKAdNetworkIdentifier`; `README.md:1147` (và Deferred trong feature.md) nói danh sách chuẩn AdMob "roughly 70 entries" và cần recheck yêu cầu SKAdNetwork của AppLovin MAX mediation partners trước khi release App Store.
→ *Rủi ro:* thiếu SKAdNetworkID → một số mạng mediation không attribute được install trên iOS 14.5+, giảm fill/doanh thu iOS. Không chặn build, nhưng nên bổ sung danh sách đầy đủ (AdMob iOS14 guide + AppLovin partner list) trước release iOS.

**F5 — Không có fallback provider runtime AdMob↔AppLovin.**
`ad_manager.dart:784 config.isAdMob ? AdMobAdapter() : AppLovinAdapter()` — provider là lựa chọn **app-wide tĩnh** tại init. Nếu provider đang chọn init fail (`ok=false` tại `ad_manager.dart:804`), SDK **không** tự thử provider còn lại; toàn bộ ad surface tắt cho phiên đó. Đây là quyết định kiến trúc (single provider), phù hợp với ghi chú "shadow eCPM / per-slot routing out of scope" trong feature.md — nhưng cần hiểu rõ: không có redundancy monetization giữa 2 mạng.
→ *Rủi ro:* thấp về vận hành (init fail hiếm), nhưng là kỳ vọng sai nếu ai đó tưởng "dual-provider = tự động waterfall". Chỉ cần document rõ, không cần code.

### Low

**F6 — `ad_manager.dart` là god-file 2148 dòng.**
Đơn file lớn nhất SDK (kế đó `vip_redeem_screen.dart` 1229). Nó gánh orchestration + consent + VIP gating + lifecycle observer + retry timers + arbitrator hook. Còn maintainable (đặt tên tốt, comment dày) nhưng đã tới ngưỡng nên tách (ví dụ tách consent-plumbing và lifecycle-observer ra file riêng).
→ *Rủi ro:* bảo trì dài hạn; không ảnh hưởng publish.

**F7 — Trùng lặp logic nhỏ giữa 2 adapter (chấp nhận được).**
Pattern reload-on-hidden/`beginReload`-on-display-fail, wiring click→`recordAdClick`→emit, expiry-reuse gần như song song ở cả `admob_adapter.dart` và `applovin_adapter.dart`. Do hai native API khác nhau nên khó share thêm mà không tạo abstraction gượng ép (đúng tinh thần không over-engineer). Chỉ ghi nhận, không đề xuất refactor gấp.

---

## 4. Kết luận — Có nên dùng SDK này cho production ngay bây giờ?

**CÓ ĐIỀU KIỆN.** Bản thân code SDK đã đủ chín cho production (parity tốt, error-handling nhất quán, 553/553 test xanh, race conditions đã vá và verify khớp tài liệu). Không có blocker ở tầng code. Nhưng **không được release app ngay ở trạng thái hiện tại** — phải hoàn tất các điều kiện sau, theo thứ tự ưu tiên:

1. **(F1) Cập nhật CHANGELOG cho `1.0.24`**: thêm mục T43 (ATT/UMP timeout) và dọn mục `[2.0.0] - Unreleased` lạc lõng, **trước khi** publish.
2. **(F2) Publish `packages/ad_sdk` 1.0.24 lên pub.dev, rồi flip `pubspec.yaml`** sang hosted `^1.0.24` (bỏ comment hosted, comment lại `path`), chạy `flutter pub get` xác nhận app build bằng bản hosted. **Tuyệt đối không release bằng hosted `1.0.23`** — sẽ mất fix T42/T43. (Lệnh publish do user tự chạy — cần login pub.dev.)
3. **(F3) Thêm `applovin.sdk.key` meta-data** vào `android/app/src/main/AndroidManifest.xml` cho khớp integration guide AppLovin.
4. **Đổi test → production Ad Unit/App ID** (AdMob 2 App ID theo platform + bộ unit; AppLovin unit đã là production thật nhưng cần double-check), và **publish UMP consent form** trên AdMob console (Blocker đã biết) trước bản EEA.
5. **(F4) Bổ sung `SKAdNetworkItems`** đầy đủ (~70 + partner của AppLovin) trước release iOS.

F5/F6/F7 là ghi nhận kiến trúc, **không chặn** release. Sau khi xong 1–5, nên theo đúng khuyến nghị README: pilot traffic nhỏ, theo dõi dashboard AdMob/AppLovin vài tuần trước khi tích hợp diện rộng.

---

## Re-verify — 2026-07-16

- **F1 (CHANGELOG thiếu T43) — ✅ ĐÃ FIX.** `CHANGELOG.md` mục `[1.0.24]` giờ có `### Fixed — ATT/UMP consent native awaits could hang initialize() forever (T43)`. Đồng thời phát hiện thêm (mới, không thuộc audit gốc): phần `## [Unreleased]` phía trên đang chứa fix T44 + CCPA toggle + SKAdNetwork — nhưng các fix này **đã được publish** làm một phần của `1.0.24` thật (xác nhận qua commit `1703280`: "now that 1.0.24 (T44 fix + SKAdNetwork expansion + doc corrections) is live on pub.dev"). Đã sửa: merge nội dung "Unreleased" vào mục `[1.0.24]`, để lại `[Unreleased]` trống — nhãn cũ sai lệch so với thực tế publish.
- **F2 (chạy local path, chưa publish) — ✅ ĐÃ FIX.** `pubspec.yaml` (root) dòng 51 giờ active `applovin_admob_sdk: ^1.0.24` (hosted), dòng `path:` bị comment. Xác nhận qua commit `1703280` (2026-07-16) — flip diễn ra sau khi `1.0.24` đã publish thật lên pub.dev.
- **F3 (thiếu `applovin.sdk.key` manifest) — ✅ ĐÃ FIX.** `grep -n "applovin.sdk.key" AndroidManifest.xml` → có match tại dòng 65. (Audit gốc grep không ra kết quả tại thời điểm đó; đã được thêm sau.)
- **F4 (SKAdNetwork 50 entry) — ✅ ĐÃ FIX.** `grep -c SKAdNetworkIdentifier ios/Runner/Info.plist` → 152 (danh sách đầy đủ AppLovin, thay cho danh sách rút gọn 50 trước đó).
- **F5, F6, F7 — không đổi**, đúng như đánh giá gốc: ghi nhận kiến trúc, không chặn release.

**Kết luận sau re-verify: cả 4/5 điều kiện blocking ban đầu (F1-F4) đã đóng.** Điều kiện #4 còn lại của mục "Kết luận" gốc (đổi test→production Ad Unit/App ID cho AdMob + publish UMP form trên console) là thao tác **vận hành tay trên console AdMob/AppLovin**, không phải code — nằm ngoài phạm vi sửa qua source, cần người dùng tự thực hiện trước khi bật AdMob thật ở EEA.
