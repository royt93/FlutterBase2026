# Audit round 35 — line-by-line source audit + living-docs staleness pass

Ngày: 2026-09-04. Bối cảnh: sau round 34 (đã publish, verdict "dùng được cho
production"), user vẫn chưa an tâm, yêu cầu audit lại **từng dòng** toàn bộ
source (không phải diff-since-last-round) và rà tất cả file `.md` còn sống
xem lỗi thời.

## Phương pháp

4 fork (kế thừa context phiên này, cùng model, không phải CLI ngoài — tránh
lặp sự cố round 34 với agent bypass-permission tự ý commit) chạy song song,
mỗi fork đọc thật kỹ (không skim) một cụm module, có danh sách loại trừ rõ
ràng các item đã biết/đã chấp nhận từ 34 round trước để tránh nhiễu:

| Fork | Phạm vi | Kết quả |
|---|---|---|
| 1 | `lib/src/core/` (11424 dòng, kể cả `ad_manager.dart` 7642 dòng) | 1 finding MAJOR mới |
| 2 | `lib/src/adapters/` + `lib/src/vip/` (~10900 dòng) | 0 finding mới (một số đoạn banner/mrec/native load và VIP grace/stacking logic chưa kịp đọc 100% trong ngân sách) |
| 3 | `lib/src/consent/compliance/monetization/config/utils/state/widget/adaptive/` (~8971 dòng) | 2 finding MINOR mới |
| 4 | Toàn bộ doc "còn sống" (CLAUDE.md, README.md, CHANGELOG.md, doc/feature.md, doc/architecture.md, doc/README_TESTING.md, doc/TODO.md, doc/SPLASH_SETUP.md, doc/UMP_SETUP.md, doc/AD_PROMPT_FLUTTER.MD, doc/init.md) | 4 chỗ số liệu lỗi thời, không nguy hiểm |

Mỗi finding trước khi báo cho user đều được **tự tay verify lại bằng cách
đọc source thật** (đúng bài học từ round 34's F5 — không tin báo cáo agent
nào, kể cả của chính mình, cho tới khi tự đọc code xác nhận cơ chế).

## Finding thật, đã verify, đã fix (TDD: viết test đỏ trước, sửa, xanh)

### R35-01 (MAJOR) — `ad_crash_guard.dart`: crash guard bắt nhầm lỗi của host app

`isSdkAttributable(StackTrace stack)` cũ: `stack.toString().contains('package:applovin_admob_sdk/')`
— khớp nếu package SDK xuất hiện **ở BẤT KỲ ĐÂU** trong toàn bộ stack trace.
Nhưng SDK luôn nằm trên stack ngay dưới bất kỳ callback nào của host
(`onReward`, `onAdDismiss`, `onAdClicked`...) vì chính SDK là nơi gọi
callback đó — nên **gần như mọi bug thật trong callback quảng cáo của host
app đều bị nhận nhầm là "lỗi SDK"**, bị `installAdCrashGuard()` nuốt âm
thầm (chỉ log tag nội bộ `AdCrashGuard`, không bao giờ tới
Crashlytics/Sentry/crash handler của host), trái ngược đúng mục đích đã ghi
trong doc-comment ("Anything NOT attributable to this SDK is passed through
untouched").

**Fix:** chỉ kiểm tra dòng đầu tiên (không rỗng) của stack trace — đúng nơi
exception thực sự phát sinh — thay vì toàn bộ chuỗi.

**Test:** `test/ad_crash_guard_test.dart` — thêm test dựng
`StackTrace.fromString(...)` mô phỏng đúng kịch bản (frame #0 là code host,
frame #1-2 là SDK) → RED với code cũ (`Expected: false, Actual: true`) →
GREEN sau fix. 10/10 test trong file pass.

### R35-02 (MINOR) — `consent_manager.dart`: `bootstrap()` bỏ qua âm thầm tham số `prefs` ở lần gọi thứ 2

Doc-comment cũ đã ghi đúng hành vi ("a second call updates strings... does
not re-run init side-effects") nhưng không cảnh báo gì khi điều đó thực sự
âm thầm bỏ tham số `prefs` mới. Rủi ro thực tế thấp (host luôn dùng chung 1
singleton `AdPreferences`), nhưng hợp đồng API dễ gây hiểu lầm cho code mở
rộng sau này.

**Fix:** thêm `SafeLogger.w(...)` khi lần gọi thứ 2 truyền `prefs` khác
instance đã dùng — hành vi runtime không đổi, chỉ thêm cảnh báo hiển thị.

**Test:** `test/consent_manager_test.dart` — bootstrap 2 lần với 2
`AdPreferences` khác nhau, assert có warning qua `SafeLogger.configure(onLog: ...)`.
RED → GREEN. 14/14 test trong file pass.

### R35-03 (MINOR) — `journey_prefetcher.dart`: 1 show event tính nhầm cho nhiều signal khác nhau

`_onEvent()` cũ lặp qua **mọi** entry `_lastSignalAt` khớp `AdSlotType`,
ghi sample + xoá **tất cả**. Nếu 2 signal khác nhau (vd `"levelStarted"` và
`"screenEntered"`) cùng đang chờ cho cùng 1 loại quảng cáo, 1
`AdShowEvent` thành công bị tính là mẫu thời gian cho **cả hai**, lẫn dữ
liệu giữa 2 signal không liên quan. Chỉ ảnh hưởng chất lượng gợi ý preload
(tính năng tùy chọn, mặc định tắt) — không phải an toàn/chính sách/leak.

**Fix:** chỉ khớp và giải quyết signal có `DateTime` gần nhất (mới fire gần
đây nhất) cho loại quảng cáo đó, để nguyên các signal khác đang chờ.

**Test:** `test/journey_prefetcher_test.dart` — 2 signal cùng chờ 1 type, 1
show event, assert KHÔNG cả 2 đều được ghi nhận. RED → GREEN. 7/7 test
trong file pass.

## Finding khác đã cân nhắc, quyết định KHÔNG sửa (rủi ro thấp/ngoài phạm vi)

Không có — 3 finding trên là toàn bộ finding thật tìm được và cả 3 đều đã
fix theo yêu cầu user.

## Doc lỗi thời — đã sửa, đổi sang tham chiếu thay vì ghi số cứng

Theo phản hồi của user ([[avoid-hardcoded-version-numbers-in-docs]]): sửa
nhưng KHÔNG ghi lại số cụ thể mới (sẽ lại lỗi thời lần release sau), thay
bằng câu trỏ tới `CHANGELOG.md`'s top entry:

- `CLAUDE.md:17` — "140 files, 1562 tests" (thực tế 1571 trước round 35,
  1574 sau round 35) → đổi thành "see CHANGELOG.md's latest entry".
- `packages/ad_sdk/doc/feature.md` (3 chỗ) — "current: 2.4.0" (thực tế
  2.9.15) → đổi thành "see CHANGELOG.md's top entry".
- `packages/ad_sdk/doc/README_TESTING.md` — banner tự-flag "OUTDATED" vẫn
  ghi số liệu cụ thể cũ ("1562/1562... SDK v2.9.14") → đổi thành tham
  chiếu chung.
- `packages/ad_sdk/doc/architecture.md` — bảng versioning tự nhận "stopped
  being kept in lockstep" nhưng vẫn ghi mốc cứng "2.4.1–2.9.14" → đổi
  "2.4.1–current" + tham chiếu CHANGELOG.

Các doc khác đã tự đóng dấu "STALE/WRONG REPO SCOPE" từ trước
(`doc/SPLASH_SETUP.md`, `doc/UMP_SETUP.md`, `doc/init.md`, `doc/TODO.md`)
— verify claim "còn đúng" bên trong các banner đó vẫn khớp code thật, không
cần sửa thêm.

## Kết quả kiểm chứng

`flutter analyze`: sạch. `flutter test`: **1574/1574 pass** (1571 cũ + 3
test mới, TDD red→green đầy đủ cho cả 3 fix).

## Phạm vi còn nợ — ĐÃ ĐỌC HẾT (cập nhật cùng ngày)

Phần còn thiếu ở trên (`applovin_adapter.dart` dòng ~1300–2571,
`vip_manager.dart` ~500–1280 và ~1462–1779, `vip_redeem_screen.dart` toàn
bộ 1458 dòng, `vip_dialog_strings.dart`) đã được 1 fork riêng đọc hết
line-by-line ngay trong ngày. **Kết quả: không có finding mới.** Mọi
callback có guard `identical()` chống stale-callback, mọi preload xử lý
đúng disposed-mid-await, `vip_redeem_screen.dart` 100% dùng
`ValueListenableBuilder`/`ValueNotifier` (không `setState`, loại trừ hẳn
lớp bug "setState sau dispose"), mọi async handler check `mounted` sau
await trước khi đụng `context`, `dispose()` giải phóng đủ mọi
controller/subscription/timer.

1 điểm không chắc chắn được nêu tham khảo (không phải finding độc lập):
`vip_redeem_screen.dart`'s `_onWatchAdForVip` đợi 1 `Completer<bool>` được
complete bởi `onEarnedReward`; nếu native rewarded ad treo SAU khi đã hiển
thị (không phải never-confirmed-show), nút "Watch ad" có thể kẹt ở trạng
thái processing — nhưng đây là hệ quả trực tiếp của tradeoff **đã biết và
đã chấp nhận** ở `applovin_adapter.dart` (không có watchdog đối xứng cho
rewarded/interstitial sau khi show, ghi rõ lý do trong code, round-10-E),
không phải bug mới của riêng file này.

**Kết luận: audit line-by-line toàn bộ `lib/src/` đã hoàn tất trong round
35 — không còn vùng nào chưa được đọc trực tiếp.**

## Review độc lập (fork adversarial) + đóng gap + smoke test thiết bị thật

Sau khi 3 fix + test ban đầu xanh, 1 fork khác (không phải người viết fix)
review adversarial riêng diff `211b942..fd15ac1`, tự thực nghiệm lại giả
định kỹ thuật cốt lõi (frame đầu tiên của stack trace luôn đúng nơi throw,
kể cả qua async gap — verify bằng code Dart thật với `runZonedGuarded`).
**Điểm ban đầu: 8.5/10**, 3 gap thật:

1. `journey_prefetcher.dart` — so sánh "signal gần nhất" bằng `DateTime`
   dùng `isAfter` (tương đương `>`), có thể sai nếu 2 signal trùng đúng 1
   timestamp (độ phân giải đồng hồ) — entry chèn trước trong map thắng do
   thứ tự lặp, không phải do gọi sau thật. **Sửa tận gốc**: thêm bộ đếm
   `_sequence` tăng dần làm tiêu chí so sánh (miễn nhiễm với tie đồng hồ)
   + inject clock để test tái hiện tie xác định (không phụ thuộc may rủi
   đồng hồ thật).
2. `ad_crash_guard_test.dart` — thiếu test stack trace rỗng/toàn khoảng
   trắng. Đã thêm 2 test.
3. `consent_manager_test.dart` — thiếu test âm (gọi lại `bootstrap()` với
   **cùng** instance — đúng pattern `AdManager.initialize()` dùng thật —
   không được warn). Đã thêm.

Bổ sung thêm (không phải gap bị chỉ ra, nhưng nâng chất lượng chứng minh):
test dùng stack trace THẬT (ném qua `MonetizationArbitrator.decide()` thật,
không phải `StackTrace.fromString(...)` giả lập), 1 test full-pipeline qua
đúng `installAdCrashGuard()` (không chỉ hàm thuần `isSdkAttributable`), 1
**widget test** dùng `testWidgets`/`tester.takeException()` chứng minh fix
đứng vững dưới cơ chế bắt lỗi thật của Flutter khi widget `build()` throw,
và 1 **integration test** (`example/integration_test/
crash_guard_host_bug_test.dart`) chạy full pipeline này trên **thiết bị
Android thật** (TECNO KJ7, Android 14, arm64) — **PASS**.

**Kết quả cuối:** `flutter test`: 1581/1581 pass, `flutter analyze` sạch.
**Điểm cuối: 9.5/10** (không tuyệt đối 10 vì chưa verify được dưới build
`--release --obfuscate` thật — obfuscation xoá hẳn path
`package:applovin_admob_sdk/` nên cơ chế attribution này vốn không dùng
được trong kịch bản đó, một giới hạn tách biệt khỏi fix, đã ghi rõ trong
comment file test). Đủ điều kiện >9/10 theo tiêu chí user đặt ra — đã push
`00cf21c`.

## Verdict

Không có finding nào đủ nghiêm trọng để đổi khuyến nghị "dùng được cho
production" từ round 34. 3 bug thật tìm được (1 MAJOR ảnh hưởng tới việc
host app có thấy crash report của chính mình hay không, 2 MINOR chất lượng
dữ liệu) đã fix và verify xanh. Docs đã cập nhật để không lặp lại kiểu lỗi
thời "ghi số cứng rồi quên cập nhật" từng gặp ở round 34.
