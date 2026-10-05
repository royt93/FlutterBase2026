# T244 — Release gate: đo dung lượng `lib/` theo file đã track, không theo `du` thư mục

- **Loại:** Fix (tooling)
- **Priority:** P2 · **Severity:** LOW
- **Status:** inprogress (chờ audit độc lập)

## Vấn đề

`size_check` dùng `du -sk lib`. `du` làm tròn mỗi file lên block 4 KB và đếm cả file
không thuộc git. Trên máy dev macOS, 2 file `.DS_Store` (đã `.gitignore`) đẩy `lib/`
từ 2028 KB lên đúng 2048 KB, sát trần; dung lượng chữ thật chỉ 1849 KB. Gate vì vậy
phụ thuộc vào rác cục bộ chứ không phải thứ được publish.

## Sửa

`git ls-files -z packages/ad_sdk/lib | xargs -0 -r du -k | awk sum`. Trần 2048 KB giữ
nguyên (không nới giới hạn của chủ dự án). Không cắt comment hay code SDK.
Tổng đo được bằng 0 (không có file track nào) thì gate FAIL, không pass: đo không ra
gì không được coi là đạt.

## Kiểm chứng

- Test mới (`test/release_readiness_gate_test.dart`, group "size stage measures the
  tracked tree"): file untracked không đẩy cây hợp lệ qua trần (đỏ với gate cũ, xanh
  với gate mới); cây track vượt trần vẫn fail; cây sát trần vẫn pass; cây không có file track
  nào phải fail (đỏ trước khi thêm kiểm tra tổng > 0, xanh sau).
- Thực tế repo: gate cũ 2048 KB, gate mới 2028 KB.

## Phạm vi test

Chỉ đổi một script shell và test của nó, nên không có widget hay UI để test và không
có plugin/nền tảng để chạy integration trên thiết bị. Bằng chứng là test subprocess
chạy script thật trên repo git giả, cộng chạy gate thật trên repo này.

## Audit

CHƯA CHẤM. Chưa có reviewer độc lập đọc thay đổi này.

## Giới hạn

- Con số 2028 KB đo trên macOS (APFS). Chưa đo trên Linux CI, nơi `du` tính block có
  thể khác vài KB. Gate mới không đếm block của thư mục nên thường thấp hơn gate cũ.
- Trần vẫn đo theo block 4 KB, nên vẫn cao hơn dung lượng chữ thật (~1849 KB).
