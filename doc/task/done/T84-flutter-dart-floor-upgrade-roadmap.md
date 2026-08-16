# T84 — Cần roadmap nâng cấp Flutter/Dart floor để mở khoá GMA 8/9 + 10 điểm pub.dev cuối, kèm kế hoạch v3.0.0

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** ✅ done (docs-only, roadmap)
- **Files:** `CLAUDE.md`, `packages/ad_sdk/pubspec.yaml`

## Vấn đề (Why)
Package bị khoá ở 150/160 điểm pub.dev do `google_mobile_ads: ^7.0.0` — GMA 8/9 đòi Dart `>=3.10.0` + Flutter `>=3.38.1`, trong khi CI ghim Flutter 3.35.1. Nâng floor sẽ là breaking change cho consumer (environment floor tăng), cần kế hoạch rõ ràng thay vì để treo vô thời hạn.

## Đề xuất
Lên kế hoạch: (1) mốc thời gian dự kiến bump CI floor, (2) đánh giá tác động breaking change cho app đang consume package, (3) lộ trình publish v3.0.0 kèm MIGRATION.md cập nhật.

## Acceptance criteria
- [x] Có tài liệu roadmap (có thể là chính ticket này cập nhật) ghi mốc thời gian + kế hoạch migration, không cần code ngay.

## Roadmap (2026-08-16)

### 1. Mốc thời gian bump CI floor

Không chốt ngày lịch cụ thể (đoán ngày cho 1 bản Flutter chưa ra là vô căn cứ) — chốt theo **điều kiện trigger**:

- Trigger khi Flutter stable channel đã lên **≥3.38.1** VÀ đã ở stable channel tối thiểu **4-6 tuần** (né các bug mới-ra-lò của 1 minor release, khớp cách CI hiện đang ghim 3.35.1 thay vì bám sát bản mới nhất).
- Trước khi trigger: định kỳ mỗi audit round (đã có thói quen numbered `doc/audit/`) kiểm tra `flutter --version` stable hiện tại — nếu đã qua ngưỡng trên, mở lại ticket này thành work item thật.

### 2. Đánh giá tác động breaking change

- **Với consumer app:** raise `environment: sdk` floor lên `>=3.10.0` + yêu cầu Flutter `>=3.38.1` → BREAKING với MỌI app đang ở Flutter thấp hơn — bắt buộc bump major (v3.0.0), không thể làm minor/patch.
- **Với CocoaPods wall (đã ghi trong CLAUDE.md):** `google_mobile_ads` 8/9 rất có thể đi kèm bump `GoogleMobileAdsMediationAppLovin`/`AppLovinSDK` version pin mới trong `gma_mediation_applovin` — cần re-verify TOÀN BỘ pinning-wall (không chỉ Dart floor) khi tới lúc, vì có thể ĐỔI (giải quyết hoặc dịch chuyển) xung đột `applovin_max 4.6.4` ↔ `gma_mediation_applovin 2.5.2` hiện tại. Không giả định trước — verify lại bằng `pod install` thật trên app tiêu thụ, đúng quy trình publish đã ghi trong CLAUDE.md.
- **Với chính package:** `flutter analyze`/`flutter test` CI cũng phải bump Flutter pin đồng thời — không thể bump `environment.sdk` của package mà giữ CI ở Flutter cũ hơn (compile fail ngay).

### 3. Lộ trình publish v3.0.0 (khi trigger ở mục 1 xảy ra)

1. Bump `flutter-version` trong `.github/workflows/test.yml` (cả 3 job: `sdk`, `sdk-integration`, `sdk-integration-ios`) lên bản stable mới.
2. Bump `google_mobile_ads` → `^9.x` (hoặc bản mới nhất tương thích tại thời điểm đó), `environment.sdk` → `>=3.10.0 <4.0.0`.
3. Chạy lại **toàn bộ** bước verify trong CLAUDE.md's "Publishing to pub.dev": `flutter pub get` + `cd ios && pod install` + `flutter build apk`/`flutter build ios --simulator` trên 1 app tiêu thụ thật — không chỉ trong CI.
4. `flutter test` full suite (699 test tại thời điểm audit gốc, ~750 tại thời điểm ticket này) phải xanh 100% trên Flutter/Dart mới — chạy 1 lần với FULL log để bắt regression do API Flutter đổi (không chỉ trust "compile được").
5. Cập nhật `MIGRATION.md` — thêm section mới `2.x → 3.0.0` theo đúng format các section cũ (bảng mục lục + no-breaking-changes / breaking-changes rõ ràng, kèm bước sửa `pubspec.yaml` environment của consumer app).
6. `CHANGELOG.md` — entry `[3.0.0]` đánh dấu `### Breaking` rõ ràng (floor Dart/Flutter mới), không gộp chung với các thay đổi non-breaking khác trong cùng version.
7. Publish qua `dart pub publish --dry-run` trước (nhớ 2 trap đã ghi trong CLAUDE.md: giới hạn 200/160 ký tự cho `screenshots`/`description`), rồi publish thật.

### Không làm ngay (đúng acceptance criteria — chỉ cần roadmap, chưa code)
- Chưa đụng `pubspec.yaml`/CI workflow trong ticket này.
- Việc re-verify CocoaPods wall thật sự chỉ có thể làm khi tới bước 3 ở trên (cần Flutter/GMA version mới thật để test, không thể giả lập trước).
