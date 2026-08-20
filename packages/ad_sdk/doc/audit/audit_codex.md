# Audit độc lập `applovin_admob_sdk` — codex CLI (bản hợp nhất)

Hợp nhất `audit_codex.md` (round 1, ~2026-08-09, local version 2.0.3, pub.dev khi đó 1.2.2) và `audit_codex_20260815.md` (round 2, 2026-08-15, version 2.0.4, 700 test pass). **codex CLI không chạy được round 3 trong phiên audit 08-19/20 này** (quota OpenAI hết, trả về "usage limit — resets Aug 20 2026") — file này KHÔNG có góp ý mới từ codex sau 08-15; phần "cross-check" dưới đây là do Claude tự re-verify trực tiếp source trong phiên 08-19/20.

---

## Cross-check các "P1 bug" của round 2 (08-15) với vòng audit 08-19/20

| # | Finding round 2 (08-15) | Trạng thái sau re-verify 08-19/20 |
|---|---|---|
| P1-1 | AppLovin Native có thể request ad sau khi gate đổi trạng thái (`native_ad_widget.dart:48,70,102,158,249`) — `_allowed=true` latch không re-check `canRequestAds`/`canReload` khi rebuild | **UNVERIFIED** — không tự đọc lại trong phiên này, không khẳng định fixed hay còn mở. |
| P1-2 | `canShowInterstitial()`/`canShowRewardedAd()` trả `true` dù đường show thực tế sẽ bị chặn | **STALE/ĐÃ FIX** — phiên 08-19/20 xác nhận trực tiếp cả 2 hàm này hiện dùng `canShowFullscreenAdPeek()` (side-effect-free, phản ánh đúng trạng thái sẽ chặn hay không) thay vì logic cũ gây sai lệch. |
| P1-3 | README ghi sai default `autoRequestUmpConsent` (README nói `false`, code là `true`) | **STALE/ĐÃ FIX** — README hiện tại (dòng ~715) ghi đúng `true`, khớp `ad_config.dart:370`. |
| P1-4 | `destroy()` không reset đủ consent/ATT guard state (`_canRequestAds`, `_lastUmpResult`, `_umpAttemptFailed`, `_attRequested` sống sót qua destroy→reinit) | **UNVERIFIED** — không tự đọc lại trong phiên này. |
| P1 (UMP fail-open) | UMP channel lỗi fail-open cho phép request ads sau lỗi consent SDK (`ad_manager.dart:1272,1275,1294,1300` — số dòng lịch sử tại thời điểm đó) | **CONFIRMED CÒN MỞ** — re-verify độc lập trong phiên 08-19/20 (lane E M2) xác nhận `runZonedGuarded` error handler mở lại gate khi UMP channel native lỗi. Đây là finding thật, không phải lỗi audit cũ. |

---

## Round 1 (2026-08-09) — các mục còn giá trị tham khảo

**Bối cảnh lúc đó:** local `pubspec.yaml` = 2.0.3, pub.dev serve 1.2.2. **Tình trạng hiện tại (08-20):** local = 2.1.0, đã release theo git log (`51e79e6`, `95c12e8`) — verify trực tiếp trên pub.dev trước khi tin đã lên hẳn (CDN có thể lag, xem CLAUDE.md). Số liệu phiên bản cũ trong round 1 (2.0.3 vs 1.2.2) đã lỗi thời hoàn toàn, không dùng lại.

### Critical
Không có regression Critical mới trong diff lúc đó. `canReload` gate đã wire đúng cho banner/MREC/native cả 2 adapter (`ad_manager.dart:1312`, `admob_adapter.dart:944`, `applovin_adapter.dart:1081,395,676,879`) — mục này vẫn còn đúng theo cấu trúc code hiện tại (chưa có tín hiệu gì cho thấy gate này bị gỡ).

