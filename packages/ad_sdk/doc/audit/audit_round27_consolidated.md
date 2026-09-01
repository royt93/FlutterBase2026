# Audit round 27 — verdict tổng hợp

**Ngày:** 2026-09-01
**Commit audit bắt đầu:** `d25e43d` (2.9.4)
**Bối cảnh:** audit toàn diện theo yêu cầu user — đối chiếu 7 yêu cầu sản
phẩm (như round 26) + đánh giá riêng độ đầy đủ của `doc/AD_PROMPT_FLUTTER.MD`
như tài liệu handoff độc lập cho partner engineer, + so sánh với bản mới
nhất trên pub.dev.

**Reviewer:** 3 CLI độc lập chạy song song (`codex`, `agy`/gemini, `claude`
phiên chính) — mỗi bên đọc `audit_round26_consolidated.md` làm baseline rồi tự
audit `git diff de9c40a..HEAD` (batch ticket T101-T130, 30 ticket) độc lập,
không thấy báo cáo của nhau trước khi viết. Báo cáo gốc: `audit_codex_round27.md`,
`audit_agy_round27.md`, `audit_claude_round27.md`.

---

## 1. Đồng thuận cả 3 reviewer — không có regression, không có BLOCKER mới

Cả 3 độc lập xác nhận: kiến trúc round 26 còn nguyên vẹn, 30 ticket batch
T101-T130 "kỷ luật, được test kỹ" (agy), không có gì trong batch chạm tới
consent/VIP/trial-mode làm hỏng baseline. T115 (`AsyncEpoch` migration vào
`AdLoadingDialog`) được cả 3 xác nhận **hành vi tương đương 100%** bộ đếm
`_generation` cũ.

## 2. Finding MỚI — cả 3 reviewer tìm ra ĐÚNG 1 vấn đề giống hệt nhau

**T102 (`AdManager.destroy()` await event-log flush, merge trong 2.9.4 hôm
nay) thiếu timeout** — khác với các đường teardown liền kề trong cùng hàm
(`_eventStream.close()` có timeout 2s, fullscreen-show drain có timeout 5s).
Nếu write `SharedPreferences` bị treo, `destroy()` treo vĩnh viễn và mọi
`initialize()` sau đó cũng treo theo qua `_destroyInFlight`.

- `codex`: "NEW MAJOR — T102 makes teardown availability depend on unbounded storage write"
- `agy`: "NEW MAJOR Finding: Teardown Availability Dependency on Unbounded Platform Storage Write" — cùng khuyến nghị `.timeout(const Duration(seconds: 2))`
- `claude`: xác nhận độc lập bằng đọc source trực tiếp trước khi thấy 2 báo cáo kia, cùng kết luận

