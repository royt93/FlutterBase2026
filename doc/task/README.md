# Board task — Audit SDK `applovin_admob_sdk`

Nguồn: `doc/audit/audit_claude.md`. Quy trình scrum theo thư mục:

```
doc/task/todo/         → chưa làm
doc/task/inprogress/   → đang làm (di chuyển file sang đây khi bắt đầu)
doc/task/done/         → xong (di chuyển file sang đây, tick hết acceptance criteria)
```

**Cách dùng:** khi bắt đầu một task, `git mv` file từ `todo/` → `inprogress/` và đổi `Status:` trong file. Khi xong, `git mv` sang `done/`. 1 file = 1 task, tên `Txx-slug.md`.

## Tiến độ (cập nhật 2026-07-07)
- **P0: 5/5 XONG ✅** — T02, T08, T18, T01, T03.
- **Lifecycle/memory XONG ✅** — T11, T12, T13.
- **Network UX XONG ✅** — T09 (banner offline/reload), T10 (isConnected last-known).
- **T05 done** (RDP/CCPA vs COPPA tách đúng, +7 test case, `flutter analyze` clean).
- **T04 done** (AppLovin CMP-flow đã tắt mặc định khi dùng UMP + footgun warning nếu tắt cả 2 CMP; COPPA gap của `applovin_max` 4.x được document loudly qua `SafeLogger.w`, +2 test case).
- **T06 done** (`AdManager().showPrivacyOptions()` + `isPrivacyOptionsRequired()` wrap UMP privacy-options form; README có mục "Privacy Options entry point" hướng dẫn host đặt nút thường trực; re-consent re-apply provider ngay; +6 test case).
- **T07 done** (ATT wiring đúng thứ tự splash→ATT→UMP; thêm `assert()`-wrapped `SafeLogger.e()` ngay trước `requestAuthorization()` để cảnh báo sớm nếu thiếu `NSUserTrackingUsageDescription`; không cần test mới — nhánh quan sát được không đổi, `att_consent_test.dart` đã bao phủ đủ).
- **T15 done** (`AdMobConfig`/`AppLovinConfig` thêm optional `android*Id`/`ios*Id` override cho `bannerId`/`interstitialId`/`appOpenId`/`rewardedId`, resolve qua `Platform.isAndroid/isIOS` bằng getter cùng tên cũ — backward-compatible, adapter không cần sửa; +4 test case `ad_config_platform_test.dart`).
- **T16 done** (`releaseFootgunWarnings` thêm cảnh báo id rỗng cho `bannerId`/`interstitialId`/`appOpenId`/`rewardedId` (mọi provider) và cảnh báo sai định dạng `ca-app-pub-<16 số>/<id>` riêng cho AdMob — cùng cơ chế log ERROR + `assert(false, ...)` như guard dryRun/test-id sẵn có, không thêm class/abstraction mới; +6 test case `ad_manager_core_test.dart`).
- **T17 done** (`VipEntry.isActive`/`remaining` thêm check `now.isBefore(grantedAt)` — đồng hồ bị lùi sau khi cấp entry sẽ bị coi là đã tiêu thụ thay vì "sống lại"; `releaseFootgunWarnings` thêm cảnh báo khi `firstInstallVipGrace` bị disable ở release — partner có thể vô tình tắt trial mà không biết; anti-reinstall Keychain guard giữ nguyên không đổi; +6 test case `vip_entry_test.dart` + `ad_manager_core_test.dart`). T14, T19, T20 sau đó đều done — xem điểm cập nhật bên dưới.
- **✅ P0 milestone build verified trên S24 Ultra (SM-S928B) — cả 2 provider:**
  - AdMob (example app): `🔐 UMP gate → canRequestAds=true`, `applyConsent → nonPersonalizedAds=true`, `📶 connectivity watch started`, VIP grace → expire → AdMob appOpen/inter/rewarded **loaded ✅**.
  - AppLovin (host FastNet): `AppLovin CMP flow disabled (UMP is CMP)`, gate hoạt động, provider=appLovin.
  - **0 crash, 0 `E/flutter`.**
