# Independent audit round 27 — Claude (phiên chính)

**Ngày:** 2026-09-01
**Cây được audit:** `HEAD` (`d25e43d`), version 2.9.4 — trùng khớp bản mới nhất trên pub.dev
(`https://pub.dev/api/packages/applovin_admob_sdk` → latest `2.9.4`, publish
`2026-09-01T05:09:00Z`) — **không có khoảng lệch** giữa local và bản published,
khác các round trước (round 6 từng lệch).
**Baseline:** đọc toàn bộ `audit_round26_consolidated.md` trước khi audit.
**Phạm vi:** (1) đánh giá độ đầy đủ của `doc/AD_PROMPT_FLUTTER.MD` như một tài
liệu handoff độc lập; (2) audit toàn diện SDK theo 7 yêu cầu sản phẩm, đối
chiếu các commit `de9c40a..HEAD` (batch ticket T101-T130 + 3 lần sửa T102).

Reviewer độc lập khác cùng round: `codex` (`audit_codex_round27.md`), `agy`
(`audit_agy_round27.md`, xem file đó để có kết luận của gemini).

---

## Phần 1 — Đánh giá `doc/AD_PROMPT_FLUTTER.MD`: chỉ với 1 file này, đủ tích hợp full tính năng chưa?

**Kết luận: RẤT MẠNH cho phần lõi (bootstrap/splash/VIP/consent/policy/memory-leak),
nhưng KHÔNG đủ để tích hợp *toàn bộ* tính năng SDK — thiếu 3/7 loại ad-surface hoàn toàn.**

### Những gì file làm rất tốt
- Section 0 + "Hard rules" buộc AI phải hỏi user từng ID/key thay vì tự bịa —
  đúng thực hành an toàn (không auto-fill test ID khi có ID thật).
- Step 4 (bootstrap + splash) chép gần như nguyên văn thứ tự bắt buộc
  (`setNavigatorKey` trước `runApp`, ATT → UMP → `initialize`, hard-cap timer,
  hot-restart guard) — khớp chính xác với `README.md` và source hiện tại.
- Step 6.2 + Step 10.5 (memory-leak checklist) liệt kê đúng từng loại
  controller/timer/subscription cần `dispose()`/`cancel()` — khớp với các
  MAJOR đã từng bị audit bắt (m22, T103-T105 trong CHANGELOG).
- Step 9 (trial mode / first-install grace + anti-uninstall-bypass) rất chi
  tiết, đúng với `_first_install_guard.dart` hiện tại (Android Auto Backup,
  iOS Keychain) — đây chính là "trial mode 1 ngày" trong checklist của user,
  và tài liệu mô tả đúng, có cả smoke-test thủ công từng bước.
- Step 7 (Policy check) map đúng 5 rule chính (banner không che nội dung, app
  open không hiện trên splash trần, tần suất interstitial, rewarded chỉ khi
  xem xong, disclaimer splash) — đúng với 12-layer anti-fraud thật trong
  `ad_manager.dart`.
- Step 8 (Consent) đủ 3 mảnh: Cupertino auto-dialog, UMP, iOS ATT.

### Khoảng trống thật (đã verify bằng source, không suy đoán)

1. **Thiếu hoàn toàn 3/7 loại ad-surface mà SDK thực sự hỗ trợ và có demo
   sẵn:** `README.md:46-47,1639-1664` (và `example/lib/demos/mrec_demo_page.dart`,
   `example/lib/demos/native_demo_page.dart`) xác nhận SDK có `buildMrec()`
   (MREC 300×250), `buildNative()`/`NativeAdWidget` (native ad blend UI), và
   `showRewardedInterstitialAd()` (`README.md:1138-1184`). `AD_PROMPT_FLUTTER.MD`
   chỉ có touchpoint table + lifecycle steps cho **Banner / Interstitial / App
   Open / Rewarded** (Step 3 điểm 1, Step 4.4-4.7). MREC chỉ được nhắc lướt
   qua đúng 1 lần trong Appendix D (migration changelog, dòng 1452) như một
   fix cũ, không phải hướng dẫn tích hợp. Native và Rewarded Interstitial
   **không được nhắc tới một lần nào** trong toàn bộ 1545 dòng.
   → Một AI agent chỉ có file này sẽ tích hợp đúng và đầy đủ cho 4/7 loại ad,
   và **sẽ không biết MREC/Native/RewardedInterstitial tồn tại** — vì Appendix
   B đóng khung README là nguồn "nếu có source code" (tuỳ chọn), không phải
   bắt buộc đọc.