**Đã hỏi user qua AskUserQuestion → chọn "vá ngay". Đã fix, mutation-verified:**
`lib/src/core/ad_manager.dart` — bọc `_eventLog?.flush()` bằng
`.timeout(const Duration(seconds: 2), onTimeout: ...)`, cùng pattern với
`_eventStream.close()` ngay phía trên. Test mới trong
`test/destroy_awaits_event_log_flush_test.dart` ("destroy() gives up on a
stuck flush instead of hanging forever"): dùng `debugPersistDelay = 10s`
(dài hơn timeout 2s nhiều), assert `destroy()` trả về trong < 3s.
**Revert → hang thật ~10s + assertion đỏ. Fix → xanh trong < 3s.** Version
2.9.4 → **2.9.5**.

## 3. Finding MINOR mới — chỉ `agy` bắt được, đã verify và fix

`example/test/home_page_test.dart:24` assert `findsNWidgets(17)` nhưng
`example/lib/shared/home_page.dart` thực tế có 18 `DemoTile(` (tile "Adaptive
surface" T124 thêm ở 2.9.1 không được cập nhật vào test). Tự verify bằng
`grep -c "DemoTile(" example/lib/shared/home_page.dart` → 18. Đã fix
(17→18), test xanh.

## 4. 2 MAJOR cũ từ round 26 — ĐÃ FIX trong round này (2.9.6)

Cả 3 reviewer xác nhận cả hai còn nguyên tại thời điểm audit; sau đó user
chọn "fix ngay" cho cả hai qua AskUserQuestion (khác round 26, lúc đó chọn để
sau):

1. `lib/src/vip/_redeemed_key_ledger.dart` `markRedeemed()` — race
   read-modify-write không lock trên Keychain iOS. **FIXED**: mỗi write giờ
   chain vào write trước (cùng idiom `AdEventLog._persistChain`).
   Mutation-verified (`test/redeemed_key_ledger_test.dart` — 2 redeem đồng
   thời, revert → mất 1 kid/đỏ, fix → cả 2 kid còn/xanh).
2. `lib/src/adapters/admob_adapter.dart` — nhánh `onFailed` của 4 loại
   fullscreen ad thiếu `_discardIfDisposed` guard mà `onLoaded` có. **FIXED**:
   thêm `_fullscreenDisposed` guard vào cả 4 vị trí + null hoá `eventSink`
   cuối `dispose()` làm lớp phòng thủ thứ hai. Mutation-verified
   (`test/admob_adapter_test.dart`, 1 test/loại ad, dùng bridge giả có thể
   trễ callback `onFailed` tới sau `dispose()`).

Chi tiết đầy đủ: `CHANGELOG.md` mục **[2.9.6]**.

## 5. BLOCKER — AppLovin key/ad-unit ID chưa rotate — TÁI XÁC NHẬN Y NGUYÊN ROUND 26

Cả 3 reviewer grep lại toàn bộ diff `de9c40a..HEAD` cho pattern SDK
key/ad-unit ID thật → **0 leak mới**. Rotation trên dashboard AppLovin vẫn
chưa được xác nhận (hành động ngoài source, không tự verify được).

**User đã được hỏi lại qua AskUserQuestion (round 27) và chọn giữ nguyên
quyết định round 26: chấp nhận rủi ro, không rotate ngay vì repo đang
private.** Đây là lần thứ 2 user xác nhận cùng lựa chọn — **từ nay không hỏi
lại vấn đề này trong các round audit sau nữa**, chỉ nêu là điều kiện còn treo
(risk-accepted) trong báo cáo, trừ khi user tự chủ động nhắc lại.

## 6. Đánh giá riêng: `doc/AD_PROMPT_FLUTTER.MD` có đủ để 1 AI agent tích hợp "full mọi tính năng" không?

(Câu hỏi 1 của user hôm nay, xem chi tiết đầy đủ trong `audit_claude_round27.md` phần 1.)

**Kết luận ngắn gọn: KHÔNG đủ cho "full mọi tính năng", dù RẤT ĐỦ cho phần
lõi khó nhất.** File làm rất tốt: bootstrap, splash, VIP UI 13-component,
consent 3 mảnh (UMP/ATT/Cupertino), trial mode (first-install grace) và
anti-bypass, memory-leak checklist, policy 5-rule — tất cả khớp chính xác với
source hiện tại. Nhưng **thiếu hoàn toàn 3/7 loại ad-surface có thật trong
SDK**: MREC (`buildMrec()`), Native (`buildNative()`/`NativeAdWidget`),
Rewarded Interstitial (`showRewardedInterstitialAd()`) — không được nhắc tới
trong touchpoint table hay bất kỳ lifecycle step nào, chỉ thấy MREC lướt qua
1 lần trong phụ lục migration. Một agent chỉ có file này sẽ tích hợp đúng 4/7
loại ad và không biết 3 loại kia tồn tại. Cũng phát hiện thêm: compliance
nuance COPPA (AppLovin không có runtime child-directed flag, khác AdMob) bị
rút gọn còn 2 dòng code mẫu, không giải thích rủi ro thật cho app luôn hướng
tới trẻ em.

**Cập nhật cùng round (2.9.6):** Rewarded Interstitial giờ đã có demo +
widget test + integration test trong example app (xem mục 4/CHANGELOG) — gap
"SDK có tính năng nhưng 0 chỗ nào thực nghiệm được" đã đóng. `AD_PROMPT_FLUTTER.MD`
**chưa được sửa** (ngoài phạm vi được duyệt trong round này) — vẫn thiếu
touchpoint cho cả 3 surface, khuyến nghị dưới đây còn nguyên giá trị.

**Trùng hợp đáng chú ý:** `agy` (được giao audit source, KHÔNG được giao đọc
`AD_PROMPT_FLUTTER.MD`) tự đề xuất độc lập trong action-item #6: *"Maintain
Documentation Integrity: Ensure any companion integration prompts (such as
AD_PROMPT_FLUTTER.MD) include clear integration instructions for MREC,
Native, and Rewarded Interstitial formats, as well as COPPA pre-init
restrictions."* — khớp gần như nguyên văn với finding độc lập của `claude`.
**Khuyến nghị (chưa làm trong round này, để user quyết định ưu tiên):** thêm
Step 4.8/4.9/4.10 cho 3 surface còn thiếu vào `AD_PROMPT_FLUTTER.MD`, theo
đúng pattern các step hiện có.

## 7. Đối chiếu 7 yêu cầu sản phẩm — không đổi so với round 26

| # | Yêu cầu | Kết quả |
|---|---|---|
| 1 | AdMob + AppLovin, Android + iOS | ✅ PASS |
| 2 | Có mạng / không mạng | ✅ PASS |
| 3 | 4 loại ad, lifecycle, no-leak | ⚠️ PASS-with-caveat — caveat T102 flush timeout **đã đóng trong round này**; caveat MAJOR #2 (AdMob onFailed) vẫn mở |
| 4 | Trial 1 ngày | ✅ PASS — không ticket nào trong T101-T130 chạm `_first_install_guard.dart` |
| 5 | VIP by-code, không backend | ⚠️ PASS-with-caveat — MAJOR #1 (ledger race) vẫn mở |
| 6 | Consent mọi quốc gia | ✅ PASS — không gì mới chạm consent, khoảng hở round-26 vẫn đóng |
| 7 | Policy compliance | ⚠️ PASS-with-caveat — vẫn chặn về mặt formal bởi BLOCKER key rotation (risk-accepted, không phải finding mới) |

## Kết luận production

**Sẵn sàng production: YES WITH CONDITIONS** — verdict text không đổi, nhưng
nội dung điều kiện đã thu hẹp đáng kể: cả 2 MAJOR round-26 (ledger race,
AdMob onFailed guard) và MAJOR mới của round này (T102 flush timeout) đều đã
fix + mutation-verify trong cùng round, không tồn đọng sang round sau. Chỉ
còn 1 điều kiện thật sự treo.

Điều kiện còn lại:
1. Rotate AppLovin key + 8 ad-unit ID trên dashboard **trước khi** mở quyền
   truy cập repo ra ngoài team hiện tại hoặc public hoá — user đã chấp nhận
   rủi ro tạm thời (2 lần xác nhận, round 26 và 27), đây không phải blocker
   chặn ship nội bộ. Không hỏi lại vấn đề này ở các round sau.
2. (Khuyến nghị, không chặn) bổ sung MREC/Native/RewardedInterstitial vào
   `AD_PROMPT_FLUTTER.MD` — example app đã có demo đầy đủ cho cả 3, chỉ còn
   tài liệu handoff chưa cập nhật theo.

**Điểm trung bình 3 reviewer tại thời điểm audit:** codex 7/10, agy 8.5/10,
claude 8/10 → **~7.8/10**. Điểm này chưa phản ánh 2 MAJOR đã fix sau đó
trong cùng round — thực tế cao hơn.

**Kiểm chứng cuối round:** `flutter analyze` sạch cả 2 package. `flutter
test` (package `ad_sdk`): **1.482/1.482 pass**. `example`: toàn bộ unit +
widget test pass (bao gồm `home_page_test.dart` 19 tile,
`rewarded_interstitial_demo_page_test.dart` mới). On-device integration
test mới (`rewarded_interstitial_ad_test.dart`) verified PASS trên Android
emulator (`sdk gphone16k arm64`, khớp phương pháp CI job `sdk-integration`);
chạy trên iOS Simulator bị chặn bởi giới hạn môi trường đã biết (UMP form
không present được trong `integration_test` harness trên Simulator — xem
memory `ios-simulator-cannot-run-consent-integration-tests`), không phải
regression. Version **2.9.4 → 2.9.6**, `CHANGELOG.md` đã cập nhật đầy đủ 3
version (2.9.5, 2.9.6). Chưa publish lên pub.dev (chờ user xác nhận).
