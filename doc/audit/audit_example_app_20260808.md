# Audit `packages/ad_sdk/example` — code/test/doc quality (2026-08-08)

**Người audit:** Claude (Sonnet 5), đọc source trực tiếp.
**Phạm vi:** chỉ `packages/ad_sdk/example/` (demo/reference app), KHÔNG phải SDK core (`packages/ad_sdk/lib/`) — SDK core đã qua 9 round audit riêng, xem `doc/audit/audit_claude_20260802.md` và các round trước.
**Explicitly out of scope:** ad-serving correctness (real ads thực sự hiển thị) — đã verify thủ công 2026-08-08 (`project_ad_sdk_manual_ad_verify_20260808`, Android+iOS, AppLovin+AdMob, 4 loại ad, không stuck). Round này **chỉ** code/test/doc quality.

**Nguyên tắc:** mọi finding dưới đây đã tự mở source xác minh tới từng dòng. ID prefix `E` (Example) để không trùng với `C`/`N`/`F`/`T` của các audit doc SDK core.

## 0. Kết luận theo từng hạng mục yêu cầu

| # | Hạng mục | Đánh giá |
|---|---|---|
| 1 | `example/lib/main.dart` maintainability | **Chấp nhận được** — 2,585 dòng / 1 file, nhưng 39 class nhỏ (~66 dòng/class trung bình), không phải logic dồn nén như `ad_manager.dart`. Không có precedent audit nào từng bàn về file size (xem E1). |
| 2 | Integration test depth (22 file) | **Đạt, chất lượng cao** — 100% file được đọc/grep đều assert real state, không file nào chỉ "didn't crash" trần trụi (xem E2). |
| 3 | T45 gotcha consistency (`findsWidgets`/`findsOneWidget`, `FilledButton.icon`) | **Đạt, áp dụng nhất quán 100%** — không có regression nào lọt qua (xem E3). |
| 4 | Doc drift (CLAUDE.md "21 files") | **Sai, đã tự sửa** — thực tế 22 file `.dart`, trong đó 21 file test thật + 1 helper (`scroll_helpers.dart`) không có `testWidgets`. Xem E4. |
| 5 | Demo pages làm reference implementation cho 7-point contract | **Đạt, giảng dạy đúng** — không tìm thấy điểm lệch nào so với contract mô tả trong root `CLAUDE.md` (xem E5). |

**Không có finding Critical hoặc High.** Toàn bộ round này là Low/Info — example app ở trạng thái tốt hơn kỳ vọng ban đầu của brief (brief giả định main.dart "chưa split", giả định 21 test file khớp CLAUDE.md — cả hai giả định đều sai theo hướng tốt hơn thực tế, xem E1/E4).

---

## E1 — LOW/INFO: `example/lib/main.dart` (2,585 dòng, 1 file) — chấp nhận được, không có precedent để so sánh

**Kiểm tra file listing:** `packages/ad_sdk/example/lib/` chỉ có **một file Dart**, `main.dart` (`find packages/ad_sdk/example/lib -name "*.dart"` → 1 kết quả). Ứng dụng demo **chưa** được tách thành nhiều file — brief đặt câu hỏi đúng.

**So sánh với `ad_manager.dart`:** `packages/ad_sdk/lib/src/core/ad_manager.dart` = **2,902 dòng**, lớn hơn `main.dart`. Nhưng grep toàn bộ `doc/audit/*.md` (11 file, bao gồm `audit_claude.md`, `audit_claude_20260802.md`, `audit_full_20260711.md`, `audit_codex.md`, `audit_gemini.md`, `policy_crosscheck_20260711.md`, `audit_partner_lead_20260710.md`, `release_1_2_4_and_ci_findings_20260801.md`) cho từ khóa `maintainab|god file|god class|quá lớn|split.*file|tách file|file size` — **không một kết quả nào**. `ad_manager.dart` được trích dẫn bằng số dòng hàng chục lần (functional findings — consent gate, mutex, retry logic) nhưng **chưa từng bị đánh giá về kích thước/maintainability** trong bất kỳ round nào.

