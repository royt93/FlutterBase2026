# T200 — Scoped SDK data-erasure API (NEW)
Priority P1 · Status todo · Source `lib/src/utils/ad_preferences.dart:578` và SDK-owned keys.

`clearAllData()` gọi prefs.clear(), có thể xoá dữ liệu host; SDK thiếu erase scoped. Khuyến nghị `clearSdkData(scope: analytics|diagnostics|allIncludingEntitlements)` với key registry/versioning, explicit confirmation cho entitlement. Expose clearAllData nguy hiểm; không API không đáp ứng privacy.

Tests: unit registry/idempotency/failure; widget confirmation; integration erase→reload; device smoke host keys còn nguyên, SDK keys biến mất.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; >9/10 commit+push.
