# T224 — Cải tiến thu hồi bộ nhớ chủ động khi OS phát tín hiệu Memory Pressure

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done — REFUTED (already covered); chỉ bổ sung 4 pinning test

## Vấn đề (Why) — theo ticket gốc

`AdManager().didHaveMemoryPressure()` chỉ ghi log mà chưa giải phóng tài nguyên.
Ticket đề xuất khi có memory pressure: flush/nén `AdEventLog` và
`BypassAuditTrail`, giải phóng slot fullscreen preloaded quá 15 phút chưa dùng,
dọn tombstone cũ trong `InlineAdInstanceRegistry`.

## Kết luận điều tra: ticket SAI — mọi cơ chế đã tồn tại

`didHaveMemoryPressure()` (`lib/src/core/ad_manager.dart:9062`) chỉ log là
**chủ ý thiết kế**, không phải thiếu sót. Doc comment ngay tại đó
(`ad_manager.dart:9045-9055`) giải thích: drop native ad object ở đây mà không
kèm `adapter.dispose()` phối hợp sẽ leak — slot state báo "idle" nhưng native
`InterstitialAd`/`RewardedAd` vẫn còn trong bộ nhớ, và lần `load` kế tiếp
early-return vì cached pointer vẫn non-null.

| Đề xuất của ticket | Thực tế trong code (file:line) | Verdict |
|---|---|---|
| Flush buffer `AdEventLog` | `lib/src/compliance/ad_event_log.dart:20,119-121` — hard cap 5000 entries, oldest drop đầu tiên trên mọi `_append()`; persist debounce 1s (`:40-41`), `flush()` đã gọi ở pause/destroy (`ad_manager.dart:8925,7027`) | Bounded sẵn, không có gì unbounded để flush thêm |
| Flush buffer `BypassAuditTrail` | `lib/src/compliance/bypass_audit_trail.dart:76,96,191` — ring buffer 200 entries, `removeAt(0)` trên mọi `record()`; `flush()` ở pause (`ad_manager.dart:8855`) | Bounded sẵn, như trên |
| Evict slot fullscreen quá 15 phút | `lib/src/adapters/admob_adapter.dart:788,793-804` — `isAdFresh` 1h/4h; slot cũ bị từ chối ngay trên path `show()` (`:1259-1266`) và `load()` (`:1189-1196`); AppLovin: MAX tự giữ cache native, Dart không có handle để evict (`lib/src/adapters/applovin_adapter.dart:932-937`), `discardCachedFullscreenAds` (`:928-954`) chỉ reset slot | Timer 15 phút riêng là dư thừa; trên AppLovin còn bất khả thi |
| Dọn tombstone cũ trong registry | `InlineAdInstanceRegistry` **không hề có tombstone set** (`lib/src/adapters/inline_ad_instance_registry.dart:106-111` — dùng slot-identity check thay vì tombstone vĩnh viễn, đúng thiết kế); tombstone duy nhất nằm ở AppLovin native, đã bounded 200 entries drop-oldest-first (`lib/src/adapters/applovin_adapter.dart:511-513,558-562`), comment T114 (`:492-510`) giải thích xóa sớm gây leak late-callback | Không tồn tại "tombstone cũ chưa dọn"; xóa sớm hơn còn gây hại |

Nói ngắn: cả 3 đề xuất đều nhắm vào vấn đề không tồn tại, và 2 trong 3 nếu
làm theo còn gây hại (leak native pointer / late-callback leak). Không thêm
code sản phẩm — làm vậy sẽ là abstraction thừa và regression risk.

## Test đã thêm (pinning, không phải fix)

`test/ad_manager_core_test.dart`, group `didHaveMemoryPressure()` — 4 test mới
chốt hành vi hiện tại để chống regression nếu ai đó "sửa" theo ticket sau này:

1. `AdEventLog` tự cap (dùng `maxEntries: 3` để chứng minh cơ chế trim, mặc định
   production là 5000) — oldest drop đầu tiên, không cần memory pressure can thiệp.
2. `BypassAuditTrail` ring buffer tự cap (dùng `maxEntries: 2`, mặc định 200).
3. Slot fullscreen cũ đã bị `isAdFresh` từ chối trên path `show()` — không cần
   timer evict 15 phút riêng.
4. 50 lần gọi `didHaveMemoryPressure()` liên tiếp: không throw, slot untouched,
   throttle 60s giữ nguyên.

3 test `didHaveMemoryPressure()` có sẵn (null-adapter no-op, log-only, throttle)
vẫn pass nguyên.

## Acceptance Criteria

- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi (không đổi code sản phẩm — cơ chế đã có).
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Kiểm thử: 4 unit test pinning mới; widget test N/A (không có hành vi observable qua UI thay đổi); integration test N/A (không có hành vi on-device nào vượt ngoài no-op đã chứng minh bằng unit).
- [x] `flutter analyze` sạch 0 cảnh báo; `flutter test` toàn bộ pass xanh (xem số liệu trong commit message).
- [x] Device smoke: N/A — không sửa production code. `adb devices` chỉ thấy TECNO KJ7 (`115333744A005844`), không có S24 Ultra; không có gì mới để smoke.
