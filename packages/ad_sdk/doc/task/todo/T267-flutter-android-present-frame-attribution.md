# T267 — Đo Frame Presentation/Jank Gắn Với Flutter App Trên Android

- **Loại:** Performance / Measurement / Research
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (điều tra trước; không đổi criterion T257 hoặc khẳng định pass nếu chưa có metric Android-level đáng tin)

## Bối cảnh & Vấn đề

T257 yêu cầu xác minh app giữ ổn định 60fps trong benchmark toàn UI trên Pixel 7 Pro, nhưng Flutter Profile `FrameTiming` chỉ đo mốc/timing trong engine; không chứng minh frame được present hay bị drop. Các lần thử trên Pixel 7 Pro / Android 17:

- `dumpsys gfxinfo` với Flutter `SurfaceView` chỉ ghi nhận vài frame khởi chạy, không theo dõi frame cuộn.
- `dumpsys SurfaceFlinger --latency` theo cả layer `SurfaceView` và `VRI` chỉ trả chu kỳ vsync `8333333ns`, không trả lịch sử frame.
- Perfetto `actual_frame_timeline_slice` chủ yếu thuộc `SurfaceFlinger` với `layer_name=NULL`; process app không có slice cho các pha cuộn. Không khẳng định nguyên nhân; cần xác định SurfaceView/BLAST, cấu hình trace, hoặc giới hạn của hệ thống.
- Pixel 7 Pro liệt kê `android.surfaceflinger.frame`, `.frametimeline`, `.layers` qua `perfetto --query`; trace 10s bật cả ba datasource không cấu hình sinh 0 layer snapshot và 0 FrameTimeline slice. Schema upstream của `SurfaceFlingerLayersConfig` cho thấy mode mặc định ACTIVE chỉ snapshot khi layer thay đổi; GENERATED mode materialize snapshot từ giao dịch lưu trong SurfaceFlinger ring buffer lúc data source flush. Thử trace riêng 10s với `mode: MODE_GENERATED`, `TRACE_FLAG_ALL` cũng cho 0 snapshot, 0 layer, 0 transaction, 0 FrameTimeline slice. Đây không chứng minh datasource không hoạt động: Pixel đang idle trong cả hai lượt, nên chưa có layer transition/transaction để capture. Schema không có sampling interval định kỳ. Trace local ở `/tmp/t267_sf_default.pftrace` và `/tmp/t267_sf_generated.pftrace` (không commit).
- Thử trace 24s khi benchmark T257 deterministic tự cuộn (không `adb swipe`), bật `.frame`, `.layers` (`MODE_GENERATED`, `TRACE_FLAG_ALL`) và `.frametimeline`: trace có 3,049 actual-frame slices và 2,715 expected-frame slices tổng thể, nhưng phần lớn thuộc `surfaceflinger`/SystemUI/launcher/tiến trình nền khác. `com.roy.admobwrapper` (PID 24550) có 6 slice, đều layer `TX - ...MainActivity`, `SurfaceView` BLAST, background hoặc bounds (khởi chạy/chuyển cảnh); 0 slice trong pha scroll. Có tiến trình `com.galaxyjoy.roycasualkit` PID 24934 với 7 slice, không được xem là benchmark target. Layer snapshots/transactions vẫn 0. Kết quả: các datasource mới không cung cấp app-attributed scroll presentation trong cấu hình và thiết bị này; không kết luận chúng không thể làm được với config khác. Trace local `/tmp/t267_active.pftrace` (2.8MB, không commit); config `/tmp/t267_active.cfg`.
- Sau đó thử `.layers` ở `MODE_ACTIVE` + `TRACE_FLAG_ALL`, cùng `.frametimeline` trong trace 24s phủ runner tự cuộn: 1 snapshot chứa 125 layer; layer `SurfaceView[com.roy.admobwrapper/...MainActivity](BLAST)` và `VRI` được đánh dấu `is_visible=1`. Có 2,710 actual-frame slices (2,709 gắn `surfaceflinger`, 1 SystemUI); 0 slice gắn `com.roy.admobwrapper` hoặc layer app. Không có transaction record. Nghĩa là `.layers` thấy được layer SurfaceView của app, nhưng `.frametimeline` vẫn không cấp frame cadence/present record cho nó. Kết quả phân biệt được 'không thấy layer' với 'thấy layer nhưng không app-attributed frames'; chưa chứng minh bằng config/schema chính xác theo build (Android 17 `CP3A.261005.002.A1`, Perfetto v57.0), vì schema upstream `main` chưa đối chiếu được revision Pixel. Trace `/tmp/t267_active_mode.pftrace` (1.2MB, không commit), config `/tmp/t267_active_mode.cfg`.
- Lượt tiếp theo dùng cùng `MODE_ACTIVE` nhưng chọn từng enum trace flag riêng (`TRACE_FLAG_COMPOSITION`, `TRACE_FLAG_HWC`, `TRACE_FLAG_BUFFERS`); OR bằng `|` và số nguyên bitmask đều bị proto validator từ chối (`trace_flags` là enum đơn trong config schema). Mỗi trace 24s cho 1 snapshot/111 layer, 0 transactions, 2,843–2,854 actual-frame slices, gần như toàn bộ `SurfaceFlinger`; SurfaceView layer vẫn visible, không có frame gắn app. Các flags này không thay đổi kết luận trong lượt thử; build/source schema Pixel chính xác vẫn chưa xác minh. Trace `/tmp/t267_flags.pftrace`, `/tmp/t267_TRACE_FLAG_HWC.pftrace`, `/tmp/t267_TRACE_FLAG_BUFFERS.pftrace` (local, không commit), config `/tmp/t267_flags.cfg`.
- App-attributed ftrace từ `--trace-systrace` có `Animator::BeginFrame` và `GPURasterizer::Draw`, nhưng đó là timing của Flutter engine, không xác nhận buffer được present/drop. Hai lượt Profile có trung bình khoảng 106–107 `BeginFrame`/s; lượt runner tự cuộn ghi nhận ba khoảng giữa frame 16.8–19.3ms giữa pha cuộn. Trace có `systrace_parse_failure` đáng kể; raw trace chưa commit.

