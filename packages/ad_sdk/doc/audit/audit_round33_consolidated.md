# Audit round 33 — consolidated (3 agent độc lập + tự verify) — applovin_admob_sdk 2.9.14

> **Cập nhật 2.9.15 (2026-09-03):** user đã review 3 finding dưới đây và quyết định xử lý từng
> cái riêng biệt (không "sửa tất cả theo mặc định"). Kết quả:
> - **R33-01 (BLOCKER, AppLovin consent-apply không xác nhận được):** **KHÔNG sửa code** — đây là
>   giới hạn của dependency `applovin_max` (API `void`, fire-and-forget), không thể sửa triệt để
>   chỉ bằng code phía SDK này. Quyết định: ghi nhận là known limitation trong `README.md` và
>   `doc/AD_PROMPT_FLUTTER.MD` (step 4.11) thay vì tạo cảm giác an toàn giả. Vẫn là BLOCKER thật
>   cho app có traffic AppLovin ở EEA/UK/California — xem phần known limitations để biết đầy đủ.
> - **R33-02 (MAJOR, GPP US-state chưa parse):** **Đã sửa** (TDD, RED→GREEN) —
>   `IabStorage.usPrivacyOptedOut()` giờ fallback đọc GPP USNAT (section id 7) khi không có legacy
>   `IABUSPrivacy_String`. Chuỗi legacy vẫn có ưu tiên cao hơn khi tồn tại. Xem CHANGELOG `[2.9.15]`.
> - **R33-03 (MAJOR, nghi vấn double-count AppLovin banner/MREC/native):** **Đã vá phòng ngừa**
>   (TDD, RED→GREEN) dù chưa xác nhận được là bug thật (không có thiết bị để test) — thêm guard
>   so khớp identity trước khi ghi nhận revenue cho banner/MREC, và check tombstone đã dispose cho
>   native. Xem CHANGELOG `[2.9.15]`.
>
> `flutter analyze` sạch, 1571/1571 test pass (1567 cũ + 4 test mới) sau các thay đổi trên.

**Ngày:** 2026-09-02. **Bản audit:** pubspec 2.9.14, đúng bản mới nhất trên pub.dev (publish
trong vòng 1 giờ trước khi audit — repo local = bản đã publish, không có gap).

**Phương pháp:** chạy 3 agent độc lập song song, không cho thấy báo cáo của nhau, cùng 1 đề bài
— verify 3 commit fix sau round 32 (`3b0a8ac`/2.9.12, `e7c770e`/2.9.13, `0b2bd54`/2.9.14) rồi
audit lại từ đầu (không chỉ diff) trên các trục: dual-provider Android+iOS, online/offline, vòng
đời + policy từng loại ad + không leak, trial 1 ngày, VIP by-code offline, consent mọi quốc gia,
tuân thủ policy AdMob/AppLovin.

| Agent | BLOCKER | MAJOR | Verdict tự báo |
|---|---|---|---|
| Codex (`gpt-5.6-sol`) | 2 | 2 | **KHÔNG ship nguyên trạng** (nếu có AppLovin hoặc consent pháp lý) |
| agy/Gemini | 0 | 0 (3 MINOR/known-limit) | **APPROVED FOR PRODUCTION** |
| Claude (fork, tự đọc source) | 0 | 0 | **SHIP** |

**3 agent lại ra 3 verdict khác nhau — đúng pattern round 32.** Điểm khác biệt mấu chốt: Codex
là agent duy nhất lần vào **source thật của dependency `applovin_max`** (không chỉ code của SDK
này) để kiểm tra xem `try/catch` quanh lệnh gọi AppLovin có thực sự bắt được lỗi platform-channel
hay không. Claude-fork và agy chỉ verify logic điều kiện Dart (`if (appLovinApplied && adMobApplied)`)
mà không lần xuống một tầng nữa — cùng một loại thiếu sót "self-review miss" đã ghi nhận ở round
trước ([[self-review-misses-what-independent-review-catches]]).

## Tôi (orchestrator) tự verify lại — xác nhận Codex đúng

Đọc trực tiếp `~/.pub-cache/hosted/pub.dev/applovin_max-4.6.4/lib/applovin_max.dart:191-211`:

```dart
static void setHasUserConsent(bool hasUserConsent) {
  _methodChannel.invokeMethod('setHasUserConsent', {'value': hasUserConsent});
}
static void setDoNotSell(bool isDoNotSell) {
  _methodChannel.invokeMethod('setDoNotSell', {'value': isDoNotSell});
}
```

Cả 2 hàm là `static void` — gọi `invokeMethod` (trả về `Future<dynamic>`) nhưng **không lưu,
không return, không await** Future đó. Đây là fire-and-forget: nếu platform channel lỗi
(`PlatformException`, `MissingPluginException`...), lỗi chỉ xuất hiện dưới dạng **unhandled Future
rejection** sau khi hàm `void` đã return xong — nó không bao giờ ném ngược lên call stack đồng bộ.

Đối chiếu `lib/src/core/ad_consent.dart:148-175` (code hiện tại):

