# Audit độc lập `applovin_admob_sdk` (packages/ad_sdk) — 2026-08-15

**Người audit:** Claude subagent (general-purpose), đọc source trực tiếp + 3 sub-audit song song (fork, cùng context) cho `lib/`, `test/`, `example/+CI+docs`.
**Phiên bản tại thời điểm audit:** `packages/ad_sdk` = 2.0.4 (2026-08-09), pub.dev 150/160.
**Baseline đã đọc trước khi audit** (để không báo lại issue đã đóng): `doc/task/README.md` (T01-T56 done), `doc/audit/audit_full_20260711.md`, `doc/audit/audit_claude_20260802.md` (C1-C7, đã fix toàn bộ trong 2.0.0, xem CHANGELOG), `doc/audit/release_1_2_4_and_ci_findings_20260801.md`, `doc/audit/audit_example_app_20260808.md` (example app: không finding Critical/High).

**Lưu ý về phạm vi khi viết bản này:** báo cáo tổng hợp từ 2/3 sub-audit đã hoàn tất đầy đủ (`lib/` deep-dive, `test/` coverage). Sub-audit thứ 3 (`example/` + CI workflow + docs/pinning) **chưa trả kết quả tại thời điểm file này được viết** — mục 3 và 4 dưới đây có bổ sung từ việc tôi tự đọc trực tiếp `CLAUDE.md` (mục "Publishing to pub.dev") và `release_1_2_4_and_ci_findings_20260801.md`, nhưng KHÔNG có một lượt đọc kỹ độc lập mới của `example/lib/main.dart`/`.github/workflows/test.yml` ở phiên này — phần đó kế thừa nguyên trạng kết luận của `audit_example_app_20260808.md` (đã dẫn nguồn). Nếu cần độ phủ đầy đủ hơn cho riêng mục CI/example, nên chạy bổ sung.

---

## 1. Bug cần fix

**1.1 — AdMob: slot fullscreen "ready" không bao giờ được chủ động refresh khi cache hết hạn, dẫn tới `show()` fail âm thầm đúng lúc user bấm xem**
`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:401-436` (`isAdFresh`, `_fullscreenExpiryHours` = 1h, `_appOpenExpiryHours` = 4h) chỉ được consult **bên trong** `loadX()`. `_retryRefillAds` (`lib/src/core/ad_manager.dart:2965-2973`) chỉ gọi lại `loadX()` khi slot đang `idle`/`cooldown`, không bao giờ khi slot đang `ready`. Nếu interstitial/rewarded/appOpen load xong nhưng không được show trong >1h (>4h với appOpen), object cache stale nhưng slot vẫn báo `ready` — native `show()` fail đúng lúc user bấm, mất impression không lý do rõ ràng cho host. AppLovin không bị vì MAX SDK tự refresh cache nội bộ.
Effort: M. Priority: P1.

**1.2 — AdMob: banner đặt ở route đầu tiên của app (trường hợp tích hợp phổ biến nhất) có thể không bao giờ hiện**
`packages/ad_sdk/lib/src/widgets/banner_ad_widget.dart:53,116-133,236-244` — `_admobIsTop` khởi tạo `false`, chỉ set `true` trong `didPush()`/`didPopNext()` của `RouteObserver`. Theo hành vi chuẩn Flutter, route đầu tiên đã được push xong TRƯỚC KHI widget con kịp gọi `adRouteObserver.subscribe()` ở `didChangeDependencies` — `didPush()` không bao giờ chạy cho route đó. Banner AdMob ở Home/màn hình đầu sẽ mãi hiện placeholder rỗng cho tới khi user điều hướng đi rồi quay lại (trigger `didPopNext`). Test hiện có chỉ cover push/pop MỘT route TRÊN banner, chưa cover "banner ở route đầu tiên".
Effort: S/M (cần viết test xác nhận trước khi fix). Priority: P1.

