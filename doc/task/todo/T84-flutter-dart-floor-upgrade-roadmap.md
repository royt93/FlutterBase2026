# T84 — Cần roadmap nâng cấp Flutter/Dart floor để mở khoá GMA 8/9 + 10 điểm pub.dev cuối, kèm kế hoạch v3.0.0

- **REQ:** audit round mới 2026-08-15 (agy + codex)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `CLAUDE.md`, `packages/ad_sdk/pubspec.yaml`

## Vấn đề (Why)
Package bị khoá ở 150/160 điểm pub.dev do `google_mobile_ads: ^7.0.0` — GMA 8/9 đòi Dart `>=3.10.0` + Flutter `>=3.38.1`, trong khi CI ghim Flutter 3.35.1. Nâng floor sẽ là breaking change cho consumer (environment floor tăng), cần kế hoạch rõ ràng thay vì để treo vô thời hạn.

## Đề xuất
Lên kế hoạch: (1) mốc thời gian dự kiến bump CI floor, (2) đánh giá tác động breaking change cho app đang consume package, (3) lộ trình publish v3.0.0 kèm MIGRATION.md cập nhật.

## Acceptance criteria
- [ ] Có tài liệu roadmap (có thể là chính ticket này cập nhật) ghi mốc thời gian + kế hoạch migration, không cần code ngay.