```dart
try {
  AppLovinMAX.setHasUserConsent(outcome.appLovinHasUserConsent);
  AppLovinMAX.setDoNotSell(outcome.appLovinDoNotSell);
  ...
  appLovinApplied = true;
} catch (e) {
  SafeLogger.w(tag, 'AppLovin privacy apply failed: $e');
}
```

`try/catch` này **chỉ bắt được exception Dart đồng bộ** (ví dụ `AppLovinMAX` class chưa init) —
gần như không bao giờ xảy ra trong thực tế. Lỗi platform-channel thật (channel chưa sẵn sàng,
native side ném exception, app đang background lúc gọi...) **không được `catch` nhìn thấy**, nên
`appLovinApplied = true` được set gần như vô điều kiện trên thực tế, bất kể AppLovin native có
thực sự nhận và áp dụng consent hay không.

**Kết luận: BLOCKER-A của round 32 CHƯA được fix triệt để ở nhánh AppLovin.** Round 32 xác định
đúng bug (ghi "đã apply" dù có thể chưa), fix 2.9.12 sửa đúng phần điều kiện Dart-side (nhánh
AdMob giờ có `await` thật nên đáng tin), nhưng nhánh AppLovin vẫn mang cùng bản chất lỗi vì API
`applovin_max` không cho Dart-side biết kết quả thật. Đây không phải false-positive — đã tự verify
qua source thật của cả 2 lớp (SDK này + dependency).

**Mã hoá lại thành finding round 33:**

### BLOCKER R33-01 — `applyConsentToProviders()` vẫn có thể ghi nhận AppLovin "đã áp dụng" dù platform channel thất bại

- **File:** `lib/src/core/ad_consent.dart:148-175` (call site), root cause ở
  `applovin_max-4.6.4/lib/applovin_max.dart:191-211` (dependency, ngoài tầm sửa trực tiếp của SDK
  này — không thể `await` một API không trả `Future`).
- **Kịch bản lỗi:** người dùng EEA rút consent → `applyConsentToProviders` gọi
  `AppLovinMAX.setDoNotSell(true)` → platform channel tạm lỗi (background app, cold channel...) →
  Dart-side không biết, `appLovinApplied = true` → `_lastAppliedToProviders` được ghi nhận →
  `reconcile-on-resume` so khớp và **không retry** → AppLovin native tiếp tục phục vụ ad cá nhân
  hoá cho người dùng đã từ chối. Vi phạm GDPR/CCPA thật, không chỉ sai số liệu nội bộ.
  **Ai không thể tự sửa 100%:** vì `applovin_max` không expose kết quả platform-channel, SDK này
  không thể biết chắc chắn call có thành công không chỉ bằng cách "sửa nhiều hơn ở Dart-side" —
  cần 1 trong các hướng: (a) đợi một callback/getter xác nhận từ AppLovin (nếu SDK native có expose
  — cần audit thêm phía plugin), (b) luôn coi AppLovin write là "chưa chắc chắn" và định kỳ
  re-apply bất kể có throw hay không (loại bỏ khái niệm "applied" one-shot cho riêng nhánh
  AppLovin), hoặc (c) báo cáo lên upstream `applovin_max` để họ đổi API trả `Future`.

### MAJOR R33-02 (giữ nguyên mức từ round 32 #6, không nâng cấp) — GPP string chưa được parse, chỉ đọc legacy US Privacy string

`lib/src/core/iab_storage.dart:161-165` — comment trong code xác nhận đây là quyết định **chủ ý**
từ trước ("mis-parsing a privacy signal is worse than not reading one"), không phải hồi quy mới.
Codex xếp finding này BLOCKER trong báo cáo riêng; tôi giữ nguyên MAJOR như round 32 đã xếp, vì
không có gì thay đổi về bản chất rủi ro giữa 2 vòng — nếu target có bang Mỹ mới chỉ ghi GPP (không
ghi USP legacy), host phải tự map thêm, đúng như round 32 đã kết luận.

### MAJOR R33-03 (chưa kết luận được, cần test thiết bị thật) — AppLovin banner/MREC/Native revenue callback: chưa rõ ownership guard khi widget rebuild/dispose

Codex nêu nghi vấn: `_AppLovinMaxAdView` là `StatelessWidget` dựng lại theo `ValueListenableBuilder`
(auto-refresh) — nếu `MaxAdView` cũ chưa kịp destroy ở native mà đã có `MaxAdView` mới, một
callback `onAdRevenuePaidCallback` "trễ" từ instance cũ có thể vẫn bắn vào `eventSink` chung, gây
double-count doanh thu. Đọc source Dart không đủ để khẳng định — phụ thuộc hành vi teardown
platform view phía native `applovin_max`. Cần device test (round 33 không có device) trước khi
xếp loại chắc chắn BLOCKER hay chấp nhận được.

## Đối chiếu 3 verdict — vì sao 2 agent kia bỏ sót

