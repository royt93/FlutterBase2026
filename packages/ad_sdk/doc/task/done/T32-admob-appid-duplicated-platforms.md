# T32 — AdMob Application ID giống hệt nhau giữa Android và iOS

- **REQ:** 1 (provider AdMob/AppLovin, Android + iOS)
- **Priority:** P1 · **Severity:** MEDIUM (thấp *hiện tại* vì AdMob đang dormant) · **Status:** ✅ done — xử lý như feature/quyết định có chủ đích (2026-07-14, chốt qua `AskUserQuestion`)
- **Files:** `android/app/src/main/AndroidManifest.xml` (`com.google.android.gms.ads.APPLICATION_ID`), `ios/Runner/Info.plist` (`GADApplicationIdentifier`), `lib/mckimquyen/common/const/ad_keys.dart` (comment), `doc/AD_PROMPT_FLUTTER.MD` (Phụ lục C)

## Vấn đề (Why)
Cả 2 file đang dùng **cùng 1 giá trị** `ca-app-pub-3612191981543807~9731053733`. AdMob console cấp App ID **riêng biệt** cho mỗi platform app entry (Android app và iOS app là 2 entry khác nhau trên console, dù cùng 1 project) — đây là bug native config thật, dù rủi ro thực tế thấp vì runtime provider đang cố định `AdProvider.appLovin` (AdMob dormant).

## Giải pháp đã chọn (quyết định của user, không phải AI tự quyết)
Người dùng (non-tech) chốt qua `AskUserQuestion`: **không** tự tra cứu/đoán App ID production thật (rủi ro cắm nhầm account), mà đổi tạm sang **test App ID chính thức của Google** — khác nhau đúng theo platform, giống hệt cách `packages/ad_sdk/example` đã làm ở T41:
- Android: `ca-app-pub-3940256099942544~3347511713`
- iOS: `ca-app-pub-3940256099942544~1458002511`

Mỗi vị trí đều có comment giải thích đây là quyết định tạm thời có chủ đích (không phải bug sót), kèm checklist việc cần làm trước khi bật AdMob thật — xem `doc/AD_PROMPT_FLUTTER.MD`'s "Phụ lục C".

## Acceptance criteria
- [x] `AndroidManifest.xml` và `Info.plist` có 2 giá trị App ID **khác nhau** (test ID chính thức của Google, đúng theo platform).
- [x] Ghi chú checklist rõ ràng trong `doc/AD_PROMPT_FLUTTER.MD` (Phụ lục C) + `doc/feature.md`: việc cần làm trước khi lấy App ID production thật từ AdMob console.

## Verify
`flutter analyze` (root) → no issues. `grep -rn "3612191981543807~9731053733" android/ ios/ lib/` → chỉ còn trong comment lịch sử (đã cập nhật nội dung), không còn giá trị nào được dùng thật.
