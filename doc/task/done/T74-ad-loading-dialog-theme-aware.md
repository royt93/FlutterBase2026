# T74 — `AdLoadingDialog`/`VipRedeemScreen` nên kế thừa `ThemeData` thay vì màu cứng

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart:245-288`

## Vấn đề (Why)
Nền tối mờ + chữ trắng cố định — tương phản mạnh nếu app dùng theme sáng.

## Đề xuất
Dùng `Theme.of(context).colorScheme` thay vì màu hardcode, giữ fallback hợp lý nếu app không set theme.

## Acceptance criteria
- [x] Dialog render hợp lý ở cả light/dark `ThemeData` mẫu trong test.

## Đã làm (2026-08-16)
Dialog là 1 "glass bubble" nổi trên bất cứ thứ gì đằng sau nó (thường là splash/ad, không phải screen của host) — nên KHÔNG kế thừa `colorScheme.surface`/`onSurface` trực tiếp (sẽ phá vỡ ý đồ "overlay nổi" gốc), mà tự tint dựa trên `Theme.of(context).brightness`: dark theme → glass trắng (giữ nguyên hành vi cũ), light theme → glass đen (tương phản tốt hơn trên nền sáng thường gặp). Cùng 1 bộ giá trị alpha (0.10/0.18/0.90/0.82) như cũ, chỉ đổi màu gốc `Colors.white`→`base` (biến theo theme). Bóng đổ (`boxShadow`) giữ nguyên `Colors.black` — luôn hợp lý bất kể theme.

`Theme.of(context)` luôn trả về ít nhất `ThemeData` mặc định (light) nếu host không set theme — không cần fallback thêm.

TDD: 2 test mới trong `ad_loading_dialog_test.dart` — dựng `MaterialApp(theme: ThemeData.dark()/.light())`, show dialog, đọc `BoxDecoration.color` của `Container`, assert đúng `Colors.white`/`Colors.black.withValues(alpha: 0.10)` tương ứng.

`flutter test`: 739/739 pass, `flutter analyze` sạch.