**1.3 — Dialog consent built-in không clear `_footgunBlocked` khi host tự set `autoRequestUmpConsent: false` — phần dư sót lại của C1 (audit 20260802) chưa đóng hết**
`consent_manager.dart:136` (`showDialog` → `_setInternal`) chỉ gọi `_persist()` + `_applyToProviders()`, không đụng `AdManager._footgunBlocked`. Cờ này chỉ được clear trong `AdManager.setConsent()` (`ad_manager.dart:1597-1599`). CHANGELOG 2.0.0 chỉ đổi **default** `autoRequestUmpConsent` → `true` khiến footgun không trip ở cấu hình mặc định, nhưng KHÔNG sửa đường dây dialog built-in. Một host cố ý đặt `autoRequestUmpConsent: false` (tự chạy UMP lúc khác) nhưng quên gọi `requestUmpConsent()`/`setConsent()` thủ công, dựa vào dialog built-in (`autoShowConsentDialog: true`, mặc định) — vẫn bị khoá `canRequestAds` vĩnh viễn ở release ngay cả sau khi user trả lời dialog. Đây chính xác là lỗi C1 cũ, thu hẹp còn đúng 1 tổ hợp cấu hình chưa được vá.
Effort: S. Priority: P1.

**1.4 — `suspiciousViolationCount` trong snapshot/compliance report không decay, trong khi `policyRiskScore` từ cùng dữ liệu có decay — hai số liệu không nhất quán**
`ad_safety_config.dart:640-655` (`getStatusSnapshot`) đọc thẳng field `_suspiciousViolationCount` chưa decay; decay (`_decayViolationCount`, dòng 664-678) chỉ chạy bên trong `_triggerSuspiciousPause`, tức chỉ khi có vi phạm TIẾP THEO. `policyRiskScore`/`_computeRiskScore()` (dòng 734-757) decay đúng, live mỗi lần đọc. Kết quả: 1 vi phạm xảy ra rồi user hành xử tốt mãi mãi → `ComplianceReport` vẫn báo `suspiciousViolationCount` cũ vĩnh viễn dù risk score đã gần 0.
Effort: S. Priority: P2.

**1.5 — Reconnect handler chỉ `preloadBanner()`, bỏ sót `preloadMrec()`/`preloadNative()` cho AppLovin**
`ad_manager.dart:2936-2940` (`_onConnectivityChanged` debounce callback) chỉ gọi `_adapter?.preloadBanner()`. Với AdMob hai hàm kia no-op nên vô hại, nhưng với AppLovin (`preloadMrec`/`preloadNative` thực sự cache trước) — MREC/Native không được refill chủ động ngay khi mạng về; chỉ nạp lại khi widget tương ứng tự rebuild qua `initRevision` (nếu đã mounted). Nếu host preload MREC/Native mà chưa mount widget, cache vẫn trống sau một đợt mất mạng.
Effort: S. Priority: P2.

---

## 2. Enhancement (cải thiện tính năng đã có)

**2.1 — `VipManager` ghi SharedPreferences ở mỗi lần đọc getter `expiresAt` tưởng chừng read-only**
`vip_manager.dart:169-177` — mỗi lần đọc `.expiresAt` sẽ `unawaited(_prefs.setVipMaxObservedClockMs(...))` trừ khi đồng hồ bị lùi (đây là cơ chế chống clock-rollback, đúng chủ đích). Code mẫu hiện tại (`vip_redeem_screen.dart:216-219`) không polling field này nên chưa gây vấn đề thật, nhưng là side-effect bất ngờ cho một getter tưởng read-only — nếu host tự viết UI polling `vip.expiresAt` mỗi giây/frame sẽ tạo ghi đĩa dư thừa không cần thiết.
Effort: S. Priority: P2.

**2.2 — Ngưỡng stale-cache của AdMob (1h fullscreen / 4h appOpen) là hằng số private, không cấu hình qua `AdConfig`**
`admob_adapter.dart:401,406`. Nên gộp chung với fix 1.1: expose ngưỡng qua `AdConfig` + thêm sweep định kỳ trong `_retryRefillAds` chủ động drop+reload slot `ready` quá hạn, thay vì chờ `show()` fail mới lộ ra.
Effort: S. Priority: P2.

**2.3 — Chu kỳ retry-refill timer cố định 5 phút, không cấu hình được**
`ad_manager.dart:90` (`_retryIntervalMs`). Host có phiên ngắn (game casual) muốn backstop nhanh hơn, hoặc muốn tiết kiệm pin bằng chu kỳ dài hơn, hiện không có cách chỉnh ngoài việc không dùng tính năng.
Effort: S. Priority: P2.

---

## 3. Task mới / nợ kỹ thuật

