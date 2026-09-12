# T163 — Tính năng "tự sửa khi quảng cáo kém" bị câm vĩnh viễn sau vài lần đổi qua đổi lại

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** agy, tự verify đúng code thật
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Tính năng "tự sửa khi quảng cáo kém" (`SelfHealingObserver`) theo dõi xem nên gợi ý chuyển sang mạng quảng cáo nào. Nếu nó gợi ý "chuyển sang Google", rồi sau đó gợi ý "chuyển sang AppLovin" (vì Google tạm thời kém hơn) — hệ thống chặn không cho lặp lại gợi ý đã từng đưa. Vấn đề: nếu sau này Google tốt lại và cần gợi ý quay về Google lần nữa, hệ thống sẽ IM LẶNG MÃI MÃI không gợi ý nữa cho vị trí đó (vì cả 2 chiều đã từng được gợi trước đó), dù thực sự cần đổi lại.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/self_healing_observer.dart:91,95,110,113` — `_alreadyObserved` (một `Set<String>`) chỉ được thêm vào (`add`), không bao giờ bị xoá/evict — mỗi cặp `(placement, hướng gợi ý)` chỉ được phép gợi ý đúng 1 lần trong suốt vòng đời.

## Việc cần làm
1. Thiết kế lại cơ chế chống lặp: thay vì chặn vĩnh viễn theo key tĩnh, cân nhắc TTL (hết hạn sau X ngày) hoặc chỉ chặn lặp lại gợi ý GIỐNG HỆT gần đây (không chặn nếu đã có ít nhất 1 gợi ý ngược lại xen giữa).
2. Viết test: gợi ý A → B → (mô phỏng thời gian trôi qua hoặc điều kiện thực tế đổi) → cần gợi ý A lại — xác nhận hệ thống không còn câm.
3. Cập nhật CHANGELOG.md, ghi rõ giới hạn mới của cơ chế chống lặp (TTL bao lâu, hoặc điều kiện gì mở khoá lại).

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/monetization/self_healing_observer.dart: _alreadyObserved (Set<String>, dòng ~91) chỉ add() không bao giờ evict, khiến sau khi 1 vị trí đã nhận đủ 2 chiều gợi ý (A rồi B), hệ thống không bao giờ gợi ý lại cho vị trí đó nữa dù sau này thực sự cần đổi lại. Đọc kỹ toàn bộ logic file để hiểu đúng invariant hiện tại trước khi sửa (đừng phá vỡ mục đích chống dedupe 2 gợi ý sát nhau). Thiết kế cơ chế TTL hoặc "chỉ chặn lặp lại gợi ý giống hệt gần đây trong X ngày" thay vì chặn vĩnh viễn theo key tĩnh. Viết unit test: mô phỏng gợi ý A rồi B rồi (sau khi TTL hết hạn hoặc điều kiện mở khoá) cần A lại — xác nhận không còn bị chặn.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả chống-dedupe-sát-nhau (giữ nguyên hành vi cũ có ích) VÀ mở khoá lại sau TTL/điều kiện.
3. CHANGELOG.md cập nhật rõ ràng cơ chế mới.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device qua demo mô phỏng nhiều vòng lỗi/hồi phục mạng quảng cáo, xác nhận gợi ý tiếp tục hoạt động qua nhiều vòng.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-12)

**Giải thích cho người không rành kỹ thuật:** Tính năng "tự sửa khi quảng
cáo kém" theo dõi 2 mạng quảng cáo (Google/AppLovin), khi 1 bên rõ ràng tệ
hơn bên kia (ít quảng cáo hiện ra hơn, kiếm ít tiền hơn), nó gợi ý dev nên
đổi qua bên tốt hơn. Trước đây, mỗi gợi ý (VD "đổi sang Google cho vị trí
X") chỉ được phép nói 1 LẦN DUY NHẤT trong suốt đời của app — nói 1 lần
xong là câm vĩnh viễn, dù sau này tình hình thay đổi và thực sự cần nói
lại y hệt gợi ý đó. Giờ mỗi gợi ý có "hạn dùng" 7 ngày — nói 1 lần xong sẽ
im lặng trong 7 ngày (tránh làm phiền lặp lại vô ích), nhưng sau 7 ngày,
nếu tình hình vẫn y hệt, nó lại được phép nói lại — không còn câm vĩnh
viễn.

**Kỹ thuật đã sửa:**
- `self_healing_observer.dart`: đổi `_alreadyObserved` từ `Set<String>`
  (chỉ nhớ "đã từng nói") sang `Map<String, DateTime>` (nhớ "nói LẦN CUỐI
  lúc nào"). Thêm tham số `reobserveAfter` (mặc định 7 ngày) và
  `debugClock` (test seam theo đúng pattern có sẵn trong
  `journey_prefetcher.dart`/`revenue_integrity_ledger.dart`).
- `ad_preferences.dart`: đổi từ lưu 1 danh sách chuỗi
  (`getSelfHealingObservedKeys`) sang lưu kèm mốc thời gian
  (`getSelfHealingObservedAt`/`setSelfHealingObservedAt`, key mới trong
  SharedPreferences — dữ liệu cũ không có mốc thời gian nên không migrate
  được, để nguyên không đọc, coi như "chưa từng nói" — hướng sai lệch này
  an toàn hơn: nói thừa 1 lần không hại bằng câm vĩnh viễn).

**Kết quả review độc lập (`codex review --uncommitted`, 2 vòng):**
- Vòng 1: phát hiện 1 lỗ hổng thật — nếu đồng hồ thiết bị bị lùi lại (VD
  đồng bộ lại giờ NTP, hoặc người dùng chỉnh tay sai rồi sửa lại), phép
  trừ thời gian ra số ÂM, và số âm luôn "nhỏ hơn" 7 ngày → lại câm vĩnh
  viễn (chính xác lỗi cũ, chỉ khác đường vào). Đã sửa: coi đồng hồ lùi lại
  là "đã hết hạn ngay lập tức", không phải "vẫn còn mới". Có test riêng.
- Vòng 2: sạch.

**Test coverage:**
- `test/self_healing_observer_test.dart`: thêm 3 test mới — gợi ý câm
  trong vòng 7 ngày rồi nói lại sau khi hết hạn (test chính, dùng đồng hồ
  giả lập), đồng hồ bị lùi lại vẫn nói lại ngay (không bị câm dài hạn),
  giá trị mặc định `reobserveAfter` = 7 ngày. Không sửa/breaking 4 test cũ
  nào (đã cập nhật 1 dòng gọi API đổi tên).
- Full SDK suite: 1847 test xanh.
- Full example suite: 42 test xanh.

**Smoke test thật trên device (Pixel 7 Pro, `2B051FDH3006MU`, Android
17):** file mới
`example/integration_test/r163_self_healing_observer_ttl_test.dart` — tạo
`SelfHealingObserver` thật trên tiến trình app thật, mô phỏng 4 vòng
lỗi/hồi phục (dùng đồng hồ giả lập để nhảy qua nhiều chu kỳ 7 ngày mà
không cần chờ thật): vòng 1 nói, vòng 2 (chưa hết hạn) câm, vòng 3 (đã hết
hạn) nói lại, vòng 4 (thêm 1 chu kỳ nữa) nói lại lần 3 — xác nhận cơ chế
lặp lại được nhiều lần, không phải chỉ "mở khoá 1 lần rồi thôi". PASS.

**Tự chấm điểm: 9.5/10.**