2. **Compliance nuance bị rút gọn quá mức:** `AD_PROMPT_FLUTTER.MD:1388-1389`
   chỉ đưa 2 dòng code mẫu `isAgeRestrictedUser` / `doNotSell` không giải
   thích gì thêm. Trong khi đó `README.md:1935-1936` ghi rõ một hành vi bất
   đối xứng quan trọng: AppLovin MAX 4.x không có runtime COPPA flag, nên khi
   `isAgeRestrictedUser=true` được biết **tại thời điểm init**, toàn bộ
   AppLovin bị vô hiệu hoá cho session đó — và một app **luôn luôn**
   child-directed (không có dialog consent nào) sẽ vẫn để AppLovin init một
   lần ở lần cài đầu tiên vì chưa có gì để gate. Đây là rủi ro pháp lý thật
   (COPPA) cho một nhóm app cụ thể (app trẻ em), và prompt file không hề nhắc
   engineer phải tự thêm config "child app" trước `initialize()`.

3. **Không có bước nào yêu cầu đọc `doc/audit/`** để biết SDK có 26+ vòng
   audit với các quyết định "cố ý không sửa" (VD: native ads không cần
   `RouteAware`, MJ9 clock rollback không thể fix pure-Dart) — một partner
   engineer có thể tưởng đây là bug và tự ý "sửa" ngược decision đã có lý do.

**Trả lời câu hỏi của user:** *"Nếu user chỉ có 1 file này thì họ đã đủ khả
năng tích hợp ad sdk full mọi tính năng chưa?"* → **Chưa.** Đủ cho một bộ
tích hợp production-safe với 4 loại ad chính + VIP + consent + trial mode
(phần khó nhất, dễ sai nhất, đã được cover kỹ) — nhưng **"full mọi tính
năng"** thì thiếu MREC, Native, Rewarded Interstitial hoàn toàn. Khuyến nghị:
thêm Step 4.8/4.9/4.10 cho 3 surface còn thiếu (không cần chi tiết như VIP
UI, chỉ cần touchpoint + 1 code block + memory-leak note mỗi loại, theo đúng
pattern các step khác), và thêm 1 dòng ở Section 0 nhắc rule "nếu app
child-directed, đọc `README.md` mục AppLovin/COPPA trước khi init".

---

## Phần 2 — Audit SDK (7 yêu cầu sản phẩm)

Không đọc lại từ đầu — baseline round 23-26 đã ổn định (xem file round26).
Tự verify độc lập (đọc source trực tiếp, không chỉ tin báo cáo trước) 4 điểm
rủi ro cao nhất, sau đó đối chiếu với báo cáo `codex` (đã xong,
`audit_codex_round27.md`) để cross-check.

### Tự verify độc lập

| # | Việc verify | Kết quả |
|---|---|---|
| 1 | BLOCKER key rotation — có leak mới trong `de9c40a..HEAD` không? | `git log -p de9c40a..HEAD -- packages/ad_sdk \| grep` cho pattern SDK key/ad-unit ID thật → **0 match**. Không có leak mới. Rotation trên dashboard AppLovin **vẫn chưa được xác nhận** — user đã chọn (2 lần, round 26 và round 27) giữ nguyên là rủi ro chấp nhận vì repo private. Không hỏi lại. |
| 2 | MAJOR #1 (round 26) — `_redeemed_key_ledger.dart` `markRedeemed()` còn thiếu lock? | Đọc trực tiếp dòng 66-76: vẫn là read-modify-write không lock. **Còn mở, y nguyên round 26.** |
| 3 | MAJOR #2 (round 26) — AdMob `onFailed` 4 loại fullscreen thiếu `_discardIfDisposed`? | Đọc trực tiếp `admob_adapter.dart:913-924` (appOpen), và grep xác nhận pattern lặp lại ở 3 vị trí khác (interstitial/rewarded/rewardedInterstitial) — `onLoaded` luôn gọi `_discardIfDisposed` đầu tiên, `onFailed` không bao giờ gọi. **Còn mở, y nguyên round 26.** |
| 4 | T102 (`destroy()` await event-log flush, 2.9.4) — có timeout không? | Đọc `ad_manager.dart:5406-5417` + `ad_event_log.dart:126-131` + `ad_preferences.dart:330`: `flush()` await `_persistChain`, chain này await `SharedPreferences.setString` qua platform channel — **không có `.timeout(...)` nào bọc quanh**. Nếu write bị treo (mất kết nối platform channel giữa lúc app bị kill, hoặc lỗi runtime hiếm), `destroy()` treo vĩnh viễn, và mọi `initialize()` gọi sau đó cũng treo theo (`destroy()`/`initialize()` serialize qua `_destroyInFlight`). Test hiện có (`destroy_awaits_event_log_flush_test.dart`) chỉ test độ trễ hữu hạn (`debugPersistDelay`), không test trường hợp không bao giờ resolve. |

