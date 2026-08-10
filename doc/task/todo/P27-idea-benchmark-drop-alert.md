# P27 — Idea: cảnh báo tự động khi tốc độ tụt dưới % benchmark cá nhân

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/benchmark_controller.dart` (đã có `pctOfAdvertised`/`isAboveAdvertised`)

## Ý tưởng
`BenchmarkController` đã tính sẵn `pctOfAdvertised`/`isAboveAdvertised` — chỉ thiếu bước trigger notification khi kết quả tụt dưới ngưỡng X% so với gói cước quảng cáo.

## Việc cần làm (đề xuất, chưa code)
- Sau khi lưu test result, check `pctOfAdvertised` — nếu dưới ngưỡng (config được, default gợi ý 50-70%), bắn local notification qua `NotificationService` đã có sẵn.
- Cân nhắc rate-limit cảnh báo (không spam mỗi lần test đều tụt).

## Acceptance criteria
- [ ] Test tụt dưới ngưỡng → có notification, không spam nếu tụt liên tục nhiều lần trong thời gian ngắn.
- [ ] Ngưỡng cảnh báo config được trong benchmark settings.
