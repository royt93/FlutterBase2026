# Board task — Audit SDK `applovin_admob_sdk`

Nguồn: `doc/audit/audit_claude.md`. Quy trình scrum theo thư mục:

```
doc/task/todo/         → chưa làm
doc/task/inprogress/   → đang làm (di chuyển file sang đây khi bắt đầu)
doc/task/done/         → xong (di chuyển file sang đây, tick hết acceptance criteria)
```

**Cách dùng:** khi bắt đầu một task, `git mv` file từ `todo/` → `inprogress/` và đổi `Status:` trong file. Khi xong, `git mv` sang `done/`. 1 file = 1 task, tên `Txx-slug.md`.

## Tiến độ (cập nhật 2026-07-06)
- **P0: 5/5 XONG ✅** — T02, T08, T18, T01, T03.
- **Lifecycle/memory XONG ✅** — T11, T12, T13.
- **Network UX XONG ✅** — T09 (banner offline/reload), T10 (isConnected last-known).
- **T05 done** (RDP/CCPA vs COPPA tách đúng, +7 test case, `flutter analyze` clean).
- **T04 done** (AppLovin CMP-flow đã tắt mặc định khi dùng UMP + footgun warning nếu tắt cả 2 CMP; COPPA gap của `applovin_max` 4.x được document loudly qua `SafeLogger.w`, +2 test case).
- **T06 done** (`AdManager().showPrivacyOptions()` + `isPrivacyOptionsRequired()` wrap UMP privacy-options form; README có mục "Privacy Options entry point" hướng dẫn host đặt nút thường trực; re-consent re-apply provider ngay; +6 test case).
- **T07 done** (ATT wiring đúng thứ tự splash→ATT→UMP; thêm `assert()`-wrapped `SafeLogger.e()` ngay trước `requestAuthorization()` để cảnh báo sớm nếu thiếu `NSUserTrackingUsageDescription`; không cần test mới — nhánh quan sát được không đổi, `att_consent_test.dart` đã bao phủ đủ).
- **T15 done** (`AdMobConfig`/`AppLovinConfig` thêm optional `android*Id`/`ios*Id` override cho `bannerId`/`interstitialId`/`appOpenId`/`rewardedId`, resolve qua `Platform.isAndroid/isIOS` bằng getter cùng tên cũ — backward-compatible, adapter không cần sửa; +4 test case `ad_config_platform_test.dart`).
- **T16 done** (`releaseFootgunWarnings` thêm cảnh báo id rỗng cho `bannerId`/`interstitialId`/`appOpenId`/`rewardedId` (mọi provider) và cảnh báo sai định dạng `ca-app-pub-<16 số>/<id>` riêng cho AdMob — cùng cơ chế log ERROR + `assert(false, ...)` như guard dryRun/test-id sẵn có, không thêm class/abstraction mới; +6 test case `ad_manager_core_test.dart`).
- **T17 done** (`VipEntry.isActive`/`remaining` thêm check `now.isBefore(grantedAt)` — đồng hồ bị lùi sau khi cấp entry sẽ bị coi là đã tiêu thụ thay vì "sống lại"; `releaseFootgunWarnings` thêm cảnh báo khi `firstInstallVipGrace` bị disable ở release — partner có thể vô tình tắt trial mà không biết; anti-reinstall Keychain guard giữ nguyên không đổi; +6 test case `vip_entry_test.dart` + `ad_manager_core_test.dart`). Còn lại P2: T14, T19, T20.
- **✅ P0 milestone build verified trên S24 Ultra (SM-S928B) — cả 2 provider:**
  - AdMob (example app): `🔐 UMP gate → canRequestAds=true`, `applyConsent → nonPersonalizedAds=true`, `📶 connectivity watch started`, VIP grace → expire → AdMob appOpen/inter/rewarded **loaded ✅**.
  - AppLovin (host FastNet): `AppLovin CMP flow disabled (UMP is CMP)`, gate hoạt động, provider=appLovin.
  - **0 crash, 0 `E/flutter`.**
- **306/306 test SDK xanh**, `flutter analyze` sạch (SDK + host).
- ⚠️ Host `pubspec.yaml` đang **flip path override** sang SDK local — nhớ flip lại trước release.
- **Điểm hiện tại: 8.5/10** — thiếu: (0.5đ) T14/T19/T20 còn ở todo/ (đều P2); (1đ) chưa re-audit `doc/audit/audit_claude.md` sau đợt fix T07/T15/T16/T17; (~0.5đ) chưa smoke-test lại trên SM_A507FN kể từ khi thêm T07.

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
| T14 | Route observer re-subscribe + guard timer nhỏ | 3 | P2 | LOW | todo |
| T15 | Ad-unit-id tách theo platform (Android/iOS) | 1 | P1 | MEDIUM | ✅ done |
| T16 | Validate ad-unit-id (rỗng/định dạng) trong footgun warnings | 1 | P1 | MEDIUM | ✅ done |
| T17 | Trial hardening: anti clock-rollback + footgun nếu grace tắt | 4 | P1 | HIGH | ✅ done |
| T18 | VIP key signed offline (Ed25519) + one-time-use per-device | 5 | P0 | HIGH | ✅ done |
| T19 | VIP robustness: negative-duration, purge, cap/API clarity | 5 | P2 | MEDIUM | todo |
| T20 | Test suite compliance + lifecycle + network | tất cả | P2 | — | todo |

## Định nghĩa "Done" chung
- Code + `flutter analyze` sạch, `dart format` áp dụng.
- Có test tương ứng (trong `packages/ad_sdk/test/`) và **xanh**.
- Cập nhật CHANGELOG.md của package + doc liên quan nếu đổi public API.
- Không mark done nếu test đỏ / implement dở dang.