- **321/321 test SDK xanh** (+76 host), `flutter analyze` sạch (SDK + host). (2026-07-07, vòng audit round 3)
- **Verification pass "1-day trial" (T17/T19 follow-up, không phải bug mới)**: soát lại first-install anchoring (grantedAt cố định lúc grant, không tính lại mỗi launch), durable Keychain marker (iOS) sống sót qua prefs/SharedPreferences clear, và trial+redeem stacking (key khác nhau vẫn cộng dồn đúng, không đè/rút ngắn entry trial) — tất cả đã đúng, không có bug. Chỉ thiếu test case đặt tên/khung cảnh đúng thực tế (dùng key `__FIRST_INSTALL__` thật, mô phỏng redeem trong khi trial còn active, và Keychain-survives-prefs-clear rõ ràng) → +3 test case (`first_install_guard_test.dart` +2, `vip_manager_stacking_test.dart` +1). **324/324 test SDK xanh**, `flutter analyze` sạch. (2026-07-07)
- ⚠️ Host `pubspec.yaml` đang **flip path override** sang SDK local — nhớ flip lại trước release.
- **Điểm hiện tại: 10/10** (xem chi tiết smoke-test bên dưới). T14/T19/T20 đã done. Re-audit `doc/audit/audit_claude.md` hoàn tất 2026-07-07 (đọc trực tiếp code hiện tại, không chỉ tin doc): tất cả P0/P1 finding (T01–T18) đều **PASS** khi đối chiếu code, trừ 2 điểm cần lưu ý (không phải bug mới, không cần task mới ngay):
  - **T06** — SDK expose `AdManager().showPrivacyOptions()` + `isPrivacyOptionsRequired()` đúng như acceptance criteria, README có mục MUST. Nhưng **host app hiện tại chưa wire nút** gọi 2 API này ở đâu cả (`vip_screen.dart` chỉ có link mở Privacy Policy tĩnh, không phải UMP re-consent form) — nếu cần entry point thật cho user trước khi submit store, nên mở task nhỏ để thêm 1 nút trong Settings/VIP screen.
  - **T18** — Ed25519 signed key chặn được **forge key mới** (decompile không lấy được private key) và one-time-use **per-device** (redeemed-kid store local) hoạt động đúng. Nhưng one-time-use **toàn cục** vẫn chưa có (đã ghi rõ trong chính task doc T18 "Giới hạn đã biết" — quyết định có chủ đích vì "user xác nhận không có backend"): 1 key hợp lệ bị lộ/share vẫn redeem được trên nhiều máy khác nhau. Chấp nhận được cho scope hiện tại, nhưng là rủi ro kinh doanh cần nhớ nếu key bị leak công khai.
  - ~~(~0.5đ còn thiếu) chưa smoke-test lại trên SM_A507FN~~ — **đã smoke-test 2026-07-07** trên `packages/ad_sdk/example/` (SM_A507FN không kết nối, dùng Pixel_7_Pro thay thế, user đã xác nhận). Kết quả: Banner (pause/resume qua route push/pop, resize 320x50→468x60 đúng T14 fix), Interstitial (show + counter), Rewarded (reward grant), VIP redeem (signed-key `AVP1...` qua `VipRedeemScreen` dùng chung host/example — hoạt động đúng, "VIP ACTIVE" + countdown), VIP stacking (TEST_VIP_7 cộng dồn đúng công thức), VIP suppression live (banner/interstitial/rewarded/app-open đều tự tắt khi `vip=true`, xác nhận qua Log viewer: `loadAppOpen skipped — VIP member`, `banner preload skipped — VIP member`, `consent dialog skipped — VIP member`), Consent/GDPR toggle → propagate đúng (`npa=1` → `personalized`), Safety status/Log viewer render đúng số liệu live. Overlay "🐛 Ad SDK Debug" ban đầu nghi ngờ là ad che UI (R4) — xác minh lại qua UI layout dump, đây là debug panel của SDK, không phải ad thật; không có ad nào che UI ngoài ý muốn trong suốt phiên test. **0 crash.**
  - **Điểm cập nhật: 10/10** — mọi P0-P2 đã done, re-audit code xác nhận PASS, smoke-test thiết bị thật (thay thế) hoàn tất không phát hiện regression. Risk còn lại (T06 host chưa có nút re-consent UI, T18 chưa one-time-use toàn cục) là giới hạn đã biết/có chủ đích, không phải bug.