- **agy/Gemini:** trích đúng đoạn code `ad_consent.dart`, nhận xét "CHÍNH XÁC" chỉ dựa vào việc
  điều kiện `if (appLovinApplied && adMobApplied)` tồn tại — không lần vào chữ ký thật của
  `AppLovinMAX.setHasUserConsent`. Verdict APPROVED FOR PRODUCTION dựa trên audit nông hơn ở đúng
  điểm quan trọng nhất, giống hệt lý do round 32 gọi agy "bỏ sót vì audit nông hơn".
- **Claude (fork):** cùng lỗi bỏ sót y hệt agy — verify logic điều kiện Dart, không trace dependency.
  Đây là bằng chứng cụ thể cho lý do phải luôn chạy nhiều agent độc lập thay vì tin 1 báo cáo
  ([[audit-must-be-slow-and-adversarial]]): kể cả Claude tự audit (không phải chỉ Gemini/agy) vẫn
  có thể bỏ sót nếu không đọc đến tầng dependency thật.
- **Codex:** đúng, vì đã chủ động mở source `applovin_max` trong `.pub-cache` thay vì chỉ tin API
  contract từ tên hàm.

## Các finding khác round 33 (không tranh cãi giữa 3 agent, hoặc đã reclassify)

- BLOCKER-B (TCF TimeoutException fail-closed): **cả 3 agent đồng ý đã fix đúng** — tự verify khớp,
  giữ nguyên.
- `remote_ad_safety_provider.dart` sàn `min:1`, `canShowRewardedInterstitialAd` dialog gate,
  example `_navigated` guard, `AdBootstrap` hard-cap: **cả 3 agent đồng ý đã fix đúng.**
- AppLovin Rewarded Interstitial no-op, trial Android best-effort, VIP AVP1 legacy/fail-open
  bundle-binding, không auto-failover AdMob↔AppLovin: **known/intentional limitation**, không phải
  bug mới — không nâng cấp mức độ round này (không có bằng chứng mới).
- Không tìm thấy leak Timer/StreamSubscription/Controller mới ở cả 3 báo cáo.
- `flutter analyze`: 0 issue (2/2 agent xác nhận). `flutter test`: 1562/1562 pass (2/2 agent xác
  nhận số liệu khớp CHANGELOG).

## Kết luận cuối cùng — Có nên dùng production không?

**KHÔNG ship nguyên trạng 2.9.14 nếu có AppLovin trong traffic VÀ có user chịu GDPR/UK-DMA/CCPA
thật** — vì BLOCKER R33-01 (đã tự verify qua source thật của cả SDK lẫn dependency, không phải
suy đoán). Đây là biến thể mới của đúng lỗ hổng round 32 từng chặn ship, chỉ là fix trước chưa đủ
sâu.

**Điều kiện để dùng production:**

1. **Bắt buộc trước khi ship (nếu dùng AppLovin + có user chịu luật riêng tư):** xử lý R33-01 —
   khuyến nghị: đừng coi AppLovin write là "applied" one-shot; định kỳ re-apply consent cho
   AppLovin bất kể có exception hay không (loại bỏ ảo giác "biết chắc đã thành công" cho riêng
   nhánh này, vì API dependency không cho phép biết chắc). AdMob nhánh vẫn giữ nguyên (đã `await`
   thật, đáng tin).
2. Nếu chỉ dùng AdMob (không AppLovin) hoặc target không có nghĩa vụ pháp lý riêng tư nghiêm ngặt:
   **R33-01 không áp dụng**, có thể ship như agy/Claude-fork kết luận.
3. R33-02 (GPP): host tự map thêm nếu target có bang Mỹ mới chỉ dùng GPP — không đổi so với
   khuyến nghị round 32.
4. R33-03: nếu banner/MREC/Native AppLovin đóng góp đáng kể vào dashboard doanh thu, nên device-test
   kịch bản auto-refresh nhanh trước khi tin số liệu tuyệt đối chính xác.
5. Trial/VIP/RI/no-failover: giữ nguyên như round 32 — chấp nhận được như thiết kế hiện tại, không
   phải bug chặn ship.

**So với 2 verdict "APPROVED"/"SHIP" của agy và Claude-fork:** cả hai đúng ở 95% phạm vi audit
(6/6 fix khác đều verify đúng, không leak mới, test xanh thật) nhưng sai đúng ở điểm quan trọng
nhất — nhánh còn lại của chính BLOCKER mà cả 32 vòng trước từng dừng lại để sửa. Dùng verdict của
Codex (không ship nguyên trạng cho AppLovin+EEA/UK/CCPA) làm căn cứ quyết định, không dùng 2 verdict
kia.

## Nguồn báo cáo chi tiết

- `doc/audit/audit_codex_round33.md` — đầy đủ nhất về R33-01/02/03, đọc cả dependency source.
- `doc/audit/audit_agy_round33.md` — audit rộng theo 8 trục nghiệp vụ, tốt cho checklist tổng quan,
  nhưng verdict cuối không đáng tin ở điểm consent.
- `doc/audit/audit_claude_round33.md` — bảng verify 8/8 fix round 32 + fresh scan leak/offline/
  trial/VIP, đầy đủ nhưng cùng lỗ hổng như agy ở phần consent.
