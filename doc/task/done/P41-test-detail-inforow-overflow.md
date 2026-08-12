# P41 — `TestDetailScreen._buildInfoRow` không chống overflow với text dài

- **Priority:** P3 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** codex CLI (audit độc lập, đã verify lại trực tiếp)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/test_detail_screen.dart:427-447`

## Vấn đề
`_buildInfoRow(label, value)` dựng `Row(mainAxisAlignment: spaceBetween, children: [Text(label), Text(value)])` — cả 2 `Text` không có `Expanded`/`Flexible`/`overflow`. Dùng cho `roomTag` (dòng 300 khu vực gọi), SSID (:352 khu vực gọi), IP (:370 khu vực gọi) — các giá trị này có thể dài (SSID dài, room tag tự do nhập) và gây overflow render (banner vàng-đen hoặc clip) trên màn hình nhỏ.

## Bằng chứng
- `test_detail_screen.dart:427-447` — định nghĩa hàm, không có `Expanded`/overflow handling.

## Việc cần làm (đề xuất, chưa code)
- Bọc `Text(value)` bằng `Expanded(child: Text(value, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end))`.

## Acceptance criteria
- [ ] SSID/room tag dài (>30 ký tự) hiển thị ellipsis, không overflow/clip trên màn hình nhỏ.