**Kết luận:** brief đặt giả thuyết "ad_manager.dart là precedent đã được sign-off" — giả thuyết này **sai**: không phải là chấp nhận có chủ ý (accepted precedent), mà là **chưa từng được xem xét**. Không có bar nào để so `main.dart` vào.

Đánh giá độc lập, không dựa trên precedent giả định:
- `main.dart` chứa **39 top-level class** (`grep -c "^class "`) trong 2,585 dòng — trung bình ~66 dòng/class. Đây là nhiều widget/page nhỏ nằm cùng file, không phải một class/hàm khổng lồ kiểu god-object. Khác về bản chất với `ad_manager.dart`, nơi phần lớn logic tập trung trong class `AdManager` duy nhất.
- Vì đây là **example app** (mỗi class là một demo page độc lập: `BannerDemoPage`, `MrecDemoPage`, `VipDemoPage`, `SafetyDemoPage`, `DiagnosticsDemoPage`, `ComplianceDemoPage`, v.v.), việc gộp 1 file giúp người dùng SDK copy-paste nguyên khối để tham khảo — đánh đổi hợp lý cho một demo app, kém hợp lý hơn cho production code.
- Không có bằng chứng cụ thể (build time, merge conflict, khó điều hướng IDE) rằng kích thước này đang gây vấn đề thực tế trong quá trình audit.

**Verdict:** Low/Info, không phải defect. Nếu muốn cải thiện: tách theo domain demo page (`pages/banner_demo.dart`, `pages/vip_demo.dart`, …) sẽ dễ điều hướng hơn, nhưng đây là cải thiện DX tùy chọn, không phải fix bắt buộc. Không đề xuất coi đây là "chấp nhận theo precedent ad_manager.dart" — không có precedent đó.

---

## E2 — Integration test depth: real-state assertions, không có file "chỉ didn't crash"

Đếm file `.dart` trong `packages/ad_sdk/example/integration_test/`: **22 file**, trong đó **21 file test thật** (có `testWidgets(`) + **1 file helper** (`scroll_helpers.dart`, 51 dòng, không có `testWidgets`, chỉ export `scrollUntilVisibleAndSettle` dùng chung).

Triage có hệ thống bằng grep `expect(`/`findsOneWidget`/`findsWidgets`/`findsNothing`/`FilledButton` trên toàn bộ 21 file test, sau đó đọc trực tiếp representative sample (7 file đầy đủ: `app_boot_test.dart`, `native_ad_test.dart`, `anomaly_event_test.dart`, `log_viewer_test.dart`, `revenue_dashboard_test.dart`, `safety_status_test.dart`, `vip_redeem_flow_test.dart`, cộng phần đầu `diagnostics_demo_test.dart`), và grep tường minh mọi lệnh gọi `pumpAndSettle()` trần (không có tham số) trên cả 21 file để tìm mẫu "pump rồi không assert gì".

**Kết quả:**
- Mọi lệnh `await tester.pumpAndSettle();` trần tìm thấy (7 lần, trong `compliance_export_test.dart:81`, `fill_rate_monitor_demo_test.dart:61`, `monetization_arbitrator_demo_test.dart:60`, `policy_risk_score_test.dart:67`, `safety_status_test.dart:54`, `vip_api_playground_test.dart:122,137`) đều được theo ngay sau bởi `expect(...)` cụ thể trên nội dung UI thật (ví dụ `safety_status_test.dart:55` → `expect(find.text('Safety demo'), findsOneWidget)`, sau đó còn tiếp tục assert giá trị số thật từ `AdManager().config?.safety` ở dòng 60-98). Không file nào dừng lại ở "pump rồi thôi".
- File có `expect(` density thấp nhất (`anomaly_event_test.dart`, 2 lần) vẫn assert **state thật**: `expect(received, hasLength(1))` trên một stream event thực sự nhận được qua `AdManager().events`, không phải placeholder.
- `app_boot_test.dart` (7 `expect`) kiểm tra `AdManager().isInitialised`, `AdManager().vip` non-null, và các API call thật `returnsNormally` — đúng tinh thần "boot integration test" nhưng vẫn có tín hiệu thất bại rõ ràng nếu SDK không init.
- `native_ad_test.dart` — dù comment tự nhận "renders without crashing" (dòng 5-9, vì native ad không có cách nào assert fill quyết định), test vẫn có 2 `findsOneWidget` cụ thể trên text UI thật (`'Native demo'`, `'Native ad v1: fixed layout'`) chứ không dừng ở `tester.takeException() == null` một mình.
- Không file nào dùng `findsWidgets` một cách lỏng lẻo để né tránh chọn đúng finder — mọi chỗ dùng `findsWidgets` (chỉ 2 file: `log_viewer_test.dart:63`, `diagnostics_demo_test.dart:87,118,134`) đều có comment giải thích lý do kỹ thuật cụ thể (HomePage tile ở offstage dưới `MaterialPageRoute`, hoặc spinner xuất hiện tạm thời) — xem E3.

