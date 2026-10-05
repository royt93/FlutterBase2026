# T244 — Release gate: đo dung lượng `lib/` theo file đã track, không theo `du` thư mục

- **Loại:** Fix (tooling)
- **Priority:** P2 · **Severity:** LOW
- **Status:** ✅ done

## Vấn đề

`size_check` dùng `du -sk lib`. `du` làm tròn mỗi file lên block 4 KB và đếm cả file
không thuộc git. Trên máy dev macOS, 2 file `.DS_Store` (đã `.gitignore`) đẩy `lib/`
từ 2028 KB lên đúng 2048 KB, sát trần; dung lượng chữ thật chỉ 1849 KB. Gate vì vậy
phụ thuộc vào rác cục bộ chứ không phải thứ được publish.

## Sửa

`git ls-files -z packages/ad_sdk/lib | xargs -0 du -k | awk sum`. Trần 2048 KB giữ
nguyên (không nới giới hạn của chủ dự án). Không cắt comment hay code SDK.

## Kiểm chứng

- Test mới (`test/release_readiness_gate_test.dart`, group "size stage measures the
  tracked tree"): file untracked không đẩy cây hợp lệ qua trần (đỏ với gate cũ, xanh
  với gate mới); cây track vượt trần vẫn fail; cây sát trần vẫn pass.
- Thực tế repo: gate cũ 2048 KB, gate mới 2028 KB.

## Giới hạn

- Con số 2028 KB đo trên macOS (APFS). Chưa đo trên Linux CI, nơi `du` tính block có
  thể khác vài KB. Gate mới không đếm block của thư mục nên thường thấp hơn gate cũ.
- Trần vẫn đo theo block 4 KB, nên vẫn cao hơn dung lượng chữ thật (~1849 KB).
