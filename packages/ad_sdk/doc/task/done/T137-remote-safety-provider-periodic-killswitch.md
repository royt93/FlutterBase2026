# T137 — Enhancement: RemoteAdSafetyProvider thêm periodic refresh + kill-switch granular

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P2
- **Status:** 🔲 todo
- **Effort:** L
- **Files (dự kiến):** `lib/src/config/remote_ad_safety_provider.dart`,
  `lib/src/core/ad_manager.dart` (`refreshRemoteSafetyParams()`,
  `initialize()`'s `remoteSafetyProvider` param), `lib/src/config/ad_config.dart`
- **Nguồn gợi ý:** codex + agy đồng thuận
- **Dependency:** T132 (fix stale-session race trong `refreshRemoteSafetyParams()`)
  — **BẮT BUỘC kiểm tra `doc/task/done/T132-*.md` tồn tại trước khi bắt đầu.**
  Thêm auto-refresh định kỳ lên trên 1 method đang có race sẽ nhân bản race
  đó lên nhiều lần (mỗi tick timer là 1 lần race tiềm năng) — phải sửa race
  gốc trước.

## Vấn đề

Đọc toàn bộ `remote_ad_safety_provider.dart` (123 dòng) — xác nhận hiện tại:

- `RemoteAdSafetyProvider` chỉ có 1 method `fetchSafetyParamOverrides()`,
  được gọi 1 LẦN lúc `initialize()` và có thể gọi thủ công qua
  `AdManager().refreshRemoteSafetyParams()` — KHÔNG có cơ chế tự động định
  kỳ nào (host phải tự gọi `refreshRemoteSafetyParams()` theo lịch riêng
  nếu muốn refresh).
- `applyRemoteSafetyOverrides()` chỉ nhận các field số/bool CHUNG cho toàn
  bộ safety params (`maxFullscreenAdsPerDay`, `dryRun`, ...) — KHÔNG có
  field nào tắt riêng theo FORMAT (rewarded/interstitial/banner) hay
  PLACEMENT cụ thể.
- KHÔNG có field `revision`/version nào — 1 payload remote cũ (do lỗi CDN
  cache, hoặc do host vô tình gửi lại config cũ) có thể ghi ĐÈ lên config
  MỚI hơn đã áp dụng, không có gì chặn "rollback" vô tình.

**SDK này KHÔNG dùng remote config/backend riêng** — `RemoteAdSafetyProvider`
vẫn là interface host tự implement (Firebase Remote Config hay bất kỳ gì họ
chọn, xem doc comment ví dụ sẵn có ở đầu file), ticket này CHỈ mở rộng
INTERFACE/khả năng, không phải SDK tự dựng server.

## Việc cần làm

- [ ] Thêm optional `Duration? autoRefreshInterval` — có thể đặt ở
      `AdConfig` (áp dụng chung) hoặc truyền riêng lúc gọi `initialize()`
      cùng `remoteSafetyProvider:` (quyết định chỗ nào hợp API hiện có hơn
      khi đọc kỹdòng gọi `initialize()` thật). Mặc định `null` = giữ
      nguyên behavior cũ (không tự động).
- [ ] Nếu set, `AdManager` tự tạo 1 `Timer.periodic(autoRefreshInterval, ...)`
      gọi `refreshRemoteSafetyParams()` — cancel đúng trong `destroy()`
      (theo đúng pattern các Timer khác trong `ad_manager.dart` đã dùng,
      xem `_resetGuardState()`).
- [ ] Mở rộng override map nhận thêm field mới, tối thiểu:
      `disabledFormats: List<String>` (vd `['rewarded', 'interstitial']`) —
      `applyRemoteSafetyOverrides` parse thành 1 field mới trên
      `AdSafetyParams` (hoặc dùng cơ chế khác nếu `AdSafetyParams` không
      phải chỗ đúng để chặn theo format — đọc kỹ luồng show ad thật trước
      khi quyết định điểm chặn nằm ở đâu).
- [ ] Thêm optional `int? revision` vào override payload — nếu present và
      NHỎ HƠN revision đã áp dụng gần nhất (lưu lại đâu đó, `AdPreferences`
      có sẵn cơ chế lưu key-value), bỏ qua toàn bộ payload đó (giữ
      nguyên params hiện tại), log warning rõ ràng "rejected stale revision".
      Nếu payload không có `revision` (host cũ chưa nâng cấp) → giữ
      behavior cũ, luôn áp dụng (backward-compatible, không breaking).
- [ ] Unit test cho MỌI field mới, cả case hợp lệ lẫn malformed (theo đúng
      tinh thần `posInt`/`unitDouble` hiện có — không bao giờ throw,
      luôn fail-safe về giá trị cũ).

## Ghi chú

Toàn bộ field mới phải OPTIONAL và fail-safe giống các field hiện có —
không được đổi behavior mặc định cho host nào chưa dùng field mới. Nên làm
SAU T132 (đã ghi rõ ở Dependency) vì auto-refresh định kỳ khuếch đại đúng
race condition T132 đang sửa — sửa T137 trước T132 sẽ tạo ra 1 tính năng
mới ngay lập tức lộ race cũ thường xuyên hơn.

## Kết quả (2026-09-06) — DONE

- **Status:** ✅ done. **Điểm cuối: 9.5/10** (2 vòng review độc lập `codex`,
  bản copy cô lập: 7/10 → 9.5/10).
- **Đã làm cả 3 phần:** kill-switch theo format (`AdSafetyParams
  .disabledFormats` + `canShowFullscreenAd/Peek(forType:)`, gate ở cả 4
  format fullscreen: appOpen/interstitial/rewarded/rewardedInterstitial),
  periodic auto-refresh (`initialize(..., remoteSafetyAutoRefreshInterval:)`
  → `Timer.periodic`), revision/rollback-protection
  (`AdPreferences.getRemoteSafetyRevision/setRemoteSafetyRevision` +
  `_applyRemoteOverridesWithRevisionGuard`).
- **Vòng 1 review bắt 2 bug thật:**
  1. **BLOCKING — TOCTOU race khi 2 refresh chồng lấp** (chính periodic
     timer làm chuyện này thành thường xuyên): guard cũ là `async`, có
     khoảng hở giữa check-revision và `AdSafetyConfig.updateParams()`, nên
     request cũ resolve SAU request mới vẫn có thể đè ngược state mới hơn.
     Đã sửa: guard giờ HOÀN TOÀN ĐỒNG BỘ (không `await` bên trong), dùng
     field in-memory `_lastAppliedRemoteSafetyRevision` làm compare-and-set
     atomic, gộp cả bước ghi `AdSafetyConfig.updateParams()` vào cùng bước
     đồng bộ đó (`applyToLiveConfig` param) — event loop 1 luồng của Dart
     đảm bảo không request nào chen được vào giữa.
  2. **IMPORTANT — timer sống sót qua đường init thất bại**: timer cũ start
     ngay đầu `initialize()`, trước khi biết init có thành công không, và
     không bị cancel ở các đường adapter fail/retry exhaust/superseded. Đã
     sửa bằng cách DỜI vị trí start timer tới đúng điểm "init đã thành
     công" duy nhất trong toàn file (ngay trước `onComplete(true, ...)`,
     chỉ có 1 chỗ gọi trong cả file) — mọi đường fail/abort đều return/vào
     catch trước dòng đó, nên không cần rải cancel vào từng path.
  3. **MINOR — thiếu test malformed revision**: đã thêm 4 case
     (String/double không nguyên/bool/null) verify cả live behavior lẫn
     không ghi persisted revision sai.
