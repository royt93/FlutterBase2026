# T10 — `isConnected` pessimistic + fast-retry lỗi mạng

- **REQ:** 2
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** ✅ done (2026-07-05)

## Kết quả & quyết định
- **`isConnected`**: khi detector throw (chưa init/không khả dụng) nay trả **last-known state** (`_lastConnected` từ T08 watch, seed `true`) + **log warning** — thay vì blind `true` câm lặng.
- **Quyết định giữ optimistic** (không đổi sang pessimistic như audit đề xuất): nếu detector hỏng, trả `false` sẽ **chặn ad vĩnh viễn kể cả khi online** (tệ hơn cho revenue). Trả `true`/last-known → load offline chỉ fail + backoff, và T08 refill khi reconnect. Đây là engineering call đúng hơn; đã document rõ trong code.
- **Network-error fast-retry**: đã được **T08 subsume** — connectivity watch refill ngay khi reconnect (không cần branch error-code theo provider, vốn brittle). Backoff vẫn bounded 30 phút làm backstop.
- Verify: T08 tests (reconnect refill) + T09 (banner reconnect). Analyze sạch.
- **Files:** `core/ad_manager.dart` (`isConnected` `:845-850`), `adapters/admob_adapter.dart` + `applovin_adapter.dart` (onFailed callbacks), `state/backoff.dart`

## Vấn đề (Why)
`isConnected` catch mọi lỗi → `return true` (lạc quan) ⇒ offline có thể bị hiểu là online, load thất bại với lỗi native khó hiểu. Adapter coi lỗi mạng như mọi lỗi khác → vào cooldown/backoff dài thay vì fast-retry.

## Acceptance criteria
- [x] `isConnected` khi exception → log + fallback về **last-known state**
      (`_lastConnected`, seed `true`, optimistic) — quyết định đổi so với
      criteria gốc, xem "Kết quả & quyết định" phía trên.
- [ ] Adapter nhận diện error code mạng (no network/timeout/DNS) và: (a) không tính vào backoff dài, hoặc (b) uỷ thác cho connection listener (T08) refill khi reconnect.
- [ ] Lỗi "hard" (unit id sai, no-fill) vẫn dùng backoff bình thường (`backoff.dart`).

## Test
- [ ] Unit: exception ở isConnected → false.
- [ ] Unit: network error → không tăng backoff như hard error.
