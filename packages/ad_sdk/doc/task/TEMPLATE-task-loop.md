# Txxx — [Tên ngắn gọn của tính năng / bản vá]

- **Loại:** [Bug / Fix / Enhancement / Feature / Hardening]
- **Priority:** [P0 / P1 / P2 / P3] · **Severity:** [CRITICAL / HIGH / MEDIUM / LOW]
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

Mô tả rõ ràng vấn đề kỹ thuật hoặc yêu cầu tính năng:
- Hành vi hiện tại đang bị lỗi hoặc hạn chế ở điểm nào?
- Hậu quả thực tế đối với ứng dụng tích hợp (host app) hoặc doanh thu quảng cáo / trải nghiệm người dùng là gì?
- Các ràng buộc kiến trúc cần tuân thủ (ví dụ: không thêm abstraction thừa, tuân thủ pinning-wall, không vi phạm GDPR/COPPA).

## Đề xuất giải pháp

Kế hoạch thay đổi tối giản:
1. Xác định đúng file và dòng lệnh cần can thiệp.
2. Phương án xử lý theo nguyên tắc Native/Stdlib trước, tối thiểu diff, không over-engineering.
3. Không làm ảnh hưởng tới các luồng khác ngoài phạm vi.

## Acceptance Criteria

- [ ] [Tiêu chí cụ thể 1: logic chính hoạt động đúng]
- [ ] [Tiêu chí cụ thể 2: xử lý đầy đủ các nhánh biên, timeout, error fallback]
- [ ] [Tiêu chí cụ thể 3: không rò rỉ bộ nhớ, timer được huỷ đúng cách]
- [ ] Không đổi hành vi ngoài ý muốn của các provider khác.
- [ ] `flutter analyze` sạch 0 issue; `flutter test` toàn bộ suite xanh.
- [ ] Public API surface không bị thay đổi ngầm (nếu có đổi chủ ý phải cập nhật `CHANGELOG.md` và `test/goldens/public_api_surface.txt`).

## Kế hoạch kiểm thử

- **Unit test:** Viết kiểm thử cho logic trạng thái, timer boundary, và các callback.
- **Widget test:** Kiểm thử hành vi giao diện khi gắn với Widget (Splash, Banner, Native, v.v.).
- **Integration test:** Kiểm thử đầu cuối với thiết bị thật hoặc simulator để xác nhận luồng thực thi trên OS.

---

## Prompt vòng lặp (Loop Prompt)

Sao chép prompt dưới đây để bắt đầu vòng lặp triển khai tính năng theo chuẩn TDD:

```markdown
Triển khai task [Txxx] theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và các file mã nguồn liên quan.
2. Viết test trước để chứng minh lỗi hoặc định hình tính năng (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại toàn bộ code changes với reviewer độc lập và chấm điểm trên thang điểm 10.
   - Bổ sung đầy đủ unit test + widget test + integration test cho mọi case (success, failure, timeout, platform divergence).
   - Smoke test lên device thật (hoặc simulator nền tảng thật) để chứng minh tính năng hoạt động.
   - Nếu mọi thứ hoạt động và điểm đánh giá > 9/10 thì mới được phép push code.
```
