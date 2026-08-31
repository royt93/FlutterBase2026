# T130 — Flagship: Token chuyển VIP sang máy mới (ký offline, 1 lần dùng)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P3 · **Status:** 🔲 todo
- **Files:** `lib/src/vip/signed_vip_key.dart` (tái dùng scheme ký sẵn có), `lib/src/vip/vip_manager.dart`, `lib/src/vip/_redeemed_key_ledger.dart`

## Vấn đề

README tự công bố giới hạn: Android không có anti-reinstall bền vững, "clear app data" hoặc đổi máy làm mất VIP. Thay vì chỉ coi đây là rủi ro cần chấp nhận: user chủ động export 1 token ký Ed25519 (dùng CHÍNH private key app, không phải public key VIP) chứa thời gian VIP còn lại + danh sách `kid` đã dùng, TRƯỚC KHI gỡ cài đặt/đổi máy; máy mới verify token offline và áp lại đúng số ngày còn lại, 1 lần dùng.

## Việc cần làm

- [ ] API export token (ký Ed25519, chứa remaining-VIP-time + used-kid-list)
- [ ] API import: verify offline, áp lại VIP, tự thêm token's kid vào `_redeemed_key_ledger` như đã tiêu (chống dùng lại)
- [ ] Vẫn 1 lần dùng, vẫn cần hành động chủ động của user trước khi mất dữ liệu cũ (không làm yếu anti-abuse)
- [ ] Test: export→import đúng thời gian còn lại; import lại token đã dùng → từ chối

## Ghi chú

Priority P3 — chưa xác nhận độ ưu tiên trực tiếp với user (hết slot câu hỏi), để mặc định theo BACKLOG doc.

## 2026-08-31 — ĐÃ ĐỌC KỸ, DỪNG, KHÔNG CODE — lý do kỹ thuật cụ thể

Thiết kế trong "Vấn đề" ở trên có lỗ hổng bảo mật thật, không phải chi tiết vặt:

**"Ký Ed25519 dùng CHÍNH private key app" tự nó KHÔNG chứng minh được gì.**
Đọc `lib/src/compliance/compliance_signing.dart`: on-device signing key
(`_loadOrCreateKeyPair`) được **mỗi install tự sinh ngẫu nhiên**, không có
root-of-trust nào chung giữa các máy. Mọi `SignedPayload`/
`SignedComplianceReport` mang PUBLIC KEY đi kèm ngay trong file (đúng comment
của chính class: "proves internal consistency, not which device produced
it"). Nếu dùng ĐÚNG khoá này để ký "token chuyển VIP", máy B verify token
bằng public key đính kèm TRONG CHÍNH token đó — nghĩa là **bất kỳ ai cũng tự
sinh 1 keypair mới, tự ký 1 token "còn 9999 ngày VIP", và nó verify PASS**,
vì không có gì ràng buộc public-key-đính-kèm phải là public key hợp lệ nào
cả. Đây chính xác là lớp bug "tái dùng nhầm cơ chế ký cho use-case khác" mà
memory phiên trước (fix#5, 2 lần đầu) đã cảnh báo — signing scheme cho
tamper-evidence (đã ký = chưa bị sửa) không thay thế được cho attestation
(đã ký = một bên đáng tin đã cấp phép), và chỉ signing key CỦA MAINTAINER
(giữ ngoài app, dùng ở `tool/vip_mint.dart`) mới có thuộc tính thứ hai —
đúng như chính README/ticket này đã loại trừ ("không phải public key VIP",
nghĩa là không dùng khoá maintainer, nhưng khoá thay thế duy nhất khác lại
không giải quyết được bài toán).

**Phát hiện phụ, quan trọng hơn cả bug trên:** đọc `signed_vip_key.dart` +
`_redeemed_key_ledger.dart` cho thấy **tính năng "chuyển máy" phần lớn ĐÃ
HOẠT ĐỘNG hôm nay, không cần code mới** — với điều kiện user còn giữ lại
chuỗi key gốc đã dùng để redeem (`redeemSignedKey(keyString)`):
`_redeemed_key_ledger` là **local per-device** (không đồng bộ qua server),
nên 1 `AVP2` key string còn hạn (`expiresAtEpochSeconds` — hạn REDEEM, khác
với thời lượng VIP `seconds` nhúng trong payload) redeem lại được trên máy
MỚI ngay bây giờ, không bị chặn gì — máy mới có ledger rỗng. Cái THỰC SỰ
thiếu không phải là 1 cơ chế ký mới, mà là UX: SDK chưa có API cho user XEM
LẠI chuỗi key gốc của các VIP entry còn hạn để họ copy ra trước khi đổi máy
(entry redeem xong không giữ lại key string gốc, chỉ giữ `keyId`/`expiresAt`
đã parse).

**Đề xuất hướng đúng cho lần sau** (không phải hướng trong ticket gốc):
1. `VipEntry` lưu thêm key string gốc (nếu redeem qua `redeemSignedKey`,
   không áp dụng cho VIP từ rewarded-ad-extend vì không có key string).
2. API `VipManager.exportableActiveKeys` trả lại các key string còn
   `expiresAtEpochSeconds` chưa qua hạn — user tự copy, tự redeem lại trên
   máy mới bằng API `redeemSignedKey` ĐÃ CÓ, không cần API import mới.
3. Không cần ký gì thêm — chữ ký MAINTAINER trong chính key string gốc đã đủ,
   đúng root-of-trust duy nhất hệ thống này có.
4. Rủi ro anti-abuse KHÔNG xấu hơn hiện tại: key vẫn 1-lần-dùng mỗi máy (per
   device ledger), user vẫn phải chủ động hành động (copy key) trước khi mất
   dữ liệu cũ — y hệt tinh thần ticket gốc, chỉ khác cơ chế kỹ thuật.

Không tự làm luôn hướng đề xuất trên trong lượt này — đây là quyết định cần
xác nhận với user (đổi field lưu trữ `VipEntry`, ảnh hưởng dữ liệu đã
persist), không phải 1 fix nhỏ tự quyết được.

## ĐÃ ĐÓNG (2026-09-01) — không cần đổi schema, không cần code mới

Đọc lại `_redeemed_key_ledger.dart`/`vip_manager.dart`: ledger one-time-use
(iOS Keychain + Android `AdPreferences`) là **per-device**, không phải
global. Redeem đúng key gốc trên máy MỚI vẫn pass bình thường nếu key chưa
hết hạn — tính năng "chuyển VIP sang máy mới" **đã hoạt động hôm nay**,
không cần đổi gì. Không chọn hướng "SDK lưu lại raw key" ở trên (đổi schema
`VipEntry` đã persist, rủi ro migrate không cần thiết) — chỉ vì SDK không
cần biết/giữ raw key string sau khi verify xong: đó là dữ liệu của HOST (họ
tự lưu string user đã nhập nếu muốn hiển thị lại), không phải trách nhiệm
SDK, và giữ nó lâu hơn cần thiết còn là 1 rủi ro bảo mật nhỏ (SDK ôm 1
plaintext credential không cần).

**Việc đã làm:** thêm mục "Moving a VIP grant to a new device" vào
`README.md` (ngay trước "Cupertino dialog redeem"), document rõ 3 tình huống:
(1) còn key string + chưa hết hạn → redeem lại trên máy mới, hoạt động sẵn;
(2) muốn UX "xem lại code" → trách nhiệm host tự lưu string, không phải SDK;
(3) mất key hẳn → thu hồi qua CRL (T95) + mint key mới (`tool/vip_mint.dart`),
quy trình đã có sẵn đầy đủ. Không sửa code `lib/`, không cần test mới
(không đổi hành vi observable). `flutter analyze` sạch.

"Flagship" này thực chất là tổ hợp 2 tính năng có sẵn (AVP2 key redeem
per-device + CRL) chưa từng được viết thành 1 hướng dẫn rõ ràng cho host —
đóng ticket bằng documentation, không phải feature mới.
