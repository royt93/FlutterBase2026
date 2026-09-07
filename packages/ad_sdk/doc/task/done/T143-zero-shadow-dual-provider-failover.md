# T143 — Độc quyền: Zero-shadow dual-provider failover

- **REQ:** brainstorm round 43 (2026-09-06) — 2 nguồn AI độc lập (`codex` +
  `agy`) TỰ ĐỀ XUẤT Ý TƯỞNG GIỐNG NHAU mà không thấy nhau — tín hiệu mạnh.
  User chọn qua AskUserQuestion.
- **Priority:** P1 (differentiator mạnh nếu khả thi — xem cảnh báo kiến trúc
  bên dưới trước khi cam kết effort)
- **Status:** 🔲 todo
- **Effort:** XL (có thể phải nâng lên XXL — xem "Vấn đề kiến trúc" bên dưới)
- **Files (dự kiến):** `lib/src/config/ad_config.dart` (enum `AdProvider`,
  dòng ~62 + assert ở dòng ~418 hiện bắt buộc CHỈ 1 trong 2 config được
  cấp), `lib/src/core/ad_manager.dart` (chọn/khởi tạo adapter)
- **Nguồn gợi ý:** codex + agy đồng thuận độc lập
- **Dependency:** **T136 (WaterfallTuner hoạt động thật, ở nhóm
  Enhancement) — đây là bản "production-hoá" của cơ chế đo lường T136 xây.
  Kiểm tra `doc/task/done/T136-*.md` tồn tại chưa trước khi bắt đầu.**

## ⚠️ Vấn đề kiến trúc — ĐỌC TRƯỚC KHI ƯỚC LƯỢNG EFFORT

**Đã tự verify (không có trong brainstorm gốc): kiến trúc SDK hiện tại là
single-provider-per-install theo THIẾT KẾ, không phải giới hạn tạm thời.**
`AdConfig` (`ad_config.dart:62` enum `AdProvider { appLovin, admob }`) bắt
1 trong 2, và dòng ~418 có `assert` CHỈ chấp nhận config khớp đúng provider
đã chọn (`provider == AdProvider.appLovin ? appLovin != null : admob !=
null`) — nghĩa là **hiện tại không thể khởi tạo CẢ HAI adapter cùng lúc**.

"Failover" đúng nghĩa (tự chuyển sang provider kia khi 1 bên fail liên tục)
đòi hỏi **thay đổi kiến trúc lớn hơn nhiều** so với ước lượng ban đầu của
brainstorm: phải hỗ trợ cấu hình CẢ HAI provider đồng thời + cơ chế chọn
adapter đang active có thể đổi RUNTIME (không chỉ tại `initialize()`), rồi
mới xây logic quyết định "khi nào chuyển" lên trên nền đó. Đây gần như là
1 ticket kiến trúc riêng đứng trước, không chỉ là 1 tính năng cộng thêm.

## Việc cần làm

- [ ] **Bước 0 (bắt buộc trước mọi thứ khác):** xác nhận với user/team có
      thực sự muốn đầu tư vào thay đổi kiến trúc single→dual-provider-
      runtime không, hay chấp nhận scope nhỏ hơn: "failover" chỉ áp dụng
      GIỮA CÁC LẦN KHỞI TẠO (app restart/session mới chọn provider khác dựa
      lịch sử fail của session trước — không cần runtime switch giữa 2
      adapter sống cùng lúc). Bản thu nhỏ này khả thi hơn nhiều với kiến
      trúc hiện tại và vẫn giữ được giá trị differentiator, chỉ khác về mức
      độ "ngay lập tức" của việc failover.
- [ ] Nếu chọn bản đầy đủ (runtime switch): thiết kế lại
      `AdConfig`/`AdManager` để chấp nhận cả `appLovin` lẫn `admob` config
      cùng lúc, cơ chế chọn active adapter, và toàn bộ call site hiện giả
      định "1 adapter cố định" phải audit lại.
- [ ] Nếu chọn bản thu nhỏ (session-based, dùng chung nền T136): dùng dữ
      liệu tích luỹ từ T136 (session-alternate exploration) để quyết định
      provider cho session/init TIẾP THEO nếu provider hiện tại liên tục
      fail — không cần 2 adapter sống cùng lúc.
