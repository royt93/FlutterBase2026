# T114 — Tech debt: Hợp nhất lifecycle keyed inline-ad giữa 2 adapter

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `adapters/admob_adapter.dart`, `applovin_adapter.dart`, `_inline_visibility.dart`, 3 widget inline

## Vấn đề

Banner/MREC/native có nhiều map instance, sentinel warmup key, listenable disposal và revive logic gần giống nhau nhưng triển khai lặp ở AdMob/AppLovin — chính là lý do bug T105 (guard onAdOpened/onAdClicked) và T104 (tombstone leak) tồn tại: fix 1 bên quên bên kia. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Internal generic `InlineAdInstanceRegistry<TAd>` quản lý ownership, notifier, generation và dispose
- [ ] Bridge/adapter chỉ cung cấp load/destroy callback
- [ ] KHÔNG đổi public API
- [ ] Giữ 100% test coverage hiện có trong lúc refactor

## Ghi chú

Effort XL, rủi ro cao trên 2 file đã audit 26 vòng riêng biệt. **Nên làm SAU T116 (contract-test chung, DEBT-4)** để có lưới an toàn trước khi gộp code — dù user chọn "làm ngay" cho câu hỏi độ ưu tiên, thứ tự kỹ thuật vẫn nên tôn trọng dependency này. Không nên bắt đầu code tới khi T116 done.

## Thử batch D (2026-08-31), dừng lại — chưa code

T116 đã done (contract-test chung có sẵn), nhưng đọc kỹ trước khi viết code
cho thấy scope thật lớn hơn "trích 1 registry class" nhiều: chỉ riêng
`_bannerSlotsByKey` trong `admob_adapter.dart` đã có 30+ điểm chạm, nhiều chỗ
là identity-check tinh vi ngay trong đường callback (vd
`!identical(_bannerSlotsByKey[key], slot)` ở dòng 1890/1914 — chặn 1 fill
trễ từ slot cũ sau khi `disposeBannerInstance` đã chạy). Đây chính xác là
loại logic mà 26 vòng audit đã tinh chỉnh đúng — 1 registry generic dùng
chung dễ đơn giản hoá quá mức các nhánh identity-check này, hoặc bỏ sót 1
trong số chúng ở 1 trong 2 adapter (lặp lại đúng lớp bug T104/T105 mà ticket
này muốn giải quyết, chỉ theo hướng khác).

Không đủ tự tin refactor an toàn 5000 dòng qua 2 file trong 1 lượt không thể
chia nhỏ ra để review từng bước — dừng, giữ nguyên `todo/`. Gợi ý cho lần
sau: làm theo TỪNG loại instance riêng (banner trước, xong review kỹ, rồi
mrec, rồi native) thay vì viết 1 registry generic áp dụng đồng loạt — mỗi
bước tự nó chạy `test/adapter_contract_test.dart` + full suite trước khi
sang bước kế.

## Kết quả (2026-09-07) — DONE (scope: BANNER only)

- **Status:** ✅ done cho phần banner. **Điểm cuối: 10/10** (2 vòng review
  độc lập `codex`: 5/10 → 10/10). **mrec và native CHƯA làm** — để lại
  cho ticket/phiên sau, đúng gợi ý "từng bước" ở trên.
- User chọn scope THU NHỎ trước khi code: chỉ gộp bookkeeping thuần
  (Map<Object,AdSlot> + Map<Object,BannerListenables> + disposed-sentinel
  pattern) thành `InlineAdInstanceRegistry` (file mới
  `lib/src/adapters/inline_ad_instance_registry.dart`) — KHÔNG đụng tới
  logic identity-check trong load callback (`isCurrent(key, slot)` chỉ
  thay thế `identical(map[key], slot)`, semantics giữ nguyên 100%). KHÔNG
  đổi public API (`bannerSlot`/`bannerSlots`/`banner`/
  `disposeBannerInstance` giữ nguyên chữ ký).
- **Vòng 1 (5/10)** — 1 finding BLOCKER THẬT: AppLovin's
  `_bannerRegistry.markDisposed()` bị gọi QUÁ TRỄ (sau `await
  _bridge.destroyWidgetAdView(...)`), để lại đúng race window mà
  round-25/round-31 đã bảo vệ — 1 callback trễ resume giữa lúc `dispose()`
  đang `await` native destroy sẽ mutate REAL slot/listenables thay vì
  scratch sentinel. Sửa: dời `markDisposed()` lên NGAY đầu `dispose()`,
  cạnh `_bannerDisposed = true;` (đồng bộ, trước mọi await). Reviewer
  CŨNG chỉ ra 1 test hiện có (`onAdLoadFailedCallback...`) là **false
  negative** — assert sau khi `dispose()` xong bị reset-loop tự xoá dấu
  vết bug; sửa bằng cách assert NGAY sau khi callback bắn, TRƯỚC khi
  complete destroy gate — test này FAIL đúng với code cũ (RED xác nhận),
  PASS sau khi fix.
- AdMob's `_bannerRegistry.markDisposed()` giữ nguyên vị trí CUỐI
  `dispose()` (như code gốc) — an toàn vì method này không có `await` nào
  phía trên, chạy hoàn toàn đồng bộ; thêm comment giải thích rõ tại sao
  KHÔNG cần dời, tránh nhầm lẫn với AppLovin trong tương lai.
- Baseline: `flutter analyze` sạch (2 info deprecation pre-existing không
  liên quan); `flutter test` 1771/1771; `test/adapter_contract_test.dart`
  + `test/admob_adapter_test.dart` + `test/applovin_adapter_test.dart` +
  `test/inline_ad_instance_registry_test.dart` (37 test mới cho class)
  đều pass; integration test `banner_ad_test.dart` pass thật trên Samsung
  Galaxy S24 Ultra CẢ 2 provider (trước và sau fix vòng 1).
- **Còn lại cho lần sau:** áp dụng ĐÚNG pattern này (đã proof, đã review,
  đã sửa 1 bug thật) cho mrec rồi native — mỗi bước tự chạy contract test
  + full suite + review trước khi sang bước kế, đúng khuyến nghị gốc.
