# P09 — `benchmark_screen.dart` chia 0 khi `maxY = 0`

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/benchmark_screen.dart`

## Vấn đề
Dòng 170: `maxY = ceiling * 1.2`. Nếu chưa cấu hình advertised speed (`adv == null`) và mọi tốc độ đã lưu đều `0.0` Mbps, `ceiling = 0` → `maxY = 0.0`. Dòng 194 dùng `horizontalInterval = maxY / 4` → chia 0 → `NaN`, `fl_chart` render sai/crash tuỳ version.

## Bằng chứng
- `benchmark_screen.dart:170,194`.

## Việc cần làm (đề xuất, chưa code)
- Clamp `maxY` với giá trị floor tối thiểu (VD: `maxY = max(ceiling * 1.2, 10.0)`) để `horizontalInterval` không bao giờ chia 0.

## Acceptance criteria
- [ ] Mở benchmark screen khi chưa có test nào / mọi tốc độ = 0 và chưa set advertised speed — không crash, chart render bình thường (trục Y có giá trị hợp lý, không NaN).
- [ ] Widget test cover case list rỗng + speed toàn 0.
