# T132 — Fix: Stale-session race trong refreshRemoteSafetyParams()

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
  Xem `doc/audit/audit_round41.md` cho context audit liên quan.
- **Priority:** P2
- **Status:** 🔲 todo
- **Effort:** M
- **Files (dự kiến):** `packages/ad_sdk/lib/src/core/ad_manager.dart`
  (method `refreshRemoteSafetyParams()`, dòng ~3795-3837)
- **Nguồn gợi ý:** codex, tự verify lại đúng bằng Read trực tiếp
- **Dependency:** (không có)

## Vấn đề

`ad_manager.dart:3796-3830` — `refreshRemoteSafetyParams()`:

```dart
Future<void> refreshRemoteSafetyParams() async {
  final provider = _remoteSafetyProvider;
  final cfg = _config;                    // (1) chụp cfg TRƯỚC await
  if (provider == null || cfg == null) return;

  Map<String, dynamic>? overrides;
  try {
    overrides = await provider
        .fetchSafetyParamOverrides()
        .timeout(const Duration(seconds: 5));   // (2) await tối đa 5s
  } catch (e) { ... return; }
  if (overrides == null) return;

  if (_config == null) {                  // (3) chỉ check "đã destroy() chưa"
    ...
    return;
  }

  final prefs = await AdPreferences.getInstance();
  final merged = applyRemoteSafetyOverrides(
      _rampAdjustedSafety(cfg, prefs), overrides);   // (4) dùng `cfg` CŨ
  AdSafetyConfig.updateParams(merged, isRelease: kReleaseMode);  // (5) ghi GLOBAL
  ...
}
```

Guard ở (3) chỉ hỏi "SDK đã bị `destroy()` chưa", KHÔNG hỏi "`_config` hiện
tại có còn CÙNG INSTANCE với `cfg` đã chụp ở (1) không". Nếu trong lúc await
ở (2) (tối đa 5s) có 1 chu kỳ `destroy()` rồi `initialize()` MỚI chạy xong
(ví dụ do `RemoteSafetyDemoPage`/host app gọi lại, hoặc `_retryRefillAds`),
`_config` ở (3) khác `null` (là config của session MỚI) nên guard pass, nhưng
`cfg` ở (4) vẫn là instance CŨ (biến local, không tự cập nhật theo session
mới) — `applyRemoteSafetyOverrides` dùng baseline SAI, rồi (5) ghi kết quả
vào `AdSafetyConfig.updateParams` — đây là **static, global, dùng chung mọi
session** — tức đè state sai (từ session cũ) lên session MỚI đang chạy.

Class `AdManager` đã có sẵn cơ chế generation-token đúng để giải quyết chính
xác loại race này: `_initGen` (field, dòng 1247), bump ở mỗi `initialize()`
(dòng 2381: `final initGen = ++_initGen;`) và mỗi `destroy()` (dòng 5413:
`_initGen++;`), cùng helper `_initSuperseded(int initGen) => _initGen !=
initGen;` (dòng 3498) đã dùng ở nhiều chỗ khác trong đúng file này để phát
hiện chính xác "phiên đã bị thay thế chưa" — nhưng `refreshRemoteSafetyParams`
KHÔNG dùng cơ chế này, chỉ check `_config == null` (thiếu, không đủ).

## Việc cần làm

- [ ] Ngay sau khi chụp `cfg = _config`, chụp thêm generation hiện tại:
      `final myGen = _initGen;`
- [ ] Sau `await fetchSafetyParamOverrides()`, thay/thêm điều kiện discard:
      dùng `_initSuperseded(myGen)` (hoặc tương đương `_initGen != myGen`)
      thay vì (hoặc cùng với) `_config == null` — nếu superseded, log cảnh
      báo tương tự dòng hiện có ("destroyed mid-fetch") nhưng đổi message
      cho đúng ý nghĩa mới ("session superseded mid-fetch"), rồi `return`
      sớm, không merge/ghi `AdSafetyConfig`.
- [ ] Giữ nguyên toàn bộ semantics fail-open khác (timeout/exception vẫn
      giữ nguyên params hiện tại, không đổi).
- [ ] Không cần backend/remote gì thêm — đây thuần là race-condition fix
      nội bộ, không liên quan tới `RemoteAdSafetyProvider`'s nguồn dữ liệu.

## Ghi chú

Effort M vì cần đọc kỹ toàn bộ vòng đời `_initGen`/`_initSuperseded` trong
file (dùng ở nhiều chỗ khác — `initialize()`, `_retryRefillAds`, v.v.) để
đảm bảo thêm 1 chỗ dùng nữa không phá vỡ giả định nào sẵn có, và để viết
test mô phỏng đúng race (destroy()+initialize() xen giữa lúc
`fetchSafetyParamOverrides()` đang await) — cần 1 `RemoteAdSafetyProvider`
giả lập delay được điều khiển bằng tay (`Completer`) trong test.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T132-fix-stale-session-race-refresh-remote-safety-params.md này (nếu đã chuyển sang inprogress/
hoặc done thì đọc ở đó). Implement ĐÚNG scope mô tả trong "Việc cần làm" —
KHÔNG thêm scope ngoài mô tả.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có (kiểu RemoteAdSafetyProvider), không tự
dựng server/API mới. Nếu ticket này có vẻ cần backend, dừng lại hỏi user
trước khi code.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate đã dùng ở round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp lại: sửa → audit adversarial (có thể dùng codex/agy độc lập trong bản
copy cô lập /tmp, KHÔNG cp -R nguyên khối tránh ENOSPC, dùng rsync loại trừ
build/.dart_tool/Pods/.gradle) → nếu điểm ≤9/10 thì sửa tiếp theo finding →
verify lại → lặp tới khi ≥9/10 mới push. KHÔNG tự ý push nếu chưa đạt
ngưỡng. Di chuyển file ticket này từ todo/ sang inprogress/ khi bắt đầu,
sang done/ khi xong.
```
