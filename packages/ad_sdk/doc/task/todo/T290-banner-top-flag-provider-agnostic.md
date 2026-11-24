# T290 — Tách cờ `_admobIsTop` khỏi nhà cung cấp trong BannerAdWidget

- **Loại:** Hardening (không phải bug đã chứng minh)
- **Priority:** P3 · **Severity:** LOW
- **Status:** todo — CHỜ BẰNG CHỨNG, chưa làm

## Bối cảnh & Vấn đề

Review độc lập của 3.7.9 (2026-11-23) nhận xét `didPush()` giờ đặt `_admobIsTop = true` cho mọi nhà cung cấp, trong khi cờ chỉ có nghĩa trên nhánh AdMob. Dưới AppLovin cờ này đúng nhưng `didPushNext` không hạ nó, nên giá trị của cờ phụ thuộc nhà cung cấp. Cách sạch hơn: dẫn xuất "đang ở trên cùng" từ `_subscribedRoute?.isCurrent` lúc build, hoặc đánh giá lại cờ khi init xong.

## Vì sao CHƯA làm

Chưa có test đỏ nào chứng minh cần sửa (đã thử, 2026-11-23):

- Route đè lên banner TRƯỚC khi init, rồi đóng: banner vẫn vẽ lại (widget test + Galaxy S24 Ultra + Pixel 7 Pro). `didPopNext` tự bật lại cờ.
- Banner đã tải dưới AdMob bị dọn khi route đè lên, kể cả khi gắn trước init: bản 3.7.9 đang live đã xanh test này.
- Guard `isCurrent` đã được thêm vào callback của `didPush` (commit `b4e074d`) như biện pháp phòng ngừa; không có test đỏ cho nó.

Sửa mà không có bằng chứng sẽ đổi lõi hiển thị của mọi banner AdMob vừa phát hành.

## Điều kiện để làm

Chỉ làm khi có MỘT test tái hiện đỏ trên 3.7.9, ví dụ: một banner dưới AppLovin hoặc một đường điều hướng làm `_admobIsTop` lệch với route thật và gây banner trống hoặc quảng cáo chạy dưới route khác.

## Acceptance Criteria

- [ ] Có test đỏ trên 3.7.9 trước khi sửa (revert-để-thấy-đỏ).
- [ ] Banner AdMob/AppLovin pass trên 2 thiết bị thật (S24U và Pixel 7 Pro): gắn trước init, gắn sau init, đè route trước/sau init.
- [ ] `flutter analyze` sạch, `flutter test` xanh, gate size xanh (lib sát trần).
- [ ] CHANGELOG ghi rõ; không đổi API public.

## Quyết định 2026-11-24
User chọn BỎ: chủ yếu AppLovin (ngoài phạm vi Android + AdMob), và task yêu cầu test đỏ trên 3.7.9 trước khi sửa lõi banner AdMob vừa phát hành. Mở lại khi có test đỏ.