### High (M2–M4 của round 1)
- **M2 — version mismatch local/pub.dev.** Đã lỗi thời về số liệu cụ thể, nhưng **bản chất finding vẫn còn giá trị**: mỗi lần release cần verify pub.dev đã serve version mới thật, không chỉ tin theo commit local. Xem mục "Tình trạng hiện tại" trên.
- **M3 — UMP fail-open khi channel lỗi.** Trùng với P1 (UMP fail-open) ở bảng cross-check trên — **CONFIRMED CÒN MỞ** tại 08-19/20.
- **M4 — Signed VIP redeem yêu cầu online dù verify crypto là offline.** `redeemSignedKey` trả invalid nếu `_isConnectedCheck()` false (`vip_manager.dart:599`), lý do là product gate chống chia sẻ key qua mạng, không phải hạn chế kỹ thuật. **Chưa re-verify trong phiên 08-19/20** — nếu còn đúng, cần ghi rõ trong README rằng "hoạt động offline" chỉ áp dụng cho VIP đã redeem trước đó và ad loading, không áp dụng cho redeem key mới.

### Ghi nhận scope — các mục host-app đã lỗi thời do tách repo
Round 1 có nhắc tới các file `lib/mckimquyen/widget/splash/...`, `lib/mckimquyen/widget/vip/...` — đây là code của **host app**, theo CLAUDE.md hiện tại **host app đã được tách sang repo riêng**, không còn nằm trong repo này. Các finding liên quan (cold-start App Open bypass safety trong splash screen của host, privacy settings persistence phụ thuộc host UI) **ngoài phạm vi audit của package `ad_sdk` hiện tại** — giữ lại chỉ để lưu ý cho bên tích hợp (consuming app), không phải backlog của package này.

---

## Findings từ round 2 (08-15) — chưa cross-check ở trên, giữ nguyên

- Thiếu test cho "banner AdMob ở route đầu tiên" (đi kèm bug `_admobIsTop` không init đúng khi mount trên route hiện tại — trùng với `audit_agy.md` finding 1.1, cũng chưa được verify lại 08-19/20. Hai nguồn độc lập (codex + agy) cùng nêu vấn đề tương tự → nên ưu tiên xác minh sớm).
- Thiếu test cho tổ hợp `autoRequestUmpConsent:false` + dialog built-in.
- CI không track code coverage định kỳ, tự động — chỉ có số đo thủ công một lần (66.4% tại thời điểm 08-11).
- Barrel export `applovin_admob_sdk.dart` lộ nhiều low-level/testing surface (adapters, event bus, slot/backoff internals) ra public API — rủi ro breaking change ngầm nếu ai dùng nhầm phần internal.
- Pinning wall Dart/CocoaPods (đã ghi trong CLAUDE.md) chưa có matrix test hoặc doctor-check tự động để phát hiện xung đột trước khi consuming app build.
- README stale nhắc `google_mobile_ads 6.x` trong khi package dùng `^7.0.0` (cần re-verify README hiện tại có còn stale không).
- Không có watchdog cho load thường (không phải on-demand) của interstitial/rewarded — chỉ có cho on-demand rewarded load.

---

## Kết luận

**Không có second opinion mới từ codex trong vòng audit 08-19/20** do quota hết. File này là tổng hợp 2 round trước + annotation từ verify độc lập của Claude trong vòng mới nhất.

**Bugs còn mở, xác nhận cần fix:**
1. UMP channel fail-open cho phép request ads khi consent SDK lỗi (CONFIRMED CÒN MỞ, xem `audit_claude.md` cho finding tương đương).
2. Version mismatch pub.dev vs local — verify lại trước mỗi lần khuyến nghị ship.
3. `_admobIsTop` route đầu tiên (2 nguồn độc lập nêu, chưa verify lại — ưu tiên cao).

**Unverified, cần đọc lại trước khi đóng hoặc xác nhận còn mở:** P1-1 (AppLovin Native gate re-check), P1-4 (`destroy()` reset guard state chưa đủ), M4 (redeem VIP cần online).

**Khuyến nghị:** nhất quán với `audit_claude.md` và `audit_agy.md` — **YES-WITH-CONDITIONS**. Điều kiện thêm riêng từ góc nhìn codex: đóng UMP fail-open trước khi ship cho audience có EEA user thật; verify lại 3 mục UNVERIFIED trên trước khi coi audit này đã đầy đủ.
