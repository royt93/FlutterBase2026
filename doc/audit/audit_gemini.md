# Audit SDK — applovin_admob_sdk (round 2026-07-08)

**Người audit:** Claude (Sonnet 5). **Phạm vi:** re-audit toàn diện SDK theo 7 yêu cầu partner + 2 góc nhìn mới (request-minimization/fill-rate, pháp lý theo từng loại ad), đối chiếu với backlog đã có (`doc/audit/audit_claude.md`, `doc/task/README.md`).

## 0. Tóm tắt điều hành

Backlog gốc **T01–T20 đã đóng 100%** (`doc/task/done/`), qua 13 round re-audit độc lập (2 pass sạch liên tiếp/mục, xem `doc/task/README.md`) + 1 device smoke-test thật (Pixel 7 Pro). 332/332 test SDK xanh, 76/76 test host xanh, `flutter analyze` sạch. **Không re-litigate các mục này** — đã verify kỹ ở round trước, code hiện tại đúng như ghi nhận.

Round audit này (mới) tập trung vào 2 góc chưa từng audit riêng trước đây, dùng 2 agent độc lập đọc source hiện tại:

1. **Logic tối thiểu request / tối đa fill rate** — kết quả: kiến trúc đã tốt (backoff, dedup, cache freshness, connectivity gate đều đúng), phát hiện **1 gap MEDIUM mới** → **T21**.
2. **Pháp lý theo từng loại ad** (Banner/Interstitial/Rewarded/App Open/Native) — kết quả: hầu hết compliant, phát hiện **1 gap LOW mới** → **T22**. Gap COPPA của AppLovin (đã biết từ T04) được xác nhận vẫn đồng nhất trên cả 4 loại ad, không phải bug mới.

Ngoài ra, làm rõ 2 câu hỏi user đặt ra:

- **"CONSENT.MD"** — không tồn tại file này trong repo. Tài liệu gần nhất là `doc/UMP_SETUP.md` (setup dashboard UMP/GDPR) — đã đọc, xem mục 3.
- **VIP by code không server** — **đã resolve từ T18** (2026-07-05), không còn conflict. Xem mục 2.

---

## 1. Đối chiếu 7 yêu cầu partner

| # | Yêu cầu | Trạng thái | Ghi chú |
|---|---|---|---|
| 1 | Provider AdMob/AppLovin, work Android + iOS | ✅ done (T15,T16) | Ad-unit-id tách platform, validate format, không nhánh `Platform.is*` trong safety logic. |
| 2 | Work có/không mạng | ✅ done (T08-T10) | Connectivity listener debounce 800ms, `isConnected` last-known fallback, banner auto-reload khi reconnect. |
| 3 | Đúng loại ad, đúng pháp lý, đúng vòng đời, không leak | ✅ done (T11-T14) + 🆕 T22 (LOW) | Xem mục 4 — audit pháp lý theo loại ad round này. |
| 4 | Trial mode 1 ngày | ✅ done (T17) | `FirstInstallVipGrace.auto`: release = 1 ngày thật, debug = 30s (QA). Anti clock-rollback, write-once install-time. |
| 5 | VIP by code, không server | ✅ done (T18,T19) | Xem mục 2 — đã giải quyết constraint không server. |
| 6 | Consent mọi quốc gia, chuẩn AdMob/AppLovin | ✅ done (T01-T07) + ⚠️ 2 gap ops (mục 3) | Code-side đã chuẩn; còn 2 gap **vận hành** (không phải code) cần user xử lý. |
| 7 | Policy tuân thủ AdMob/AppLovin | ✅ done + 🆕 T21 (MEDIUM) | Xem mục 5 — audit fill-rate round này. |

---

## 2. VIP by code — không server (đã resolve, không còn conflict)

`audit_claude.md` gốc (T18) từng đề xuất "vipKeyValidator phải gọi backend kiểm one-time-use/quota/device binding". Đây **không phải trạng thái hiện tại** — quyết định cuối (2026-07-05, `doc/task/done/T18-vip-server-side-validation.md`) đã chọn hướng khác, đúng constraint user vừa nhắc lại:

