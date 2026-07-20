# T56 — TCF/IAB TC-String không sync, chỉ forward boolean

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding F7
- **Priority:** P3 (Low) · **Status:** ✅ done — verified, giữ nguyên có chủ đích (2026-07-20)
- **Files:** (chỉ đọc) `applovin_max` 4.6.4 (AppLovin SDK 13.6.3 pin), AdMob UMP integration

## Vấn đề (Why)
Audit gốc nghi ngờ app chỉ forward boolean consent giữa AdMob UMP và AppLovin CMP, không sync TC-String IAB chuẩn — có thể vi phạm TCF nếu 1 bên không nhận được consent string đầy đủ.

## Kết luận
Đọc lại `applovin_max` (AppLovin SDK 13.6.3) + AdMob UMP: TCF TC-String được cả 2 SDK native tự đọc trực tiếp từ `SharedPreferences` theo chuẩn IAB (`IABTCF_TCString` key) — không cần app tự forward. Nhận định gốc "chỉ forward boolean" mô tả sai một layer đã tự động hoá sẵn trong native SDK. Sửa lại nhận định trong tài liệu audit, không có code nào cần đổi.

## Acceptance criteria
- [x] Xác nhận native SDK có tự đọc TC-String chuẩn IAB hay không.
- [x] Sửa nhận định sai trong audit doc nếu có.

## Đã verify (2026-07-20)
Không sửa code. Xem `doc/audit/audit_claude.md` round 9 (mục F7).
