# Audit round 39 — applovin_admob_sdk v2.9.18 (Claude, 2 nguồn hợp nhất)

**2 nguồn độc lập chạy dưới tên "claude" round này, hợp nhất vào 1 file theo đúng quy ước đặt tên:**

1. **claude-cli** (worktree cô lập, dưới đây) — 4 finding (3 MAJOR + 3 MINOR), điểm 9.0/10.
2. **fork của phiên chính** (repo thật, không có trong file gốc dưới đây vì chạy song song, không chia sẻ context) — tìm **1 MAJOR khác biệt**: nhánh COPPA re-init trong `AdManager.setConsent()` (`ad_manager.dart` ~dòng 3962) ghi native SDK không có epoch guard — **ĐÚNG chỗ claude-cli's dòng "Đã kiểm tra kỹ và xác nhận KHÔNG phải bug" bên dưới (mục COPPA-flip branch) đã bỏ sót** — nguồn con verify bằng cách viết test tái tạo chính xác race (2 lệnh setConsent() COPPA-toggle chồng nhau) và **XÁC NHẬN ĐÂY LÀ BUG THẬT** (không tự lành như claude-cli kết luận). Bằng chứng: `test/consent_coppa_branch_race_test.dart` — RED trước fix, GREEN sau khi thêm epoch guard giống hệt pattern dòng 4031/4048 cùng file.

**Bài học quy trình:** 2 nguồn cùng tên "claude" bất đồng về đúng 1 finding — 1 nói "chủ ý, tự lành", 1 verify bằng test thật và tìm ra không tự lành. Đây là ví dụ cho lý do "audit phải chậm và adversarial, verify cơ chế chứ không chỉ pattern-match" — xem memory `audit-must-be-slow-and-adversarial`.

**Trạng thái tất cả finding trong file này (cả claude-cli lẫn fork) sau round 39:** tất cả MAJOR + MINOR bên dưới đã fix, có test regression, xem `CHANGELOG.md` mục version kế tiếp và `audit_round39_consolidated.md`.

---

## Báo cáo gốc từ claude-cli (worktree cô lập)

**Phương pháp:** đọc source thật trực tiếp (không chỉ pattern-match), verify từng finding bằng cách đọc cả caller lẫn callee, đối chiếu với `doc/audit/audit_round38_consolidated.md` để không báo lại lỗi đã fix. 1 phần công việc (VIP/trial, offline/connectivity/backoff, policy compliance) được chia cho 3 sub-agent chạy song song, độc lập, không chia sẻ context với nhau lẫn với phiên chính; mọi finding của sub-agent đều được phiên chính tự đọc lại source thật để verify trước khi đưa vào báo cáo này (không copy nguyên văn). Phần consent-race/lifecycle core do phiên chính tự đọc tay. `flutter analyze` sạch, `flutter test` **1640/1640 pass** tại thời điểm audit — không regression so với round 38.

## Tóm tắt

SDK đã qua 38 vòng audit đối kháng trước đó và đạt mức độ hardening rất cao — phần lớn các lớp lỗi kinh điển (double-show ad, leak Timer/StreamSubscription, dispose-while-showing, clock rollback, backoff overflow) đã được tìm và vá kỹ, có test regression đi kèm. Round này tìm thêm **3 MAJOR mới** (không trùng round 38), đều thuộc dạng "cơ chế bảo vệ áp dụng ở nơi này nhưng thiếu ở nơi song song" — đúng pattern lặp lại đã ghi nhận ở round 38. Không tìm thấy BLOCKER. Điểm tổng: **9.0/10**.

## Danh sách finding

### MAJOR-1 — `ConsentManager._persist()` không được serialize, giá trị consent lưu đĩa có thể bị đè ngược bởi lệnh cũ hơn

**File:** `lib/src/consent/consent_manager.dart:140-142` (`_persist()`), `:249-266` (`_setInternal`)

```dart
Future<void> _persist() async {
  await _prefs.setConsentSettingsRaw(ConsentSettings.encode(_current));
}
...
Future<void> _setInternal(ConsentSettings s, {AdConfig? config}) async {
  final epoch = ++_applyEpoch;
  _current = s;
  _settingsListenable.value = s;
  await _persist();                    // <-- KHÔNG có epoch guard nào quanh dòng này
  ...
  if (epoch == _applyEpoch) {
    await _applyToProviders(config);   // <-- CÓ epoch guard (round-38 fix)
  } else { ... }
}
```