**Verdict:** không có finding nào ở mức Medium+ cho hạng mục này. Test suite 21 file integration test là chất lượng thật, không phải padding coverage.

---

## E3 — T45 gotcha (`findsWidgets` vs `findsOneWidget`, `FilledButton.icon` runtimeType) áp dụng nhất quán trên toàn bộ 21 file, không chỉ nơi phát hiện gốc

`doc/task/done/T45-example-missing-integration-tests-newer-demos.md:39-40` ghi lại 2 bug gốc, cả hai fix trong `diagnostics_demo_test.dart` lúc đó.

Verify tính nhất quán trên **toàn bộ** 21 file (không chỉ 6 file T45 thêm):

- **`FilledButton.icon` gotcha:** grep `byType(FilledButton)` trên toàn bộ thư mục → **0 kết quả**. Mọi chỗ cần tìm nút `FilledButton` đều dùng `find.widgetWithText(FilledButton, '...')` (13 vị trí, ví dụ `consent_country_demo_test.dart:86`, `app_open_ad_test.dart:116`, `interstitial_ad_test.dart:124`, `rewarded_ad_test.dart:123`, `vip_api_playground_test.dart:183`, `slot_state_panel_test.dart:88,110`) hoặc `find.byWidgetPredicate((w) => w is FilledButton)` khi cần match cả `FilledButton.icon` biến thể (`compliance_export_test.dart:97`, có comment giải thích rõ tại dòng 89-96 tại sao không dùng `widgetWithText`). Cả hai kỹ thuật đều né được bug gốc; không file nào regress về `byType(FilledButton)` trần.
- **`findsWidgets` vs `findsOneWidget` sau navigation:** chỉ 2 file thực sự cần `findsWidgets` (do HomePage tile trùng tên với AppBar title của trang được push): `diagnostics_demo_test.dart:87` (comment dòng 84-86 giải thích) và `log_viewer_test.dart:63` (dùng `findsWidgets` cho bước tap tức thời, sau đó chuyển hẳn sang `findsOneWidget` một khi đã ở trang mới — dòng 88). Các file khác có title trùng giữa tile và AppBar (`compliance_export_test.dart`, `revenue_dashboard_test.dart`, `safety_status_test.dart`, `policy_risk_score_test.dart`, …) tự tránh việc trùng bằng cách assert trên `find.descendant(of: find.byType(AppBar), matching: ...)` (ví dụ `compliance_export_test.dart:82-86`) hoặc trên text nội dung khác biệt với tile label — tức là **giải quyết đúng gốc rễ thay vì lặp lại workaround `findsWidgets` không cần thiết**. Đây là mức áp dụng nhất quán cao hơn cả việc "copy-paste cùng 1 fix" — mỗi file chọn kỹ thuật phù hợp với UI cụ thể của nó.

**Verdict:** không tìm thấy file nào bỏ sót 2 gotcha này. Không có finding.

---

## E4 — Doc drift: CLAUDE.md nói "21 files", thực tế 22 — đã sửa

Root `CLAUDE.md:19`:
```
| Ad SDK on-device | `packages/ad_sdk/example/integration_test/` — 21 files | ... |
```

Verify: `ls packages/ad_sdk/example/integration_test/*.dart | wc -l` → **22**.