## Mục tiêu

Tìm phép đo lặp lại được trên thiết bị thật, phân biệt rõ:

1. Thời gian build/raster trong Flutter engine.
2. Buffer submission/composition/presentation ở Android.
3. Frame miss/jank thực sự trong pha scroll in-flight, tách khỏi idle và chuyển pha.

Không hạ tiêu chí 60fps và không diễn giải FrameTiming/BeginFrame như frame-present rate nếu chưa có dữ liệu hỗ trợ.

## Acceptance Criteria

- [ ] Chạy ít nhất 3 lượt trên Google Pixel 7 Pro với runner tự cuộn; benchmark chứa cả deterministic placeholder và AdMob test banner thật (banner phải xác nhận `ready`).
- [ ] Thu metric có app/layer attribution ở presentation/composition layer, hoặc lập chứng cứ có thể tái tạo rằng các API Android hiện hành không cung cấp metric này cho Flutter SurfaceView trên thiết bị hỗ trợ.
- [ ] Correlate frame gaps với phase marks bằng cùng một monotonic clock; loại bỏ idle, startup, UMP/init, và chuyển pha trước tính jank trong scroll in-flight.
- [ ] Kiểm tra tính toàn vẹn trace (parse/import errors), ghi tool/version/config/hash, và không đưa kết luận từ trace hỏng hoặc không app-attributed.
- [ ] Báo đủ raw counts, denominators, p50/p95/p99/max, ngưỡng 60Hz 16.67ms và 120Hz 8.33ms; ghi rõ engine timing khác presentation timing.
- [ ] Chỉ đề xuất kết luận cho T257; không sửa T257 acceptance criterion cho tới khi owner duyệt bằng chứng và cách diễn giải.

## Kế hoạch điều tra

1. Kiểm tra Android/Perfetto datasource và trace config hiện hành; thử FrameTimeline, BufferQueue/SurfaceFlinger layer stats, SurfaceFlinger latency, gfxinfo, và Flutter engine timeline có flow IDs.
2. Xác định layer/buffer của `SurfaceView` trong lúc cuộn; xác minh PID, layer name, buffer acquire/latch/present timestamps trước khi tính metric.
3. Chạy runner tự cuộn có phase marks ổn định; không dùng `adb input swipe` thay cho pha animation của runner.
4. Chạy tối thiểu ba lượt deterministic và ba lượt real-AdMob nếu phép đo cho phép; lưu summary nhỏ và config/query vào repo, raw trace lớn để local evidence nếu không phù hợp để commit.
5. Audit độc lập kết quả trước khi cập nhật T257 hoặc đề xuất đóng criterion 60fps.

## Evidence Đã Thử

- T257 task record và committed artifacts: `doc/task/done/T257-ad-shimmer-loading-full-spectrum-audit-and-hardening.md`, `doc/task/done/T257-evidence/ftrace_summary.txt`, `ftrace_frame_cadence.sql`, `ftrace_scroll_window.sql.template`.
- Current best evidence: app-attributed engine `BeginFrame`/`GPURasterizer::Draw` chỉ; chưa có app-attributed Android frame presentation proof.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Điều tra T267 theo quy trình nghiêm ngặt:
1. Xem T257-evidence và xác nhận mỗi mệnh đề từ raw source/evidence, không dựa trên memory một mình.
2. Viết một phép đo/test có thể phân biệt frame trình bày, frame miss và idle; ghi đỏ/xanh hoặc xác nhận API không hỗ trợ.
3. Chỉ dùng Pixel 7 Pro; tuyệt đối không dùng S24 Ultra.
4. Chạy ít nhất 3 lượt; benchmark real AdMob cần xác nhận banner ready.
5. Audit độc lập toàn bộ truy vấn, clock alignment, trace errors và số liệu trước khi kết luận.
6. Không push hay sửa acceptance T257 nếu chưa đạt bằng chứng và owner chưa duyệt.
```