**Điểm 4 là finding MỚI của round này** — không có trong round 26 vì T102
mới được thêm hôm nay (2.9.2→2.9.4). Đã đối chiếu độc lập với báo cáo
`codex` (`audit_codex_round27.md`, mục "NEW MAJOR — T102 makes teardown
availability depend on an unbounded storage write") — **2 reviewer độc lập
tìm ra cùng 1 vấn đề, cùng root cause, cùng khuyến nghị (thêm timeout + test
đường không bao giờ resolve)**. Coi là **CONFIRMED**.

Đánh giá mức độ nghiêm trọng: MAJOR, không phải BLOCKER — vì
`SharedPreferences.setString` trên thực tế native platform gần như không bao
giờ treo vô hạn (đây là 1 lệnh ghi file/prefs local, không phải network I/O);
nhóm code trước đó (event-stream close, fullscreen drain) đã cố tình bọc
timeout cho các operation có khả năng treo thật (chờ native SDK callback) —
áp dụng cùng kỷ luật cho flush này là đúng, nhưng rủi ro thực tế là thấp hơn
các trường hợp kia. Tác giả T102 đã cân nhắc và cố tình không thêm timeout
(xem comment tại `ad_manager.dart:5401-5415` — 2 lần thử đầu dùng
`unawaited` chính là "timeout ngầm", và bị loại bỏ vì nó *gây ra* bug đang
sửa) — nhưng chưa thêm lại timeout đúng cách (timeout + tiếp tục teardown,
khác với bỏ qua hoàn toàn).

### Đối chiếu 7 yêu cầu — không đổi so với round 26, trừ mục 3 có thêm 1 caveat

| # | Yêu cầu | Round 26 | Round 27 |
|---|---|---|---|
| 1 | Dual-provider Android/iOS | PASS | PASS (không đổi) |
| 2 | Có/không mạng | PASS | PASS (không đổi) |
| 3 | 4 loại ad, lifecycle, no-leak | PASS-with-caveat (2 race hẹp) | PASS-with-caveat — **thêm 1 caveat mới**: T102 flush không timeout (xem trên) |
| 4 | Trial 1 ngày | PASS | PASS (không đổi, không commit nào trong T101-T130 chạm `_first_install_guard.dart`) |
| 5 | VIP by-code, không backend | PASS-with-caveat (#1 ledger race) | PASS-with-caveat (không đổi) |
| 6 | Consent mọi quốc gia | PASS-with-caveat (#5 đã fix) | PASS (khoảng hở #5 đã đóng ở round 26, không có gì mới chạm consent trong T101-T130) |
| 7 | Policy compliance | PASS-with-caveat (chặn bởi BLOCKER #1) | Như cũ — vẫn chặn bởi BLOCKER key rotation (risk-accepted, không phải finding mới) |

## Kết luận round 27

**Không có BLOCKER mới. Không có regression trong batch T101-T130 (30 ticket) chạm
đến consent/VIP/trial — đã tự đọc các diff cao-rủi-ro nhất (T102, T106, T108,
T111/T121, T115) và đối chiếu với `codex`, khớp nhau.** 1 MAJOR mới (T102
flush không timeout), cộng 2 MAJOR cũ vẫn mở theo lựa chọn của user (ledger
race, AdMob onFailed guard). BLOCKER key rotation — **risk đã được user chấp
nhận, không phải "chưa xử lý", không cần hỏi lại.**

**Sẵn sàng production: YES WITH CONDITIONS** (không đổi verdict so với round
26 — điều kiện là rotate key trước khi mở quyền truy cập repo/pub.dev nếu
chưa làm, và nên vá 3 MAJOR còn mở trước khi ship một tính năng phụ thuộc vào
chúng cụ thể — VIP redeem đồng thời tần suất cao, hoặc app có traffic
destroy()/initialize() lặp lại nhanh).

**Điểm: 8/10** (round 26: baseline vững, round 27: thêm 30 ticket cải tiến
không phá vỡ gì, phát hiện thêm 1 MAJOR nhỏ mới, tự vá được ngay dễ dàng).

**Việc ưu tiên trước ship tiếp theo:**
1. Thêm `.timeout(...)` cho `_eventLog?.flush()` trong `destroy()` (dễ, rủi ro thấp, đã có sẵn pattern timeout khác trong cùng file để copy).
2. Serialize `RedeemedKeyLedger.markRedeemed()` (lock đơn giản, vd `Completer`-based mutex).
3. Thêm `_discardIfDisposed` vào 4 nhánh `onFailed` của `admob_adapter.dart`.
4. Bổ sung 3 Step còn thiếu (MREC/Native/RewardedInterstitial) vào `AD_PROMPT_FLUTTER.MD`.
5. Khi nào mở quyền truy cập repo ra ngoài team hiện tại hoặc public hoá — rotate AppLovin key/ad-unit ID trước.