- **Bug tự bắt được TRƯỚC khi có review ngoài** (khi tự viết test theo TDD):
  guard ban đầu return `null` khi reject nhưng caller vẫn gọi
  `AdSafetyConfig.updateParams(local)` — `local` là baseline tính lại từ
  đầu, không phải state đang live, nên "reject" vô tình xóa sạch mọi
  override đã áp dụng trước đó thay vì thật sự "giữ nguyên". Sửa: đổi guard
  trả `null` = caller bỏ qua HOÀN TOÀN, không gọi `updateParams` gì cả.
- **Baseline:** `flutter analyze` sạch; `flutter test` 1680/1680 (12 test
  mới); integration test `t137_periodic_refresh_test.dart` pass thật trên
  Pixel 7 Pro (proof: 1 fetch lúc init + ≥2 tick tự động trong 5s với
  interval 2s + không còn fetch nào sau `destroy()`), re-verify lại sau khi
  dời vị trí start timer.
- 2 test-only seam mới: `AdManager.debugRemoteSafetyRefreshTimerActive`
  (getter) và `debugLastAppliedRemoteSafetyRevision` (setter), cả 2
  `@visibleForTesting`.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T137-remote-safety-provider-periodic-killswitch.md
này (nếu đã chuyển sang inprogress/ hoặc done/ thì đọc ở đó). Implement
ĐÚNG scope mô tả trong "Việc cần làm" — KHÔNG thêm scope ngoài mô tả.

Cần T132 xong trước khi bắt đầu — kiểm tra doc/task/done/T132-*.md tồn tại
chưa, nếu chưa thì dừng lại và báo user.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có (RemoteAdSafetyProvider), không tự dựng
server/API mới. Nếu ticket này có vẻ cần backend, dừng lại hỏi user trước
khi code.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate đã dùng ở round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp lại: sửa → audit adversarial (có thể dùng codex/agy độc lập trong bản
copy cô lập /tmp, rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R
nguyên khối tránh ENOSPC) → nếu điểm ≤9/10 thì sửa tiếp theo finding →
verify lại → lặp tới khi ≥9/10 mới push. KHÔNG tự ý push nếu chưa đạt
ngưỡng. Di chuyển file ticket này từ todo/ sang inprogress/ khi bắt đầu,
sang done/ khi xong.
```
