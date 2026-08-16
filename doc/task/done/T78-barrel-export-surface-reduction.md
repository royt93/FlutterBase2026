# T78 — Thu hẹp barrel export, giảm lộ low-level/testing surface

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/applovin_admob_sdk.dart`

## Vấn đề (Why)
Barrel export hiện lộ adapter, event bus, slot/backoff/log — nhiều phần chỉ nên dùng nội bộ/test, không phải public API ổn định cho consumer.

## Đề xuất
Rà soát từng export, giữ lại đúng public API cần thiết, ẩn phần internal (có thể qua `src/` không export hoặc đánh dấu `@internal`).

## Acceptance criteria
- [x] Danh sách export mới không còn class/hàm chỉ dùng cho test nội bộ.
- [x] `flutter analyze` sạch, example app vẫn build được với export mới.

## Đã làm (2026-08-16) — phạm vi thu hẹp nhiều sau khi verify thật

Rà từng export bị audit nêu tên, xác nhận PHẦN LỚN thực ra là public API cần thiết thật, không phải rò rỉ internal:
- **`AdSlot`/`AdSlotType`/`AdSlotState`** — GIỮ. Đây là return type của `AdProviderAdapter.appOpenSlot`/`interstitialSlot`/`rewardedSlot` — bất kỳ ai implement custom adapter (interface public) đều cần type này. Không xoá được.
- **`SimpleEventBus`/`BoolEvent`** — GIỮ. Đây là 1 phần bắt buộc của integration contract đã document rõ trong README (`§`Subscribe BEFORE calling initialize()`) — `example/lib/main.dart` splash screen thật cũng dùng trực tiếp.
- **`AdScreen`/`AdScreenState`/`AdScreenRouteLogger`/`adRouteObserver`** — GIỮ, base class + observer bắt buộc theo integration contract.
- **`IntegrationSelfCheck`/`SelfCheckItem`/`SelfCheckStatus`** — GIỮ, tính năng debug tool đã document (`AdManager.runIntegrationSelfCheck()`), không phải test-only.

**Chỉ 1 export thật sự internal-only sau khi verify:** `Backoff` (`src/state/backoff.dart`) — chỉ là chi tiết tính cooldown nội bộ của `AdSlot.beginLoad()`'s default param, không public API nào tham chiếu, chỉ 1 file test (`ad_slot_test.dart`) dùng qua barrel. Đã xoá khỏi barrel, sửa test import thẳng `src/state/backoff.dart` (test nội bộ được phép reach vào `src/`).

Thêm CHANGELOG entry `[Unreleased]` ghi rõ đây là breaking change (dù rủi ro thấp — không ai bên ngoài chắc dùng `Backoff` trực tiếp).

`flutter test`: 748/748 pass, `flutter analyze` sạch (cả package + example).