**3.1 — Bug đã fix ở CHANGELOG 2.0.1 (`_isInternalInitRetryCall` bị kẹt `true`) không có regression test**
CHANGELOG 2.0.1 mô tả: retry timer bắn trong khi một `initialize()` khác đang giữ busy guard khiến `_isInternalInitRetryCall` (`ad_manager.dart:523,1022-1023,1478`) kẹt `true`, khiến lệnh `initialize()` thật tiếp theo bị hiểu nhầm là internal retry. Grep toàn bộ `test/*.dart` cho tên biến này → 0 kết quả. `ad_manager_core_test.dart:1025-1053` có test gần giống ("onComplete single-fire") nhưng là nhánh khác (đếm số lần fire), không phải kịch bản 2 lệnh `initialize()` chồng lấn. Một regression thật đã fix nhưng không gì ngăn nó tái diễn nếu ai refactor logic init.
Effort: S. Priority: P1.

**3.2 — Thiếu test cho "banner AdMob ở route đầu tiên" (đi kèm bug 1.2)**
Cần 1 `testWidgets` mount `BannerAdWidget` trực tiếp làm `home:` (không push route nào) với provider AdMob, assert view thật được render — hiện `banner_ad_widget_test.dart` chưa có case này.
Effort: S. Priority: P1.

**3.3 — Thiếu test cho tổ hợp `autoRequestUmpConsent:false` + dialog built-in (đi kèm bug 1.3)**
Chưa có test dựng `AdManager` với `autoRequestUmpConsent: false`, trigger footgun, rồi verify `canRequestAds` sau khi dialog built-in trả lời — gap này sống sót qua nhiều vòng audit vì chưa từng có test khoanh vùng đúng tổ hợp.
Effort: S. Priority: P1.

**3.4 — CI không track code coverage — con số 66.4% (audit 20260711) là đo thủ công một lần, không lặp lại được**
`.github/workflows/test.yml` job `sdk` chạy `flutter test` trần, không có `--coverage`. Không ai biết coverage hiện tại đã tăng hay giảm so với con số cũ; các cải thiện coverage thật đã xảy ra (xem 3.6) không được đo lại bằng số cụ thể theo thời gian, chỉ verify được bằng cách đếm dòng test thủ công mỗi lần audit.
Effort: S. Priority: P2.

**3.5 — Dependency/version pinning risk: nâng Flutter để lấy `google_mobile_ads` 8/9 (10 điểm pub.dev cuối) chưa có ticket theo dõi**
Theo CLAUDE.md mục "Publishing to pub.dev": GMA 8 và 9 cần Dart `>=3.10.0` + Flutter `>=3.38.1`, vượt sàn CI hiện tại (Flutter 3.35.1 pin, Dart 3.9.x) — nâng sẽ kéo theo nâng `environment.flutter` của chính package này, tức breaking change (major version mới) cho consumer, không phải một lần bump dependency đơn thuần. `doc/task/README.md` (T01-T56) không có mục nào theo dõi việc này — chỉ tồn tại rải rác trong các audit doc (`release_1_2_4_and_ci_findings_20260801.md` mục "Việc còn mở" A). Rủi ro: quyết định quan trọng (khi nào bump major, thông báo consumer thế nào) đang chỉ sống trong audit log, không có backlog item chính thức.
Effort: L (quyết định release, không phải code). Priority: P2.

**3.6 — [Ghi nhận tích cực, không phải finding mới] Coverage 0% cũ (`vip_dialog.dart`, `consent_manager.dart`, `applovin_bridge.dart`, `gma_bridge.dart` — audit 20260711) đã được lấp đầy tại 2.0.4**
`consent_manager_test.dart` (222 dòng/11 test), `applovin_bridge_test.dart` (112 dòng/9 test), `gma_bridge_test.dart` (148 dòng/6 test), `vip_dialog_test.dart` (89 dòng/3 test) — không còn file lib nào ở mức 0% test. Ghi lại để tránh audit sau lặp lại finding đã đóng; điểm 3.4 (thiếu đo coverage định kỳ) vẫn là gap thật độc lập với việc này.
Effort: — (informational). Priority: —.

**3.7 — CI/example: chưa xác minh lại trong phiên audit này — kế thừa `audit_example_app_20260808.md`**
Sub-audit riêng cho `example/` + `.github/workflows/test.yml` + doc/pinning không kịp hoàn tất trong phiên. Theo `release_1_2_4_and_ci_findings_20260801.md` (mục "Còn mở"), root cause của hang launch job iOS Simulator trên CI vẫn **chưa xác định** (chỉ bị chặn bằng shell watchdog + retry-with-log, không phải chữa tận gốc — nghi ngờ mạnh nhất là `apsd`/`diagnosticd` dội log trên runner GitHub, thuộc phía Apple, khó sửa từ repo). Đây là task còn mở thật, nên giữ nguyên trong backlog, không phải finding mới của phiên này.
Effort: L (phụ thuộc hạ tầng ngoài repo). Priority: P2.

