# T29 — Splash hard-cap race condition: SDK init bị skip vĩnh viễn nếu timer bắn trước ATT/UMP

- **REQ:** 3 (lifecycle/no-leak), 6 (consent/compliance)
- **Priority:** P0 · **Severity:** CRITICAL · **Status:** ✅ done (2026-07-10)
- **Files:** SDK example `example/lib/main.dart`; host `lib/mckimquyen/widget/splash/splash_screen.dart` (2 vị trí: sau ATT, trước `AdManager().initialize()`)

## Vấn đề (Why)
Splash có hard-cap timer (8s) để tránh app kẹt màn splash nếu ATT/UMP chậm. Nhưng cả 2 file đều có guard `if (!mounted || _hasNavigated) return;` chèn giữa các bước async (ATT dialog → UMP consent form → `AdManager().initialize()`). Nếu hard-cap bắn (điều hướng đi + set `_hasNavigated=true`) TRƯỚC KHI user tap xong dialog ATT/UMP, guard này return sớm ⇒ `initialize()` không bao giờ được gọi cho **cả phiên app** (không phải chỉ splash) — mọi ad surface im lặng, không log lỗi rõ ràng. Không cần `BuildContext`/mounted cho các lời gọi này nên guard vốn dĩ thừa và nguy hiểm.

## Giải pháp đã chọn
Bỏ hết guard `mounted`/`hasNavigated` giữa ATT → UMP → `initialize()`, theo đúng pattern gốc (0 guard) đã có sẵn trong ATT→UMP→initialize chain của example app. Guard trước `initialize()` thay bằng log-only (`SafeLogger.d` ghi lại mounted/hasNavigated để trace, không return).

## Acceptance criteria
- [x] Không còn `if (!mounted...) return;` nào chèn giữa ATT/UMP/`initialize()` ở cả 2 file.
- [x] Hard-cap timer navigate độc lập với init chain (không chặn nhau, không double-navigate).
- [x] Build+run xác nhận log init xuất hiện dù hard-cap đã bắn trước.

## Test
Không có unit test tách riêng (nhánh phụ thuộc timing thật + native dialog, không mock được có ý nghĩa). Xác nhận bằng build/run thật:
- Example app: build_run_sim, log sequence xác nhận `initialize()` chạy dù navigate trước.
- Host app: build/run qua scoped background agent (profile "host" riêng trong session defaults) — log mới xuất hiện, log-skip cũ (dòng return sớm) không còn.

## Kết quả
Cả 2 app đã fix, verify on-device pass. `flutter analyze` clean, test suite hiện có không đổi (nhánh này không unit-testable một cách có ý nghĩa, dựa vào code trace + build verify).

## Giới hạn đã biết
Chưa có regression test tự động cho race condition này (cần fake clock + mock ATT/UMP dialog timing để test được — chưa làm, rủi ro thấp vì pattern hiện tại (0 guard) là bất biến đơn giản, dễ code-review phát hiện lại nếu ai đó vô tình thêm guard mới).