- **Ed25519 chữ ký bất đối xứng, offline hoàn toàn.** Chỉ **public key** ship trong app để verify; **private key** dùng mint key ở máy dev (`tool/vip_keygen.dart`), không bao giờ ship — decompile app không forge được key mới.
- **One-time-use per-device** (không phải toàn cục) qua `redeemed-kid` store local (`AdPreferences`) — đủ chống 1 key dùng lại nhiều lần trên cùng máy.
- **Giới hạn đã biết, chấp nhận được:** one-time-use **toàn cục** (chống share 1 key cho nhiều máy khác nhau) cần server mới làm được — ngoài phạm vi "không server". Đã document rõ trong task file, API `redeemSignedKey` thiết kế để nếu sau này có backend thì nâng cấp thêm lớp online mà không đổi API.
- Không log plaintext code ở bất kỳ nhánh nào (`redeemSignedKey` chỉ log `keyId`/duration), atomic in-flight-set chống race concurrent-double-redeem.

**Kết luận: không cần quyết định gì thêm ở đây** — approach hiện tại đã đúng "bảo mật, không server" như user yêu cầu. Không tạo task mới cho mục này.

---

## 3. Consent mọi quốc gia — 2 gap vận hành (không phải code)

Code-side (T01-T07) đã đúng chuẩn: UMP làm consent chính, gate `canRequestAds` trước mọi impression, CCPA/COPPA tách đúng, ATT wiring đúng thứ tự, Privacy Options API đã có. Nhưng phát hiện lại 2 gap **vận hành/tích hợp** vẫn còn mở, độc lập với chất lượng code:

### 3.1. UMP/GDPR consent message chưa publish trên AdMob dashboard (thật, đang chặn EEA release)

`doc/UMP_SETUP.md` mô tả rõ: app ID `ca-app-pub-3612191981543807~9731053733` **chưa có GDPR message được publish** trên `apps.admob.com`. Log thật: `requestConsentInfoUpdate failed: ... no form(s) configured`. SDK degrade an toàn (`canRequestAds=true`), nhưng **user EEA/UK hiện không thấy form consent nào** — vi phạm yêu cầu "consent mọi quốc gia" theo đúng nghĩa TCF.

Đây **không phải task code** — là thao tác dashboard (đã có hướng dẫn từng bước trong `doc/UMP_SETUP.md`). Cần user (người có quyền admin AdMob account) thực hiện: tạo + **publish** GDPR message, verify bằng `debugGeography: eea`.

### 3.2. Host app chưa có nút "Privacy Options" / re-consent thường trực

SDK đã có API đầy đủ (`AdManager().showPrivacyOptions()`, `isPrivacyOptionsRequired()`, done từ T06) nhưng grep `lib/` (host app) cho thấy **0 lần gọi** — không có entry point UI nào để user rút/đổi consent sau lần đầu. Round audit trước (round 13) đã note đây là "known accepted limitation, không phải bug" — nhưng GDPR yêu cầu user phải rút được consent bất cứ lúc nào, nên đáng cân nhắc lại nếu sắp release EEA thật.

**Đề xuất:** không tạo task riêng ngay (vì đã được đánh giá là chấp nhận được trước đó) — nhưng nêu lại ở đây để user quyết định có muốn nâng ưu tiên hay không (ví dụ thêm nút trong Settings/VipScreen gọi `AdManager().showPrivacyOptions()`).

---

## 4. Audit pháp lý theo từng loại ad (mới)

*(Tóm tắt từ agent audit độc lập — full report trong lịch sử agent, giữ lại kết luận chính)*

| Loại ad | Check | Kết quả |
|---|---|---|
| Banner | Layout-shift/mis-tap, refresh cadence | ✅ compliant — height cố định shimmer↔loaded, "Ad" label chip, không override refresh interval |
| Interstitial | Không surprise cold-start, frequency cap, close button | ✅ compliant — chỉ gọi từ tap tường minh, `canShowFullscreenAd()` cap 60s/6-session/3-hour/5-day |
| Rewarded | Reward chỉ cấp khi hoàn thành thật | ✅ compliant — cả AdMob (`onUserEarnedReward`) lẫn AppLovin (`onAdReceivedRewardCallback`) dùng đúng signal native, dismiss sớm không cấp |
| Rewarded | Disclosure trước khi xem (VIP flow) | ✅ compliant — `vip_redeem_screen.dart` có title/badge FREE/subtitle/nút rõ ràng |
| Rewarded | Disclosure trước khi xem (generic helper) | 🆕 **GAP LOW → T22** — `AdScreenState.showRewardedAd()` không có disclosure hook sẵn cho host screen tương lai ngoài VIP |
| App Open | Không click-trap cold-start, không stack trên dialog, frequency cap riêng resume | ✅ compliant — cold-start one-shot skip, guard `isDialogOnTop`/`isShowing` xác nhận còn nguyên trong code hiện tại, `minTimeAppOpenResume` + `maxRapidResumesPerMinute` riêng cho resume |
| Native | — | N/A — SDK không có native ad |
| Cross-cutting | COPPA flag tươi mỗi lần load (không chỉ lúc consent) | ✅ compliant cho AdMob (`npa` đọc field mutable ở từng load call, mọi loại ad); ⚠️ AppLovin không có API COPPA per-request/global nào (gap đã biết từ T04, xác nhận đồng nhất cả 4 loại ad, không phải bug mới) |

