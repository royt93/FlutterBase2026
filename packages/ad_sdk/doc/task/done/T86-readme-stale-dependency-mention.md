# T86 — README nhắc dependency stale (`google_mobile_ads` 6.x trong khi pubspec dùng `^7.0.0`)

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/README.md:222,664`, `packages/ad_sdk/pubspec.yaml:58`

## Vấn đề (Why)
README vẫn nhắc `google_mobile_ads 6.x` trong khi package dùng `^7.0.0`. Cùng nhóm debt với T61 (default UMP sai) — docs pub.dev có thể dẫn dev debug nhầm version behavior.

## Đề xuất
Rà soát toàn README, đồng bộ version mention với `pubspec.yaml` hiện tại.

## Acceptance criteria
- [x] README không còn version mention lệch với pubspec.

## Đã làm (2026-08-16)
Grep toàn `README.md` đối chiếu `pubspec.yaml` (`google_mobile_ads`/`applovin_max`/`flutter_secure_storage`) — chỉ 1 chỗ thật sự lệch (dòng 222, nhắc "6.x" trong khi pubspec đã `^7.0.0` từ lâu, ghi nhận đúng ở dòng 202 cùng file). Sửa lại câu để nêu rõ hành vi đúng ở CẢ 6.x lẫn 7.x hiện tại (UMP API built-in không đổi giữa 2 bản), thay vì chỉ đổi số suông. Các dòng 43/97/143/202/281 khác nhắc `google_mobile_ads` không kèm số version cụ thể hoặc đã đúng — không cần sửa. `example/README.md` cũng không có version lệch.
