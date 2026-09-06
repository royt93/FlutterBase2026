# T141 — Tính năng mới: In-feed Native Ad ListView wrapper

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P3
- **Status:** 🔲 todo
- **Effort:** L
- **Files (dự kiến):** `lib/src/widget/native_ad_widget.dart` (dispose/
  lifecycle pattern tái dùng), file mới
  `lib/src/widget/in_feed_ad_list_view.dart`
- **Nguồn gợi ý:** agy
- **Dependency:** không có

## Vấn đề

`NativeAdWidget` hiện có (`lib/src/widget/native_ad_widget.dart`) chỉ là 1
widget đơn — app tự quản lý việc chèn nó vào giữa danh sách nếu muốn kiểu
"in-feed ad" (interleave native ad mỗi N item trong feed/list), tự lo
dispose khi item cuộn khỏi màn hình. Không có wrapper sẵn cho pattern rất
phổ biến này.

## Việc cần làm

- [ ] Đọc kỹ lifecycle/dispose hiện tại của `NativeAdWidget` (đặc biệt cách
      nó tự dispose khi unmount) trước khi thiết kế wrapper.
- [ ] Tạo `InFeedAdListView` — nhận `itemCount`, `itemBuilder` (như
      `ListView.builder` chuẩn) + `adInterval` (chèn ad mỗi N item, mặc
      định vd 10) + factory tạo `NativeAdWidget` mới cho mỗi vị trí ad.
- [ ] Đảm bảo index thật của `itemBuilder` KHÔNG bị lệch khi tính cả vị trí
      ad chen vào (offset tính đúng).
- [ ] Native ad ở vị trí đã cuộn khỏi viewport xa phải tự dispose đúng theo
      cơ chế `NativeAdWidget` sẵn có — không tự viết lifecycle riêng, tái
      dùng.
- [ ] Widget test: `itemBuilder` nhận đúng index cho item thường, ad xuất
      hiện đúng vị trí `adInterval`, dispose đúng khi scroll xa.

## Ghi chú

Effort L vì cần xử lý đúng offset index (dễ off-by-one) và đảm bảo không
phá lifecycle dispose đã qua nhiều vòng audit của `NativeAdWidget` gốc —
review kỹ code gốc trước khi viết, đừng tự chế lifecycle mới song song.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T141-infeed-native-ad-listview.md này (nếu đã
chuyển inprogress/done thì đọc ở đó). Implement ĐÚNG scope "Việc cần làm" —
KHÔNG thêm scope ngoài mô tả.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có, không tự dựng server/API mới. Nếu ticket
này có vẻ cần backend, dừng lại hỏi user trước khi code.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp: sửa → audit adversarial (codex/agy độc lập trong bản copy cô lập /tmp,
rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R nguyên khối) → nếu
≤9/10 sửa tiếp → verify lại → lặp tới ≥9/10 mới push. KHÔNG tự ý push nếu
chưa đạt ngưỡng. Di chuyển ticket từ todo/ → inprogress/ khi bắt đầu, →
done/ khi xong.
```
