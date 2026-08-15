# T74 — `AdLoadingDialog`/`VipRedeemScreen` nên kế thừa `ThemeData` thay vì màu cứng

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart:245-288`

## Vấn đề (Why)
Nền tối mờ + chữ trắng cố định — tương phản mạnh nếu app dùng theme sáng.

## Đề xuất
Dùng `Theme.of(context).colorScheme` thay vì màu hardcode, giữ fallback hợp lý nếu app không set theme.

## Acceptance criteria
- [ ] Dialog render hợp lý ở cả light/dark `ThemeData` mẫu trong test.
