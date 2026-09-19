Audit round 28 verdict tổng hợp

**Ngày:** 2026-09-01
**Commit audit:** `d3da1bc` (2.9.6, đã publish lên pub.dev, khớp HEAD)
**Bối cảnh:** audit lại từ đầu theo 7 yêu cầu sản phẩm gốc (như round 26/27), lần này có thêm kiểm tra đồng bộ pub.dev. Không có thay đổi `lib/` nào kể từ round 27 (2 commit sau đó chỉ là docs + integration-test fix) — mục tiêu round này là tìm góc mù mà 3 round audit trước bỏ sót, không phải re-verify round 27.
**Reviewer:** 3 CLI độc lập chạy song song, không thấy báo cáo của nhau: `codex exec --yolo`, `agy --dangerously-skip-permissions` (Gemini 3.7 Flash), `claude --dangerously-skip-permissions` (phiên fresh, khác phiên orchestrator này). Mỗi bên tự đọc `audit_round27_consolidated.md` làm baseline rồi tự audit source hiện tại. Báo cáo gốc: `audit_codex_round28.md`, `audit_agy_round28.md`, `audit_claude_round28.md`.
**Verify độc lập của phiên orchestrator (session hiện tại, không phải 1 trong 3 reviewer):** tự chạy `flutter analyze` (0 issues) + `flutter test` (1482/1482 pass) trên HEAD thật; tự đọc `_redeemed_key_ledger.dart` và `admob_adapter.dart` xác nhận 2 fix MAJOR round 27 đúng như khai; tự đọc `ad_route_observer.dart` để verify finding mới bên dưới trước khi đưa vào báo cáo.

---

## 1. Đồng thuận cả 3 reviewer: không có BLOCKER/MAJOR regression mới trong 2 commit sau round 27

Cả 3 xác nhận độc lập: kiến trúc round 26/27 còn nguyên vẹn — consent gate fail-closed, fullscreen mutex 8 điều kiện (`AdManager._fullscreenBusyReason`), VIP ledger write-chain, AdMob `onFailed` disposal guard, Ed25519 verify offline, anti-clock-rollback. `flutter analyze` sạch, test suite 1482/1482 (agy đo thêm example package 28/28 và integration test Android).

Điểm số: codex 8.2/10, agy 9.5/10, claude 8/10 — trung bình ~8.6/10.

## 2. BLOCKER cũ vẫn treo — không đổi

AppLovin SDK key + 8 ad-unit ID từng lộ trong git history (round 26). Cả 3 reviewer nhắc lại: **không thể xác nhận rotation/revoke từ source review** — đây là hành động ngoài code (AppLovin dashboard), risk-accepted theo quyết định user ở round 26-27, không phải finding mới. Repo vẫn phải giữ private tới khi rotation xác nhận thủ công.

## 3. Finding MỚI duy nhất — chỉ 1/3 reviewer (`claude` fresh) bắt được, đã tự verify lại

**MAJOR — App Open có thể stack đè lên `showModalBottomSheet` trong app dùng nested Navigator (bottom-nav IndexedStack, hoặc `go_router` `ShellRoute`).**

- Root cause: `showDialog()` mặc định `useRootNavigator: true`, nhưng `showModalBottomSheet()` mặc định `useRootNavigator: false` — đây là khác biệt thật trong Flutter SDK, không phải giả định (`useRootNavigator` doc trong `flutter/lib/src/material/bottom_sheet.dart` vs `dialog.dart`).
- `AdScreenRouteLogger` (`lib/src/core/ad_route_observer.dart:23-95`) là `NavigatorObserver` đếm `PopupRoute` push/pop để set `isDialogOnTop`. Nó chỉ nhận callback từ Navigator nó được đăng ký vào (`navigatorObservers`, theo README là root `MaterialApp`/`Navigator`).
- Nếu consuming app có nested Navigator (mỗi tab 1 Navigator riêng, hoặc `ShellRoute` branch Navigator của `go_router`) và gọi `showModalBottomSheet(context: ...)` **không truyền `useRootNavigator: true`**, bottom sheet push vào Navigator con — `AdScreenRouteLogger` không thấy route đó, `isDialogOnTop` vẫn `false`. `showAppOpenAdOnResume` khi đó không bị chặn, App Open ad có thể hiện đè lên bottom sheet đang mở → vi phạm chính chỗ mục 7 của integration contract ("App Open never stacks on top of a modal") và rủi ro chính sách AdMob/AppLovin (ad che nội dung/điều khiển).
- Verify: đã tự đọc `ad_route_observer.dart` xác nhận cơ chế đếm `PopupRoute` chỉ hoạt động trong phạm vi Navigator được gắn observer — kết luận đúng, không phải suy đoán sai của reviewer.
- Không kích hoạt nếu: app chỉ dùng 1 Navigator gốc (không nested), hoặc luôn truyền `useRootNavigator: true` cho mọi `showModalBottomSheet`. `codex` và `agy` đều bỏ sót vì cả hai chỉ audit `showDialog`/`AdLoadingDialog` (dùng `useRootNavigator: true` đúng) mà không xét riêng `showModalBottomSheet` như 1 API riêng có default khác.