**Việc mới cần làm:** T22 (LOW, đã tạo task file).

---

## 5. Audit request-minimization vs fill-rate (mới)

*(Tóm tắt từ agent audit độc lập)*

Kiến trúc hiện tại đã đúng gần hết các pattern chuẩn:

- ✅ **Exponential backoff** khi load fail thật (15s → 30s → ... → cap 30 phút, `backoff.dart`), reset khi thành công.
- ✅ **Phân biệt load-fail vs show-fail** — show-fail (ad đã cache nhưng hiển thị native lỗi) dùng `beginReload()` bypass cooldown vì không phải dấu hiệu mạng ad yếu; load-fail dùng `beginLoad()` tôn trọng backoff. Tránh conflate 2 loại lỗi khác bản chất.
- ✅ **Reload sau show không phải raw/unconditional** — có state machine dedup (`AdSlot.beginLoad()` no-op nếu đang loading/showing), tương đương "giữ đúng 1 ad sẵn sàng" — pattern chuẩn cho fullscreen ad (native SDK vốn chỉ cache được 1 ad/unit tại 1 thời điểm).
- ✅ **Không duplicate/concurrent request** cho cùng slot — race 2 lệnh load chỉ 1 cái thắng qua state machine.
- ✅ **Cache freshness check** (AdMob: TTL 4h app-open / 1h interstitial-rewarded) — load call khi ad còn tươi là no-op thật, không tốn request.
- ✅ **Connectivity-gated refill** — không polling/hammering khi offline, dựa vào callback + timer 5 phút ceiling (xác nhận lại T08 còn nguyên).
- 🆕 **GAP MEDIUM → T21**: preload/load-time **không** check safety cap ngày/giờ (`AdSafetyConfig.canShowFullscreenAd()` chỉ được gọi lúc **show**, không phải lúc **load**). User đã đạt cap ngày/giờ vẫn bị SDK tiếp tục preload interstitial/rewarded/app-open mỗi 5 phút — tốn request không thể nào chuyển thành impression. Fix: thêm `dailyCapReached()` read-only check ở `_retryRefillAds` + từng `loadX()`.
- ℹ️ Waterfall/bidding mediation (yếu tố lớn nhất cho fill rate) là cấu hình **dashboard** AppLovin MAX/AdMob, không có code phía SDK để audit — nêu rõ để không ai nhầm tưởng có knob code cho việc này.

**Việc mới cần làm:** T21 (MEDIUM, đã tạo task file).

---

## 6. Danh sách task mới phát sinh

| ID | Task | Severity | File |
|---|---|---|---|
| T21 | Load-time không check daily/hourly safety cap → phí request | MEDIUM | `doc/task/todo/T21-load-time-safety-cap-gate.md` |
| T22 | `showRewardedAd()` thiếu disclosure hook cho non-VIP rewarded | LOW | `doc/task/todo/T22-rewarded-disclosure-hook.md` |

Cả 2 đã thêm vào bảng backlog `doc/task/README.md`.

## 7. Việc không phải code (cần user xử lý riêng)

1. Publish GDPR/UMP consent message trên AdMob dashboard (mục 3.1) — blocker thật cho EEA release.
2. Cân nhắc thêm nút "Privacy Options" trong host app (mục 3.2) — hiện là accepted limitation, không bắt buộc nhưng nên có trước khi ship EEA rộng.
3. Kiểm tra cấu hình mediation waterfall/bidding trên dashboard AppLovin MAX + AdMob (mục 5) — đòn bẩy fill-rate lớn nhất, ngoài phạm vi code.
