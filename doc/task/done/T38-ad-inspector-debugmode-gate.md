# T38 — Nút Ad Inspector (example app) chưa gate `kDebugMode`

- **REQ:** 7 (tuân thủ policy) — hygiene, không phải vi phạm policy trực tiếp
- **Priority:** P2 · **Severity:** LOW (rủi ro thấp vì hiện chỉ tồn tại ở example app) · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/example/lib/.../state_panel_demo_page.dart` (nút gọi `AppLovinMAX.showMediationDebugger()` / `MobileAds.instance.openAdInspector()`)

## Vấn đề (Why)
Nút inspector gọi thẳng công cụ debug native của AppLovin/AdMob, không có gate `kDebugMode`. Đúng convention repo ("demo tính năng mới nằm ở example app, không ở host app" — xem `doc/feature.md` entry 2026-07-13), rủi ro hiện tại thấp vì example app không lên store. Nhưng nếu pattern này bị copy sang host app (`lib/`) sau này, **bắt buộc phải gate** — ad inspector là công cụ QA nội bộ, không nên lộ cho end-user trên bản release (một số network coi việc lộ debug tool trong production là vi phạm nhẹ chính sách).

## Giải pháp đề xuất
- Thêm `if (kDebugMode)` bao quanh nút/hành động trong example app cho nhất quán (phòng ngừa, dù rủi ro thấp).
- Ghi chú rõ trong code/README: nếu copy pattern này sang host app, gate là bắt buộc chứ không phải tuỳ chọn.

## Acceptance criteria
- [x] Nút inspector trong example app chỉ hiển thị/hoạt động khi `kDebugMode == true`.
- [x] Có comment/README note cảnh báo bắt buộc gate nếu đưa lên host app.

## Kết quả
Bọc nút trong `example/lib/main.dart:1797` bằng `if (kDebugMode) ...[...]` (Dart collection-if, không thêm widget wrapper). `flutter analyze` sạch. Verify trực quan: build+run Debug trên iOS Simulator (iPhone 17 Pro Max) xác nhận nút "Open AppLovin mediation debugger" hiển thị đúng trong debug mode (positive-path check).

## Giới hạn đã biết
Release/Profile build **không hỗ trợ chạy trên iOS Simulator** (giới hạn Flutter tooling: `flutter build ios --release/--profile --simulator` báo lỗi thẳng), và không có iOS device vật lý nào sẵn sàng kết nối tại thời điểm verify — nên chỉ xác nhận được nhánh "hiển thị khi debug" (positive path), chưa xác nhận trực tiếp bằng chạy thực tế "ẩn khi release" trên simulator hay device thật. Việc ẩn ở release dựa vào đúng ngữ nghĩa `kDebugMode` của Flutter (hằng số biên dịch, `false` trong mọi release build) — an toàn về mặt logic nhưng chưa có xác nhận runtime trên build release thật.