**2 MINOR mới, không ảnh hưởng verdict:**
- `claude` ghi nhận 1 subscription leak chỉ xảy ra ở debug-only code path (không chạy ở production build).
- Ed25519 sig-length invalid có thể ném `StateError` không bắt ở 1 nhánh hiếm — vẫn fail-safe (không grant VIP sai), chỉ crash thay vì reject êm.

## 4. Đối chiếu 7 yêu cầu sản phẩm

| # | Yêu cầu | Kết quả round 28 |
|---|---|---|
| 1 | AdMob+AppLovin, Android+iOS | ✅ PASS |
| 2 | Có mạng / không mạng | ✅ PASS — VIP redeem yêu cầu network là **chủ ý** (xem `vip_manager.dart:63-68`, đã biết trong memory dự án, không phải bug), ad load/hiển thị hoạt động offline-degraded đúng thiết kế |
| 3 | 7 loại ad, lifecycle, no-leak, pháp lý | ⚠️ PASS-with-caveat — **MAJOR mới mục 3** (App Open/bottom sheet nested-navigator) |
| 4 | Trial 1 ngày | ✅ PASS — codex lưu ý: Android không chống được "Clear data"/reinstall khi Auto Backup không bật/không restore — đã là caveat biết trước (README), không phải thiếu sót mới |
| 5 | VIP by-code, không backend | ✅ PASS — Ed25519 offline verify, ledger write-chain hết race |
| 6 | Consent mọi quốc gia | ✅ PASS — không gì mới chạm consent |
| 7 | Policy compliance | ⚠️ PASS-with-caveat — BLOCKER key-rotation cũ (risk-accepted) + MAJOR mới mục 3 (ad-che-modal risk) |

## 5. pub.dev đồng bộ

`2.9.6` đã publish (agy xác nhận `Published: 2026-09-01T12:49:57Z` qua pub.dev API), `pubspec.yaml`/README/CHANGELOG khớp 100% với HEAD. `codex` lưu ý HTML view cache cũ từng hiển thị `2.9.4` — CDN edge cache trễ, đã biết trong CLAUDE.md ("expect `flutter pub get` to keep reporting doesn't match any versions for a minute or two"), không phải vấn đề thật.

## 6. Verdict cuối round 28

**Sẵn sàng production trong app thực tế: YES WITH CONDITIONS.**
**Điểm hợp nhất: 8.5/10** (trung bình có trọng số, hạ nhẹ so với agy do 1 MAJOR mới xác nhận thật).

Điều kiện trước khi rollout thực:
1. Xác nhận thủ công đã rotate/revoke AppLovin SDK key + 8 ad-unit ID cũ trên dashboard (BLOCKER cũ, không thể verify từ code).
2. Nếu consuming app dùng nested Navigator (bottom-nav, `go_router` `ShellRoute`): audit mọi lời gọi `showModalBottomSheet` trong app đó, ép `useRootNavigator: true`, hoặc SDK cần patch `AdScreenRouteLogger`/docs để cảnh báo rõ (xem mục 3 — quyết định fix ngay hay defer để hỏi user riêng).
3. Giữ repo private tới khi mục 1 xác nhận xong.

Không phát hiện gì đủ nghiêm trọng để đổi verdict thành NO — kiến trúc cốt lõi (consent/VIP/lifecycle/mutex) vẫn vững sau 28 round audit.