Phân tích: 22 = 21 file test thật (có `testWidgets(`, xem danh sách ở E2) + 1 file helper `scroll_helpers.dart` (51 dòng, chỉ chứa `scrollUntilVisibleAndSettle`, không có `testWidgets`, được `import` bởi 6 file test khác: `log_viewer_test.dart`, `revenue_dashboard_test.dart`, `compliance_export_test.dart`, `policy_risk_score_test.dart`, `vip_redeem_flow_test.dart`, và một file khác dùng scroll).

Vậy **cả hai con số "21" và "22" đều đúng tùy cách đếm** — CLAUDE.md dòng 19 đang đếm "file test" (21, con số đúng nếu ý là số bài test-suite), nhưng lại ghi trong ngữ cảnh liệt kê nội dung thư mục ("`.../integration_test/` — 21 files") khiến người đọc hiểu nhầm là tổng số file `.dart` trong thư mục — con số đó là 22.

**Đã sửa** dòng 19 của `CLAUDE.md` để phản ánh chính xác cả hai: "22 files (21 test suites + 1 shared `scroll_helpers.dart`)" — theo đúng phạm vi cho phép của audit này (chỉ sửa con số sai này, không đụng chỗ khác của CLAUDE.md).

---

## E5 — Demo pages làm reference implementation: khớp đúng 7-point contract, không tìm thấy điểm lệch

Đối chiếu `packages/ad_sdk/example/lib/main.dart` với 7 điểm trong root `CLAUDE.md` mục "Ad SDK":

