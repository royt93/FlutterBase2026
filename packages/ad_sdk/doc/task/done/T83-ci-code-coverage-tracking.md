# T83 — CI không track code coverage theo thời gian

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `.github/workflows/test.yml`

## Vấn đề (Why)
Con số 66.4% (audit 20260711) là đo thủ công 1 lần, không lặp lại mỗi audit. Quyết định quan trọng (bump major, thông báo consumer) hiện chỉ sống trong audit log, không có backlog item chính thức hay số liệu tự động theo thời gian.

## Đề xuất
Thêm bước `flutter test --coverage` + report (badge hoặc artifact) vào CI job `sdk`, không nhất thiết phải set threshold gate ngay — trước mắt chỉ cần có số liệu theo mỗi run.

## Acceptance criteria
- [x] CI job `sdk` xuất coverage report mỗi run (artifact hoặc log).

## Đã làm (2026-08-16)
Job `sdk`: `flutter test` → `flutter test --coverage`. Thêm 2 step mới: (1) tính % coverage bằng `awk` đọc `coverage/lcov.info` (tổng `LF`/`LH` toàn bộ file), ghi vào `$GITHUB_STEP_SUMMARY` — thấy ngay trong tab Summary của run, không cần tải artifact; (2) upload `lcov.info` thô làm artifact (`ad_sdk-coverage-lcov`) để so sánh giữa các run sau này (vd feed vào Codecov/công cụ khác khi cần). Cả 2 step `if: always()` — vẫn có số liệu ngay cả khi test suite fail.

Chưa set threshold gate (đúng yêu cầu ticket — "không nhất thiết phải set threshold gate ngay").

Thêm `coverage/` vào `.gitignore` (chưa từng có, phòng commit nhầm output local).

Verify local: `flutter test --coverage` chạy thật, `awk` script y hệt trong workflow tính đúng **76.0%** (4463/5871 dòng) — cao hơn con số 66.4% ticket trích dẫn từ audit 20260711, hợp lý vì đã thêm rất nhiều test suốt phiên làm việc này. Validate cú pháp YAML bằng `python3 -c "import yaml; yaml.safe_load(...)"` — parse sạch. Không thể chạy thật GitHub Actions cục bộ nên đây là mức verify tối đa khả thi.
