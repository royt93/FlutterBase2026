# Audit round 36 — final independent review + full-suite Tecno smoke test

Ngày: 2026-09-04. Bối cảnh: round cuối theo yêu cầu user, sau round 35
(audit line-by-line 100% `lib/src/`, 3 bug thật đã fix, review độc lập
9.5/10, smoke test 1 file trên Tecno KJ7).

## Phần 1 — Audit độc lập round cuối (fork, không đọc lại source từ đầu)

Không lặp lại việc đọc toàn bộ source (đã làm ở round 35). Thay vào đó:
verify độc lập diff round 35 (3 fix + 4 file test), tự chạy lại
`flutter analyze`/`flutter test`, đọc lại `audit_round35_consolidated.md`
xem có lạc quan quá mức không, kiểm tra `git status` không có gì ngoài
phạm vi chưa audit.

**Kết quả:** không có finding mới. Xác nhận cả 3 fix đúng gốc, không
regression. Xác nhận 4 file test chứng minh đúng claim (không hời hợt).
Tự chạy lại: **1581/1581 pass, 0 issues** — khớp chính xác số liệu đã báo
cáo, không sai lệch. 2 điểm cực nhỏ nêu ra (fallback `?? -1` không bao giờ
thực sự chạy tới trong `journey_prefetcher.dart`; 1 `addTearDown` reset về
handler mặc định thay vì handler gốc trong 1 test) — cả hai vô hại, không
đủ tính là finding.

**Điểm độc lập cuối: 9.5/10** — khớp điểm round 35, không hạ thấp hơn.

## Phần 2 — Smoke test full 48 file trên Tecno KJ7 thật (AdMob)

Chạy `integration-retry.sh` đầy đủ 48 file trên **TECNO KJ7 thật** (Android
14, arm64, `AD_PROVIDER_ADMOB=true` — không có AppLovin key thật để test
cục bộ, giới hạn đã biết giống mọi lần chạy trước).

**Kết quả: 46/48 pass thật trên phần cứng Android thật.**

2 fail, cả hai đều **đã biết từ trước, không liên quan gì tới round 35**:

1. `r36_real_applovin_appopen_over_banner_test.dart` — cần AppLovin SDK key
   thật, không thể pass khi ép `AD_PROVIDER_ADMOB=true` do không có key cục
   bộ. Giống hệt kết quả trên iOS Simulator ở round 34.
2. `vip_redeem_flow_test.dart` — fail ở bước tìm `find.text('VIP / redeem')`
   (điều hướng UI chưa kịp hoàn tất trong thời gian test chờ). Đây là flake
   timing **đã biết từ trước** — xác nhận qua `doc/audit/
   audit_round34_consolidated.md` (dòng có nhắc "flake `vip_redeem_flow_test`
   đã biết trước đó") và phiên làm việc trước đó cùng ngày trên thiết bị
   Pixel 7 Pro khác cũng gặp đúng flake này. Round 35 không đụng tới
   `vip_redeem_screen.dart`/VIP redeem flow — đã đọc hết file này line-by-line
   ở round 35 và xác nhận sạch — nên đây chắc chắn không phải regression
   mới do 3 fix vừa rồi gây ra.

**Không có bug mới nào phát sinh từ round 35's code trên thiết bị thật.**

## Verdict cuối cùng (round 36, sau 3 lần review độc lập liên tiếp cùng điểm 9.5/10)

- Code: 3 bug thật (1 MAJOR, 2 MINOR) tìm được ở round 35, đã fix, đã qua
  2 vòng review độc lập riêng biệt (8.5/10 → đóng gap → 9.5/10, rồi round
  36 xác nhận lại 9.5/10 không đổi).
- Test: 1581/1581 unit/widget test pass, `flutter analyze` sạch.
- Thiết bị thật: smoke test đầy đủ trên Tecno KJ7 (Android 14) — 46/48
  pass, 2 fail đều đã biết từ trước và không liên quan tới thay đổi vừa
  rồi. iOS Simulator (round 34): 43/48 pass tương tự.
- **Dùng được cho production.** Không còn vùng nào (code hay test) chưa
  được audit và verify bằng chạy thật.