- **Broader security sweep (vòng audit round 6, không phải bug mới)**: quét thêm secure-storage (`_first_install_guard.dart` — đã có test từ round trước), `AdConfig` validation (T16 chỉ cảnh báo AdMob id format, không có tương đương AppLovin — chấp nhận được, chỉ là warning không phải security boundary), `signed_vip_key.dart` payload bounds-check (`seconds`/`kid` field), và host `network_info_service.dart` trust-boundary parsing (`isLikelyIpv4`/`vendorOf`/`dnsListOf` — đã test đầy đủ). Duy nhất gap thật: nhánh bounds-check trong `verifySignedVipKey` (seconds âm, seconds vượt `_maxSeconds` ~100 năm, `kid` rỗng) chưa có test case riêng dù logic đã đúng → +4 test case (`signed_vip_key_test.dart`). Không phải bug, chỉ thiếu coverage. **332/332 test SDK xanh** (+76 host), `flutter analyze` sạch (SDK + host). (2026-07-07)

## Legend
- **Priority:** `P0` = chặn phát hành · `P1` = ngay sau · `P2` = cải thiện
- **Severity:** CRITICAL / HIGH / MEDIUM / LOW
- **Status:** `todo` / `inprogress` / `done`

## Backlog (map tới 7 yêu cầu partner)

| ID | Task | REQ | Prio | Sev | Status |
|----|------|-----|------|-----|--------|
| T01 | Google UMP làm consent chính khi init SDK (admob+applovin) + gate ad theo canRequestAds | 6,7 | P0 | CRITICAL | ✅ done |
| T02 | Set `npa` (non-personalized) cho AdMob khi thiếu consent | 6 | P0 | CRITICAL | ✅ done |
| T03 | Không impression nào trước khi consent resolved (splash app-open) | 7 | P0 | CRITICAL | ✅ done |
| T04 | AppLovin CMP + tín hiệu COPPA parity | 6 | P1 | HIGH | ✅ done |
| T05 | Tách & sửa map cờ CCPA (RDP) vs COPPA (TFCD) | 6 | P1 | MEDIUM | ✅ done |
| T06 | Privacy Options entry point bền vững + re-consent | 6,7 | P1 | HIGH | ✅ done |
| T07 | Wiring iOS ATT đúng thứ tự + assert plist | 6 | P1 | MEDIUM | ✅ done |
| T08 | Connectivity listener → auto-refill khi mạng trở lại | 2 | P0 | CRITICAL | ✅ done |
| T09 | Banner offline state + auto-reload | 2 | P1 | HIGH | ✅ done |
| T10 | `isConnected` last-known + fast-retry (via T08) | 2 | P1 | MEDIUM | ✅ done |
| T11 | Guard single-use: chống double-show ad đã dispose | 3 | P1 | HIGH | ✅ done |
| T12 | Banner: chống postFrameCallback dồn + dispose-trước-recreate | 3 | P1 | HIGH | ✅ done |
| T13 | Close `_eventStream` + pop dialog khi destroy/reset | 3 | P2 | MEDIUM | ✅ done |
| T14 | Route observer re-subscribe + guard timer nhỏ | 3 | P2 | LOW | ✅ done |
| T15 | Ad-unit-id tách theo platform (Android/iOS) | 1 | P1 | MEDIUM | ✅ done |
| T16 | Validate ad-unit-id (rỗng/định dạng) trong footgun warnings | 1 | P1 | MEDIUM | ✅ done |
| T17 | Trial hardening: anti clock-rollback + footgun nếu grace tắt | 4 | P1 | HIGH | ✅ done |
| T18 | VIP key signed offline (Ed25519) + one-time-use per-device | 5 | P0 | HIGH | ✅ done |
| T19 | VIP robustness: negative-duration, purge, cap/API clarity | 5 | P2 | MEDIUM | ✅ done |
| T20 | Test suite compliance + lifecycle + network | tất cả | P2 | — | ✅ done |

## Định nghĩa "Done" chung
- Code + `flutter analyze` sạch, `dart format` áp dụng.
- Có test tương ứng (trong `packages/ad_sdk/test/`) và **xanh**.
- Cập nhật CHANGELOG.md của package + doc liên quan nếu đổi public API.
- Không mark done nếu test đỏ / implement dở dang.