Round 38 đã tìm và fix chính xác race giữa 2 lệnh `setConsent()`/`ConsentManager.set()` chồng nhau: thêm `_applyEpoch` guard **quanh lời gọi `_applyToProviders()`** (ghi thật xuống AppLovin/AdMob SDK), đã verify trên Samsung thật. Nhưng guard đó **không bọc lời gọi `_persist()`** phía trên nó — mọi lệnh `set()`/`reset()`/`showDialog()` chồng nhau đều gọi `_persist()` vô điều kiện, bất kể epoch.

`_persist()` gọi `_prefs.setConsentSettingsRaw()` → `SharedPreferences.setString()` — một lời gọi platform-channel bất đồng bộ thật (I/O đĩa native). Chính round 38 đã **chứng minh trên thiết bị thật** rằng đúng dạng gap bất đồng bộ này (`_persist()`'s real async gap) có thể khiến 1 lệnh cũ hơn hoàn tất **sau** 1 lệnh mới hơn — đó là lý do epoch guard tồn tại. Guard đó chỉ bảo vệ bước ghi-xuống-SDK-thật, không bảo vệ bước ghi-xuống-đĩa.

**Bằng chứng SDK tự biết dạng race này có thật và cách sửa đúng nằm ngay cạnh:** `lib/src/compliance/ad_event_log.dart:30-33,103-108` — module compliance-log dùng đúng pattern `_persistChain` (chain từng `_persist()` sau `_persist()` trước, đảm bảo ghi đĩa luôn theo đúng thứ tự gọi bất kể độ trễ platform-channel), kèm comment giải thích chính xác: *"Chains every `_persist` call after the previous one so concurrent `_append`s can't race their `setString` writes and finish out of order"*, và một `debugPersistDelay` test hook để tái tạo "the real-device timing gap (genuine async platform-channel I/O) that the in-memory SharedPreferences mock is too fast to ever exhibit on its own". `ConsentManager._persist()` không có cơ chế tương đương nào.

**Kịch bản lỗi cụ thể:** user bấm đổi ý đồng ý quảng cáo 2 lần liên tiếp rất nhanh (reject → accept, hoặc app tự gọi `setConsent()` 2 lần chồng nhau, ví dụ do double-tap hoặc do 1 UI callback tự động cộng với 1 lệnh khác gần như đồng thời). Nếu lệnh CŨ HƠN (reject) có write-đĩa hoàn tất **sau** lệnh MỚI HƠN (accept) — do trễ platform-channel thật, không phải giả định — thì:
- Bộ nhớ (`_current`), và cả 2 SDK thật (AppLovin/AdMob) đều đúng: giữ giá trị MỚI (`accept`) — vì phần ghi này ĐÃ được epoch guard bảo vệ đúng.
- Nhưng giá trị ghi CUỐI CÙNG xuống SharedPreferences lại là giá trị CŨ (`reject`), vì `_persist()` không hề biết mình đã bị "supersede".
- Hậu quả **chỉ lộ ra ở phiên sau**: lần mở app tiếp theo, `ConsentManager.bootstrap()` → `_load()` đọc lại giá trị sai (`reject`) từ đĩa, `_current` bị ghi đè về giá trị SAI, và giá trị sai này được áp lại cho AppLovin/AdMob thật ở lần `initialize()` kế tiếp — tức lựa chọn cuối cùng, thật sự của user (`accept`) bị **âm thầm đảo ngược** ở phiên sau, mỗi lần mở app tiếp theo cho tới khi user set lại consent. Đây là rủi ro tuân thủ GDPR thật (quảng cáo cá nhân hoá phục vụ sai theo lựa chọn user đã rút lại, hoặc ngược lại).

**Mức độ chắc chắn:** đã verify bằng đọc source (không đoán) rằng (a) guard hiện tại chỉ bọc `_applyToProviders`, không bọc `_persist`; (b) module song song `ad_event_log.dart` trong CÙNG codebase phải xử lý chính xác race này bằng cách serialize write. Điều chưa verify được (cần verify thêm, không khẳng định): liệu implementation thật của gói `shared_preferences` trên Android/iOS có thực sự để 2 lời gọi `setString()` liên tiếp hoàn tất KHÔNG theo thứ tự gọi hay không — đây phụ thuộc plugin, không kiểm tra được từ Dart source. Nhưng vì round 38 đã chứng minh **đúng lớp gap bất đồng bộ này** (chuỗi persist-rồi-apply của chính `_setInternal`) tái tạo được trên Samsung thật, và sibling module đã chủ động vá đúng loại race y hệt, tôi đánh giá đây là finding có cơ sở vững, không phải suy diễn hàn lâm.

**Đề xuất fix:** áp dụng đúng pattern `_persistChain` đã có sẵn trong `ad_event_log.dart` cho `ConsentManager._persist()` — chain mỗi lần persist sau lần trước, đảm bảo ghi đĩa luôn theo đúng thứ tự lệnh gọi bất kể độ trễ platform-channel. Viết test bằng `ConsentManager.debugApplyBarrier` (đã có sẵn) mô phỏng đúng kịch bản round 38 nhưng assert trên giá trị **đọc lại từ `_prefs.getConsentSettingsRaw()`** sau khi cả 2 lệnh hoàn tất, thay vì chỉ assert `_current`/provider calls như test hiện có (`test/consent_setconsent_race_test.dart` không cover trường hợp này).

---

### MAJOR-2 — Bộ đếm CTR chống click-fraud bị "pha loãng" bởi banner/MREC/native refresh, click bot chỉ nhắm fullscreen ad có thể lọt qua ngưỡng phát hiện

**File:** `lib/src/core/ad_safety_config.dart:595-611` (tính CTR), `:748-753` (`recordBannerImpression`), `:1116-1117` (`_computeRiskScore`'s `ctrRatio`)

Toàn bộ 4 loại ad (banner, MREC, native, fullscreen) đều cộng dồn vào **cùng 1 cặp counter** `_totalImpressions`/`_totalClicks`:
- Fullscreen: `recordFullscreenAdShown()` (dòng 727-744).
- Banner/MREC/native: `recordBannerImpression()` (dòng 748), gọi từ `admob_adapter.dart:2204,2377,2516` (`onAdImpression` — bắn ở **mỗi lần refresh thật**, đã verify bằng đọc call site, không chỉ lần load đầu) và `banner_ad_widget.dart:655-664` (`onAdRevenuePaidCallback` phía AppLovin, comment ghi rõ "real per-impression signal").

CTR = `_totalClicks / _totalImpressions` so với `suspiciousCtrThreshold` (mặc định 0.30). Banner tự động refresh (30-60s/lần theo mặc định AdMob) tạo ra impression liên tục suốt session, trong khi click-fraud thật thường chỉ nhắm **fullscreen ad** (CPM/CPC cao hơn hẳn banner) — nên counter chung khiến CTR thật của hành vi gian lận bị pha loãng dưới ngưỡng.

**Kịch bản cụ thể:** session 10 phút, 1 banner tự refresh (~15-20 impression) + 3 interstitial hiện, bot tự động tap **mọi** interstitial (không đụng banner). CTR đo được = 3/(3+18) ≈ 14% — dưới ngưỡng 30% mặc định — dù 100% impression "có thể tương tác" (fullscreen) đều bị click giả. Bộ đếm `_suspiciousViolationCount` không bao giờ tăng, tài khoản AdMob/AppLovin tiếp tục nhận traffic khả nghi mà chính hệ thống chống-gian-lận nội bộ của SDK không phát hiện được (dù hệ thống invalid-traffic riêng của Google/AppLovin có thể tách biệt phát hiện được — nhưng đó không phải lý do bỏ qua lớp phòng thủ nội bộ này).

**Lỗi tài liệu đi kèm** (không quan trọng bằng nhưng đáng sửa cùng lúc): docstring dòng 746 ghi *"Record a banner ad impression (initial load only, not refreshes)"* — đã verify đây là **sai** so với call site thật (bắn ở mọi refresh, cố ý, theo đúng comment round-31/32 tại các call site adapter). Comment lỗi thời này có thể khiến người đọc sau tin nhầm CTR ít nhạy hơn thực tế.

**Đề xuất fix:** tách counter CTR fullscreen-only khỏi counter banner/MREC/native (hoặc tính CTR riêng cho từng nhóm ad-type), giữ counter chung hiện tại chỉ cho mục đích thống kê tổng nếu cần. Sửa lại docstring `recordBannerImpression()` cho khớp hành vi thật.

---

### MAJOR-3 — UMP retry-khi-có-mạng-lại / backstop định kỳ không bọc `runZonedGuarded`, có thể ném unhandled zone error lặp lại khi mạng chập chờn

**File:** `lib/src/core/ad_manager.dart:7535` (`_scheduleNextRetry`, backstop định kỳ mỗi 5 phút) và `:7656` (`_onConnectivityChanged`, ngay khi mạng offline→online)

```dart
// :7532-7536
SafeLogger.d(_tag, '🔐 retrying UMP consent on periodic backstop');
_umpBackstopRetryCount++;
unawaited(_retryUmpConsent());     // <-- trần, không zone guard, không catchError
...
// :7654-7657
SafeLogger.d(_tag, '🔐 retrying UMP consent after reconnect');
unawaited(_retryUmpConsent());     // <-- trần, không zone guard, không catchError
```

`_retryUmpConsent()` (dòng 4257) gọi thẳng `requestUmpConsent(...)` → cuối cùng chạm `ConsentInformation.instance.requestConsentInfoUpdate(...)` (`ump_consent.dart:217`) — một API kiểu callback trả `void`. Đã verify: lời gọi **gốc** duy nhất của flow này lúc `initialize()` (dòng 2806-2830) được bọc trong `runZonedGuarded`, với comment giải thích rõ lý do — *"requestConsentInfoUpdate is a callback API returning void: with no UMP channel registered it throws from a future nobody awaits, so the error arrives as an unhandled ZONE error that a try/catch around the call cannot see. Verified against the real stack in google_mobile_ads' UserMessagingChannel."* — tức đây là bug **đã từng xảy ra thật**, không phải giả định lý thuyết.

2 call site retry ở trên gọi **đúng cùng chuỗi hàm** nhưng thiếu hẳn zone guard đó. Đối chiếu ngay trong cùng hàm `_onConnectivityChanged`, sibling call `_recoverConsentGate()` (dòng 7663-7666) LẠI có `.catchError` đầy đủ — xác nhận đây là chỗ sót không nhất quán, không phải chủ ý.

**Kịch bản lỗi:** host app release build có tích hợp native UMP lỗi (channel không đăng ký đúng — chính comment gốc liệt kê đây là kịch bản thật). Lần init đầu, `runZonedGuarded` bắt được lỗi, gate đóng đúng thiết kế (fail-closed), set `_umpAttemptFailed = true`. Từ đó:
- Mỗi 5 phút, backstop tự gọi lại `_retryUmpConsent()` — không zone guard → mỗi lần ném unhandled zone error.
- Mỗi lần offline→online (`_onConnectivityChanged`), gọi lại **không giới hạn số lần trong session** (chỉ check `_umpAttemptFailed && !_umpAnswered`, không có counter nào như backstop) — user đi vào vùng sóng yếu/thang máy/tàu điện ngầm nhiều lần trong ngày sẽ trigger lại nhiều lần.
- Nếu channel vẫn hỏng, `_umpAnswered` không bao giờ true, nên retry lặp vô hạn suốt session, mỗi lần đều ném unhandled zone error. Nếu host app không tự bọc `runApp()` trong `runZonedGuarded` riêng (không phải hành vi Flutter mặc định, nhiều app không làm), lỗi này thoát ra root zone → khả năng crash lặp lại mỗi lần mạng chập chờn.

**Không có test nào phủ path này** — đã kiểm tra `test/connectivity_refill_test.dart`, `test/connectivity_resilience_test.dart` (không set `_umpAttemptFailed`/`debugForceAutoUmpError` trước khi trigger connectivity flip), `test/ad_manager_core_test.dart` (có set `_umpAttemptFailed` nhưng không kết hợp connectivity trigger).

**Đề xuất fix:** bọc cả 2 call site (dòng 7535, 7656 — và cho nhất quán, `_recheckAbandonedUmpForm()` ở dòng 7531/7653 nếu chưa có) bằng cùng `runZonedGuarded` pattern đã có ở dòng 2806, hoặc factor thành 1 helper dùng chung ở cả 3-4 call site để tránh lặp logic fail-open/fail-closed nhiều lần và tránh sót lần nữa trong tương lai.

---

### MINOR-1 — Không có footgun-warning nếu host app không wire link privacy-policy cho VIP redeem screen / consent dialog

**File:** `lib/src/vip/vip_redeem_screen.dart:145-148,472-477`, `lib/src/consent/consent_dialog_strings.dart:15,28`, `lib/src/consent/consent_dialog.dart:100,195`

`onPrivacyPolicyTap`/`privacyPolicyUrl` mặc định `null`, và khi null thì phần UI liên quan (link privacy policy, "Do Not Sell") bị **ẩn hoàn toàn** khỏi widget tree thay vì hiện placeholder nhắc host phải wire. Đây là thiết kế cố ý (SDK không phụ thuộc `url_launcher`, để host tự quyết định cách mở link — đã ghi rõ trong README) nên **không phải bug code**. Nhưng `AdManager.releaseFootgunWarnings` (`ad_manager.dart:178-224`) đã có sẵn cơ chế cảnh báo loud-trong-release cho nhiều thứ khác (test ad-unit ID sót lại, `firstInstallVipGrace`, `umpDebugGeography`, AppLovin key rỗng...) nhưng **không** cảnh báo khi thiếu privacy-policy callback — dù đây cùng loại rủi ro "im lặng nhưng ảnh hưởng compliance" mà cơ chế đó vốn được dựng ra để bắt. Một host quên wire sẽ ship màn VIP purchase + dialog consent GDPR không có đường nào tới privacy policy, không nhận được tín hiệu gì từ SDK cả debug lẫn release.

**Đề xuất fix:** thêm 1 nhánh vào `releaseFootgunWarnings` (hoặc log cảnh báo tại `VipRedeemScreen.initState`/lúc build consent dialog) khi cả 2 callback liên quan privacy policy đều null.

---

### MINOR-2 — `AdRetryPolicy.jitterFraction` cấu hình cao có thể triệt tiêu gần hết tác dụng backoff

**File:** `lib/src/state/ad_retry_policy.dart:70-72`

```dart
final jitterMs = base * jitterFraction * (rand.nextDouble() * 2 - 1);
final delay = (base + jitterMs).round().clamp(0, backoff.maxMs);
```

Với `jitterFraction` gần 1.0 và roll ngẫu nhiên gần `-1`, `delay` có thể về gần 0 — cho phép retry gần như ngay lập tức bất kể số lần fail liên tiếp. Tính năng **opt-in, mặc định `0.0`** (tắt), nên không phải bug ảnh hưởng hành vi mặc định — nhưng docstring hiện chỉ ghi "±fraction" mà không cảnh báo rằng ở fraction cao nó xoá sạch tác dụng backoff, dễ khiến 1 host tự cấu hình cao mà không nhận ra hệ quả (spam request khi mất mạng kéo dài). Cần verify thêm: có host thật nào đang dùng `jitterFraction` cao hay không — nếu không ai dùng thì đây thuần là rủi ro tài liệu, ưu tiên thấp.

**Đề xuất fix:** cập nhật docstring cảnh báo rõ, hoặc clamp sàn tối thiểu (ví dụ không cho `delay` xuống dưới `base * (1 - jitterFraction * 0.9)`).

---

### MINOR-3 — Example app không demo wiring VIP key-revocation (CRL)

**File:** `example/lib/main.dart` (không có kết quả grep cho `VipRevocationProvider`/`refreshRevocationList`)

README (dòng ~1387-1414) hướng dẫn đầy đủ cách host tự implement `VipRevocationProvider` để bật tính năng revoke key VIP bị leak, nhưng app mẫu đi kèm SDK — nơi partner hay copy nguyên — không demo việc này. Không phải lỗi code SDK (revocation cố tình transport-agnostic, tài liệu hoá rõ là "host phải tự implement"), nhưng 1 partner theo sát ví dụ có thể ship sản phẩm với tính năng revoke hoàn toàn không hoạt động mà không nhận ra vì ví dụ không nhắc gì tới nó.

---

## Đã kiểm tra kỹ và xác nhận KHÔNG phải bug (loại khỏi finding, tránh false positive)

- **Backoff overflow** (round 37 fix, `backoff.dart:19-37`) và **clock-rollback trên daily/placement cap** (`ad_preferences.dart`) — đọc lại code hiện tại, cả 2 vẫn đúng, không regression.
- **GPP 19 US-state đọc song song** (`iab_storage.dart:396-402`, round 38 fix) — `Future.wait` giữ đúng thứ tự input list bất kể thứ tự resolve, precedence "state đầu tiên có tín hiệu thắng" vẫn đúng.
- **MAJOR-1/MAJOR-2 round 38** (native ad widget retry, `setConsent()` race ở tầng apply) — verify lại đúng, đã fix và có test regression.
- **COPPA-flip branch không epoch-guard** (`ad_manager.dart:3962`, caveat đã ghi nhận ở round 38 lần re-audit 3) — vẫn đúng như mô tả: hiếm, tự lành nhờ `initialize()` chạy lại ngay sau. Không lặp lại như bug mới.
- **Timer/StreamSubscription leak** cho connectivity watch + retry timer — đều được cancel đầy đủ trong `_destroy()` và re-init guard, có gen-token chống race.
- **Trial mode / VIP clock tampering, replay, forge** — trial chính là 1 VIP grant dùng chung entry list (không có 2 hệ thống song song nên không "leak"); chống rollback dùng high-water-mark epoch-ms; Ed25519 verify offline đúng chuẩn, chỉ public key ship trong app; MJ9 (giới hạn pure-Dart clock) đã biết từ trước, không lặp lại.
- **Cross-type ad overlap** (`_fullscreenBusyReason`, dùng nhất quán ở cả 4 loại show*, re-check sau mọi await dài) — không tìm được cách stack 2 loại ad khác nhau chồng lên nhau ngoài case đã biết.
- **Dual-provider parity offline/online**: `canReload()` gate bao gồm `isConnected`, áp dụng đối xứng ở AdMob và AppLovin; AppLovin không có expiry-guard như AdMob nhưng đây là chủ ý đã ghi chú (AppLovin tự quản cache, không document expiry).

## Điểm tổng: 9.0/10

Căn cứ: không có BLOCKER; 3 MAJOR mới đều thuộc dạng "cơ chế bảo vệ có ở chỗ này nhưng thiếu ở chỗ song song" (cùng pattern lỗi round 38 đã tự nhận là điểm mù quy trình review, lặp lại lần nữa) — phạm vi hẹp, đã có ít nhất 1 lớp phòng thủ liền kề đúng (epoch guard cho apply, zone guard cho init-time flow, cap CTR tổng thể vẫn hoạt động dù bị pha loãng), nên rủi ro thực tế thấp-vừa chứ không phải lỗi thiết kế lớn; nhưng đủ 3 finding thật, có bằng chứng cụ thể, kèm 1 finding (MAJOR-1) có khả năng gây lệch state consent xuyên phiên (persistent, không tự lành) nên không thể chấm ngang round 38 (9.5/10).

## Kết luận: CÓ NÊN đưa vào production — CÓ, với điều kiện

**Được, nhưng nên fix MAJOR-3 (UMP retry zone-guard) trước khi mở rộng traffic** — đây là rủi ro crash thật dù precondition hẹp (host có UMP native integration lỗi + mạng chập chờn), và fix rất rẻ (bọc `runZonedGuarded` giống hệt pattern đã có sẵn 3 dòng phía trên trong cùng file).

MAJOR-1 (consent persist race) và MAJOR-2 (CTR dilution) nên fix trong release kế tiếp nhưng không chặn production ngay: MAJOR-1 cần double-toggle rất nhanh + trễ platform-channel bất lợi mới lộ ra, và tự "tự lành" nếu user set lại consent bất kỳ lúc nào sau đó; MAJOR-2 là gap trong lớp phòng thủ thứ cấp (Google/AppLovin vẫn có invalid-traffic detection riêng ở tầng network của họ), không phải lỗ hổng duy nhất chống fraud.

3 MINOR không chặn production, có thể xếp vào backlog thông thường.