- [ ] Bất kể bản nào: threshold "liên tục fail" phải configurable, có test
      cho case "fail ngắt quãng không phải liên tục" (không nên trigger
      failover nhầm).

## Ghi chú

Effort XL là ước lượng THẬN TRỌNG cho bản thu nhỏ (session-based, sau khi
T136 xong). Nếu quyết định làm bản đầy đủ (runtime dual-adapter), effort
thật sự lớn hơn nhiều — nên tách thành 1 ticket kiến trúc riêng
("T143a — hỗ trợ dual-provider runtime") trước khi làm phần failover logic
("T143b"), thay vì gộp chung 1 ticket XL duy nhất.

## Kết quả (2026-09-07) — DONE

- **Status:** ✅ done. **Điểm cuối: 9.6/10** (3 vòng review độc lập
  `codex`: 8.0/10 → 8.8/10 → 9.6/10).
- **User ban đầu chọn bản ĐẦY ĐỦ (runtime dual-adapter)**, nhưng audit
  code thật (fork riêng) phát hiện `WaterfallTuner` (T136) đã có doc
  comment RÕ RÀNG: "never switches providers itself... no shadow ad is
  ever requested for the non-active provider" — bản đầy đủ cần giữ
  adapter thứ 2 sống/sẵn sàng, nghĩa là PHẢI request quảng cáo thật từ
  provider không dùng, đi ngược đúng quyết định kiến trúc vừa làm ở T136.
  Báo lại user, **đổi sang bản thu nhỏ** (session-based, đúng option B
  ticket đề xuất) trước khi viết bất kỳ dòng code nào.
- `ProviderFailoverAdvisor` (file mới) — track N lần load fail LIÊN TỤC
  (configurable `consecutiveFailureThreshold`) của provider HIỆN TẠI,
  KHÔNG cần dữ liệu provider kia (khác `WaterfallTuner.recommendation()`
  vốn cần cả 2 provider có data thật). Persist qua restart (mục đích
  chính: quyết định cho session SAU). Auto-reset streak khi providerTag
  đổi. `AdManager().applyProviderFailover()` áp dụng recommendation.
- **Vòng 1 (8.0/10)** — 1 finding MAJOR: `applyProviderFailover(provider)`
  flip BẤT KỲ provider nào được truyền vào miễn `shouldFailoverNextSession`
  true, không check candidate có ĐÚNG LÀ provider đã fail hay không — nếu
  `pickProviderCohort()` đã độc lập chọn provider khoẻ mạnh, hàm này flip
  NGƯỢC về provider vừa fail. Sửa bằng getter `failingProvider` (map
  providerTag → đúng AdProvider enum) + so sánh `!= provider` thay vì chỉ
  check bool.
- **Vòng 2 (8.8/10)** — 1 finding MAJOR: integration test tự viết dùng tag
  giả `[RealDeviceFake]` không map được AdProvider nào (chỉ
  `[AdMob]`/`[AppLovin]` map được) — assertion cũ không còn đúng với fix
  vòng 1. Sửa dùng tag thật `[AppLovin]`, verify cả 2 chiều
  (candidate=provider-fail → flip; candidate=provider-khoẻ → giữ nguyên).
- Baseline: `flutter analyze` sạch (2 info deprecation pre-existing không
  liên quan); `flutter test` 1748/1748; integration test
  `t143_provider_failover_advisor_test.dart` pass thật trên Pixel 7 Pro
  (cả trước và sau fix vòng 2).
- README có section "Zero-shadow dual-provider failover
  (`ProviderFailoverAdvisor`)".

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T143-zero-shadow-dual-provider-failover.md này
(nếu đã chuyển inprogress/done thì đọc ở đó). Cần T136 xong trước — kiểm
tra doc/task/done/T136-*.md tồn tại chưa, nếu chưa thì dừng lại và báo
user. ĐỌC KỸ mục "Vấn đề kiến trúc" — bắt buộc hỏi user chọn bản đầy đủ hay
bản thu nhỏ TRƯỚC KHI viết bất kỳ dòng code nào, đừng tự quyết định thay.

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
