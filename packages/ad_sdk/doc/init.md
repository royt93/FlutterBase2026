> ⚠️ **STALE / WRONG REPO SCOPE (checked 2026-08-19).** These are UI/state
> conventions (GetX, `UIUtils.showToast`) for the old WiFi Stressor host app.
> That app no longer lives in this repo — per `CLAUDE.md` it now lives in its
> own separate repo — and `packages/ad_sdk` has no GetX dependency at all
> (verified: no `get`/`GetX` entries in `pubspec.yaml`). Not applicable to
> `applovin_admob_sdk`; kept only as historical reference.

## 🔥 High Priority Features

không dùng Get.snack hoặc raw ScaffoldMessenger.showSnackBar, hãy dùng UIUtils.showToast
không dùng setState, late, force null, hãy dùng GetX
các ô text input liên quan đến nhập số tiền phải có currency format, tham khảo các screen khác để biết format
phải có animation đồng bộ với các screen khác
lưu ý rằng code không memory leak, không bug