| # | Yêu cầu contract | Vị trí trong `main.dart` | Khớp? |
|---|---|---|---|
| 1 | `AdManager().setNavigatorKey(navigatorKey)` trước `runApp` | dòng 337 (`setNavigatorKey`) trước dòng 341 (`runApp(`) | ✓ |
| 2 | `adRouteObserver` + `AdScreenRouteLogger()` trong `navigatorObservers` | dòng 346: `navigatorObservers: [adRouteObserver, AdScreenRouteLogger()]` | ✓ |
| 3 | SDK init bên trong splash screen, không trong `main()` | `AdManager().initialize(...)` ở dòng 468, bên trong `_SplashScreenState` (class bắt đầu dòng 374); `main()` (dòng 323-365) chỉ gọi `setNavigatorKey` + `events.listen`, không init | ✓ |
| 4 | Splash: hard-cap timer, `markSplashActive/Inactive`, `incrementSplashCount`, cancel hard-cap **trước** `showAppOpenAd`, `markSplashInactive()` gọi đúng 1 lần | `markSplashActive()`/`incrementSplashCount()` dòng 414-415; hard-cap `Timer(8s)` dòng 422; cancel-trước-show tại dòng 487-490 (comment tường minh "Cancel hard cap BEFORE showing ad"); `markSplashInactive()` gọi duy nhất 1 chỗ (dòng 506) bên trong `_goHome()`, được guard bởi `_navigated.value` (dòng 499) nên không double-fire kể cả khi gọi từ nhiều event path | ✓ |
| 5 | Screen hiển thị ad extends `AdScreen`/`AdScreenState` | `_BannerDemoPageState`, `_BannerSecondScreenState`, `_MrecDemoPageState`, `_MrecSecondScreenState`, `_NativeDemoPageState`, `_InterstitialDemoPageState`, `_RewardedDemoPageState` đều `extends AdScreenState<...>` (dòng 769, 815, 841, 888, 914, 949, 1022) | ✓ |
| 6 | SDK safety layer không bị bypass ngoài splash App Open | `bypassSafety: true` chỉ xuất hiện 1 lần, tại `showAppOpenAd` trong splash (dòng 490-491), với comment tự giải thích "splash flow is the ONE place safety is bypassed"; watch-ad flow riêng dùng `bypassVipGuard` (khác cờ, đúng theo thiết kế VIP watch-ad ở root CLAUDE.md) | ✓ |
| 7 | App Open không đè lên modal (`AdScreenRouteLogger.isDialogOnTop`) | Nằm trong SDK core (`ad_manager.dart`), không phải trách nhiệm của example — example chỉ cần đăng ký đúng observer (đã ✓ ở #2), việc gate nằm trong SDK | ✓ (gián tiếp qua #2) |

**Điểm đáng chú ý khác (không phải lệch, mà là điểm mạnh về giảng dạy):**
- `StatePanelDemoPage` (dòng 2063+) có nút "Re-initialize SDK" gọi lại `AdManager().initialize(...)` (dòng 2118) ngoài splash — đây **có vẻ** vi phạm "chỉ init trong Splash", nhưng được đặt rõ ràng dưới heading "Lifecycle test" cùng nút "Destroy SDK" (dòng 2096-2129), rõ ràng là demo có chủ đích cho lifecycle/debug testing (dành cho người muốn hiểu `destroy()`/re-init cycle của SDK), không phải pattern được khuyến nghị copy-paste vào flow khởi động thật. Không gây hiểu nhầm cho người đọc vì tách biệt rõ khỏi `SplashScreen`.
- Các trang không hiển thị ad trực tiếp (`ConsentDemoPage`, `SafetyDemoPage`, `VipDemoPage`, `LogViewerDemoPage`, …) đúng đắn dùng `StatefulWidget`/`StatelessWidget` thường thay vì `AdScreenState` — đúng vì chúng không cần `buildBanner()`/interstitial/rewarded helpers.

**Verdict:** không tìm thấy điểm lệch nào so với contract. Example app dạy đúng pattern, và điểm ngoại lệ duy nhất (`StatePanelDemoPage` re-init) được đóng khung rõ ràng là demo nâng cao, không lẫn với pattern chuẩn.

---

## 6. Những gì example app làm tốt (không phải mọi thứ đều là finding)

- 21 integration test suite thật, không phải smoke test rỗng — mỗi file assert trên state cụ thể lấy từ `AdManager()` thật (config, events, vip, safety), không mock giả.
- T45 gotcha (2 bug thật phát hiện qua on-device run 2026-07-19) được xử lý nhất quán ở **mọi** vị trí có nguy cơ, không chỉ nơi phát hiện gốc.
- Splash screen (`main.dart:367-527`) là bản triển khai mẫu mực của 7-point contract, với comment giải thích rõ *tại sao* từng bước phải theo đúng thứ tự — hữu ích cho partner đọc để hiểu, không chỉ copy máy móc.
- Nhiều test file có comment giải thích rõ trade-off kỹ thuật thật (ví dụ tại sao không dùng `pumpAndSettle()` cho `RevenuePanel` vì stream sống, tại sao cần viewport cao giả để list item cuối được build).
- File helper `scroll_helpers.dart` được tái sử dụng đúng mức (6 file dùng chung) thay vì copy-paste logic scroll.

---

## 7. Verdict tổng thể

**Example app đạt chất lượng code/test/doc tốt — không có finding Critical hoặc High.**

Điểm số: **9/10** — trừ điểm duy nhất cho E1 (file demo chưa tách theo domain, dù đây là trade-off hợp lý cho example app) và việc doc drift E4 (dù nhỏ và đã tự sửa trong round này).

Tổng kết theo severity:
- **Critical:** 0
- **High:** 0
- **Medium:** 0
- **Low/Info:** 2 — E1 (main.dart size, chấp nhận được, không phải defect thật), E4 (doc drift 21 vs 22, đã sửa)

Khác với giả định ban đầu trong brief kế hoạch (main.dart "chưa split" + CLAUDE.md khớp đúng "21 files" như một baseline để so sánh), thực tế xác minh cho thấy: main.dart quả thật là 1 file duy nhất (giả định đúng), nhưng CLAUDE.md sai về số đếm (21 vs 22 thực tế) — đã sửa trong round này. Không có precedent audit nào từng bàn về kích thước `ad_manager.dart`, nên E1 được đánh giá độc lập thay vì so với một "tiền lệ đã chấp nhận" không tồn tại.

**Khuyến nghị (không chặn, không bắt buộc):**
1. Cân nhắc tách `main.dart` theo domain demo page nếu file tiếp tục phình to (hiện 2,585 dòng / 39 class là còn quản lý được, nhưng thêm 5-10 demo page mới nữa sẽ đáng tách).
2. Không cần thay đổi gì ở integration test suite — chất lượng đã cao, T45 gotcha đã đóng nhất quán.