---

## 4. Ý tưởng tính năng mới

**4.1 — VIP ladder "xem N ads hôm nay = +giờ VIP", cấu hình qua `AdConfig`**
Mở rộng flow `bypassVipGuard` hiện có (đơn lẻ, cố định 1 lần xem = 1 duration cố định) thành ladder cấu hình được (vd: xem 3 ads/ngày → +6h VIP). Tăng engagement + revenue mà không cần backend, tận dụng đúng hạ tầng VIP/rewarded đã có.
Effort: M. Priority: P2.

**4.2 — Safety cap theo từng `AdPlacement`, không chỉ theo loại ad**
Hiện `AdSafetyConfig` áp cap toàn cục theo loại ad (interstitial/rewarded/appOpen), không phân biệt placement (vd: splash vs. sau khi hoàn thành 1 tác vụ trong app). Cho phép cap riêng theo placement giúp host tinh chỉnh UX chi tiết hơn mà không phải tắt cap toàn SDK.
Effort: M. Priority: P2.

**4.3 — Helper bucketing A/B experiment nhẹ, deterministic per-install, không cần remote-config SDK riêng**
`AdManager().experimentBucket(key, buckets: n)` tận dụng đúng GAID/install-id đã có sẵn trong SDK, giúp host A/B test tham số `AdSafetyParams`/arbitrator threshold mà không cần tích hợp thêm dependency remote-config.
Effort: L. Priority: P2.

---

## 5. Tính năng độc quyền / flagship (differentiator)

**5.1 — CRL (revocation list) nhẹ, ký offline, cho VIP key đã bị lộ**
SDK đã có VIP key Ed25519 offline-verified với expiry + bundle-id binding (AVP2, từ 2.0.0) — khái niệm mà AppLovin MAX raw/Google Mobile Ads raw/wrapper khác không có. Giới hạn còn lại đã biết (README tự nhận): 1 key lộ ra vẫn dùng được vĩnh viễn, không có kênh thu hồi. Ý tưởng: host fetch định kỳ (1 lần/ngày, cache local, fail-open nếu không mạng) một JSON nhỏ ký bởi cùng private key, chứa danh sách `kid` bị revoke — vẫn "chủ yếu offline" đúng tinh thần thiết kế hiện tại, đóng nốt lỗ hổng doanh thu lớn nhất còn lại của mô hình VIP không server.
Effort: M/L. Priority: P2.

**5.2 — Cryptographically signed, exportable Compliance Report — tamper-evident audit artifact**
SDK đã có `ComplianceReport` export (T23) và hạ tầng ký Ed25519 (VIP key). Ý tưởng: ký luôn compliance report xuất ra bằng cùng khóa, tạo artifact tamper-evident host có thể trình cho team pháp lý/policy review của AdMob/AppLovin khi bị flag — chữ ký chứng minh report không bị chỉnh sửa sau khi xuất. Không SDK ads nào khác trên pub.dev có tính năng này.
Effort: M. Priority: P2.

**5.3 — "Fill-rate regression detector" tự chẩn đoán, chạy hoàn toàn client-side, không cần backend**
SDK đã có `FillRateMonitor`/`AdDiagnostics`/`policyRiskScore` (dashboard sống, per-device). Ý tưởng mở rộng: so sánh fill-rate/eCPM phiên hiện tại với baseline 7 ngày lưu cục bộ trên chính thiết bị, tự động cảnh báo "fill rate ad unit X giảm Y% so với baseline của thiết bị này" ngay trong debug/compliance overlay — điều mà dashboard AppLovin/AdMob thật cần backend để làm, ở đây chạy per-device, không cần server, nhất quán với hướng thiết kế "offline-first" đã chọn xuyên suốt SDK này (VIP Ed25519 offline, safety layer client-side).
Effort: M. Priority: P2.

---

**Tổng kết số lượng:** Bug: 5 · Enhancement: 3 · Task/nợ kỹ thuật: 7 (gồm 1 mục thông tin không tính priority) · Ý tưởng mới: 3 · Flagship: 3. Tổng 21 item (20 item có priority).

Tạo bởi: Claude subagent (general-purpose), ngày 2026-08-15.
