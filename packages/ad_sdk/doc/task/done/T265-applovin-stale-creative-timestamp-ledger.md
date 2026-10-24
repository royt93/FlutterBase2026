# T265 — Quản Lý Hạn Dùng Quảng Cáo AppLovin MAX Bằng Sổ Cái Thời Gian (Stale Creative Timestamp Ledger)

- **Loại:** Enhancement / Revenue Integrity
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (2026-10-24; Discovery-only / Không triển khai theo quy định trong CLAUDE.md)

## Kết luận Discovery (2026-10-24)

- **Quy định ràng buộc (CLAUDE.md:56):**
  > "AppLovin MAX exposes no load timestamp for ads, so this SDK cannot enforce AdMob-style ad freshness for that provider. Do not claim stale cached MAX creatives are rejected at show time."
- **Lý do kỹ thuật:**
  1. Plugin `applovin_max` tự quản lý vòng đời và bộ nhớ đệm (cache) bên trong native SDK. Nó không trả về timestamp thời điểm tải thực tế của creative từ máy chủ quảng cáo.
  2. Việc dùng thời gian callback `onAdLoaded` trong Dart chỉ phản ánh thời điểm Flutter nhận sự kiện, không phản ánh tuổi thọ thực của creative trên mạng quảng cáo.
  3. AppLovin MAX không cung cấp API cho phép hủy bỏ hoặc làm mới có chọn lọc một creative cụ thể đang nằm trong bộ đệm nội bộ mà không gọi lệnh hiển thị.
  4. Triển khai một bộ đếm thời gian giả lập phía Dart sẽ vi phạm quy định dự án và gây hiểu nhầm về tính đảm bảo doanh thu.
- **Quyết định:** Đóng task dưới dạng Discovery Documented Limitation. Giữ nguyên cơ chế hiện tại, không thêm mã nguồn mới.

## Bối cảnh & Vấn đề ban đầu

Theo chính sách của các mạng quảng cáo:
- Google AdMob có cơ chế tự động kiểm tra quảng cáo đã nạp có quá 4 giờ hay không; nếu quá 4 giờ, quảng cáo được coi là hết hạn (stale) và không được phép phát để tránh hiển thị nội dung lỗi thời và mất doanh thu.
- Ngược lại, plugin `applovin_max` không công khai timestamp thời điểm nạp của creative quảng cáo.
- Nếu người dùng để ứng dụng chạy nền nhiều giờ liền rồi mở lại, quảng cáo AppLovin nạp từ 5-6 tiếng trước vẫn có thể bị đem ra phát. Điều này dẫn đến nguy cơ nhà quảng cáo từ chối trả tiền cho lượt hiển thị đó (unmonetized impression).

## Đề xuất giải pháp

1. Trong `AppLovinAdapter`, khi callback `onAdLoaded` được kích hoạt cho bất kỳ slot toàn màn hình nào (Interstitial, Rewarded, App Open):
   - Ghi lại mốc thời gian nạp `_creativeLoadedTimestamp = DateTime.now()`.
2. Khi hàm `show...` được gọi:
   - Kiểm tra `DateTime.now().difference(_creativeLoadedTimestamp) > Duration(hours: 4)`.
   - Nếu quảng cáo đã quá 4 tiếng, tự động đánh dấu slot là hết hạn (`AdSlot.markExpired()`), hủy creative cũ, và tự động gửi request nạp một creative mới toanh trước khi cho phép hiển thị.

## Acceptance Criteria

- [x] Rà soát và đối chiếu với quy định tại `CLAUDE.md:56` và `admob_adapter.dart:845`.
- [x] Xác nhận `applovin_max` không cung cấp load timestamp và không hỗ trợ API huỷ creative stale an toàn.
- [x] Không triển khai cơ chế freshness giả định bằng Dart wall-clock để tránh vi phạm quy tắc dự án.
- [x] Đã cập nhật task record và phân loại là giới hạn nền tảng đã biết (known platform limitation).

## Kế hoạch kiểm thử

Không có thay đổi mã nguồn SDK. Tiếp tục duy trì toàn bộ test suite xanh hiện tại.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T265 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/adapters/applovin_adapter.dart, lib/src/state/ad_slot.dart.
2. Viết test trước để kiểm tra cơ chế hủy ad quá hạn của AppLovin (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
