# T129 — Flagship: Monetization Digital Twin

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done, RESCOPED (2026-08-31)
- **Files:** `lib/src/monetization/digital_twin.dart` (mới), `lib/src/core/ad_manager.dart` (`buildMonetizationDigitalTwin()`), `test/digital_twin_test.dart`

## Vấn đề

Mô phỏng trước tác động của cap, retry, provider split, VIP duration và preload policy từ event history local, trả dự báo dạng khoảng-tin-cậy về impression/revenue/blocked-request/UX cost, không phát ad thử. [đồng thuận 3 nguồn, effort XL]

## Rescope có chủ ý — đọc trước khi mở lại ticket này

Bản đầy đủ (5 trục: cap/retry/provider-split/VIP-duration/preload) đòi hỏi viết lại TOÀN BỘ logic quyết định có state của `AdSafetyConfig` (daily/hourly/session cap, per-placement cap, click-spam, CTR, network-fatigue T126, dry-run...) thành 1 bản THUẦN, replay được — 1 bản sao trùng lặp của code đã qua 27 vòng audit, không có contract-test nào đảm bảo 2 bản không lệch nhau theo thời gian. Đây là rủi ro XL thật, không phải phóng đại.

**Đã ship v0: CHỈ 1 trục — `maxFullscreenAdsPerDay`** — trục DUY NHẤT đã có đủ dữ liệu log sẵn (`AdShowEvent` + `AdSkipEvent(reason: 'daily_cap')`) để replay thuần từ `AdEventLog`, không cần event mới, không đụng state `AdSafetyConfig` sống. 4 trục còn lại (retry/provider-split/VIP-duration/preload) để dành làm ticket riêng, cùng hình dạng, mỗi lần 1 trục — nếu v0 này chứng minh hữu ích.

## Việc cần làm

- [x] Deterministic replay trên `AdEventLog.entries` đã có (không phải ring buffer mới) — nhóm theo ngày, đếm `shown`/`blockedByDailyCap`/`revenueMicros`.
- [x] "Shadow decision mode": `MonetizationDigitalTwin`/`forecastDailyCap()` là pure function, đọc-only, không phát request nào, không đổi state `AdSafetyConfig` sống — kết quả chỉ là số trả về cho host tự quyết định có áp dụng hay không.
- [x] Không phát thêm ad request chỉ để đo lường — 100% từ lịch sử đã ghi sẵn.
- [x] Test (`test/digital_twin_test.dart`, 5 case): replay chuỗi event với 2 giá trị cap khác nhau (tăng cap → dự báo tăng đúng hướng dùng average revenue-per-show của chính ngày đó; hạ cap → dự báo giảm đúng hướng) — **1 bug thật bị bắt ngay ở lần chạy đầu** (hạ cap dưới mức đã shown không làm giảm revenue dự báo, do công thức cộng-dồn sai chiều), sửa bằng công thức đối xứng `wouldShow * avgRevenuePerShow` thay vì `actual + delta`.

## Ghi chú

Làm sớm, ĐỘC LẬP với T127 (FLAGSHIP self-healing) theo quyết định user — dù BACKLOG doc gốc đề xuất nên làm sau để tránh trùng lặp. Nếu cả 2 chạy song song, cân nhắc thống nhất sớm cấu trúc dữ liệu rolling-metrics dùng chung.
