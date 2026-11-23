# T291 — Bằng chứng click quảng cáo fullscreen trong flight recorder (thứ tự và thời lượng)

- **Loại:** Hardening (chưa phải bug đã chứng minh)
- **Priority:** P3 · **Severity:** LOW–MEDIUM (ảnh hưởng chứng cứ tuân thủ, không ảnh hưởng doanh thu)
- **Status:** todo — CHỜ BẰNG CHỨNG, chưa làm

## Bối cảnh & Vấn đề

Review độc lập (2026-11-23) mô tả: với quảng cáo fullscreen (interstitial/App Open), click phát `AdClickEvent` và `_emit` ghi `clicked` ngay lập tức, nhưng cặp `fullscreenVisible` + `fullscreenDismissed` chỉ được ghi khi quảng cáo đóng, với timestamp lúc đóng. Chuỗi bằng chứng khi đó đọc là `clicked` → `fullscreenVisible` → `fullscreenDismissed`.

Hai hệ quả được nêu:
- `interactionDurationMs` tính so với `fullscreenVisible` của quảng cáo TRƯỚC (đóng lúc trước), nên báo "thời gian từ khi quảng cáo trước kết thúc" thay vì thời gian hiển thị.
- Click dùng `AdPlacement.unspecified` hoặc `splash` trong khi cặp visible/dismissed dùng placement của lần show; khi khác nhau thì thời lượng = 0.

Vị trí được nêu: `core/ad_manager.dart` quanh `_emit` / ghi flight recorder, và `compliance/ad_flight_recorder.dart` (tính `interactionDurationMs`).

Một `.adproof` đã ký có thể khẳng định "đã hiển thị X ms trước khi tương tác" mà code không đảm bảo.

## Vì sao CHƯA làm

Chưa tái hiện được: chưa viết test đỏ, chưa xem chuỗi thật trên thiết bị. Sửa thứ tự ghi bằng chứng mà không có bằng chứng sai là thay đổi lõi tuân thủ, có thể làm hỏng các export đã ký và các kiểm chứng offline (`verify_adproof`, `incident_replay`).

## Điều kiện để làm

Một test tái hiện đỏ: mô phỏng click trên interstitial rồi đóng, đọc chuỗi flight recorder, và chỉ ra thứ tự hoặc `interactionDurationMs` sai. Nếu đúng, cần quyết định sản phẩm: ghi `fullscreenVisible` lúc show (thay vì lúc đóng) hay sửa cách tính thời lượng.

## Acceptance Criteria

- [ ] Có test đỏ trên bản hiện tại trước khi sửa.
- [ ] `tool/verify_adproof.dart` và `tool/incident_replay.dart` vẫn xác minh được các export cũ (không phá tương thích chữ ký).
- [ ] `flutter analyze` sạch, `flutter test` xanh, gate size xanh.
- [ ] CHANGELOG ghi rõ; nếu đổi định dạng bằng chứng thì cập nhật golden API.
