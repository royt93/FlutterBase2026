# T20 — Test suite: compliance + lifecycle + network

- **REQ:** tất cả (gate chất lượng)
- **Priority:** P2 · **Severity:** — · **Status:** todo
- **Files:** `packages/ad_sdk/test/` (200+ test sẵn có), CI `.github/workflows/test.yml`

## Mục tiêu (Why)
Mỗi fix ở T01–T19 phải có test bảo vệ khỏi hồi quy. Không mark task nào "done" nếu test tương ứng đỏ (theo Definition of Done ở `README.md`).

## Acceptance criteria (checklist theo nhóm)
- [ ] **Consent (T01–T07):** gate `canRequestAds`; npa khi consent=false; không impression trước consent; map CCPA/COPPA đúng; privacy options gọi UMP; ATT ordering.
- [ ] **Network (T08–T10):** offline→online refill (debounced); banner offline→reload; isConnected pessimistic; network error không backoff dài.
- [ ] **Lifecycle (T11–T14):** double-show guard; banner 1-callback/1-load; stream close & dialog pop; route re-subscribe.
- [ ] **Provider (T15–T16):** resolve id theo platform; footgun id rỗng/sai định dạng.
- [ ] **Trial/VIP (T17–T19):** clock rollback inactive; grace-disabled footgun; server validator path; duration âm bị chặn; purge; stacking cap.
- [ ] CI (`packages/ad_sdk`) xanh; `flutter analyze` sạch cả SDK và host.

## Ghi chú
- Chạy: `cd packages/ad_sdk && flutter test` và `flutter test` (repo root).
- Dùng `@visibleForTesting` hooks sẵn có: `debugSetAdapter`, `debugVipManager`, `debugEmit`, `releaseFootgunWarnings`, các `*Override` của ATT.
