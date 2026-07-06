# T14 — Route observer re-subscribe + guard timer nhỏ

- **REQ:** 3 (đúng vòng đời)
- **Priority:** P2 · **Severity:** LOW · **Status:** todo
- **Files:** `widget/banner_ad_widget.dart` (`didChangeDependencies` `:50-60`), `core/ad_manager.dart` (`_armSplashBudget` `:301`, `_scheduleFirstSecondaryLoad` `:680`), `widget/shimmer_view.dart` (`initState`)

## Vấn đề (Why)
- Banner subscribe route theo lần đầu; đổi route (vd vào dialog) không re-subscribe → nhận sai event.
- `_armSplashBudget` có thể ghi đè timer cũ không cancel (rủi ro thấp).
- `_scheduleFirstSecondaryLoad` add listener 2 lần nếu init 2 lần không destroy.
- Shimmer AnimationController thiếu guard tạo lại (rất hiếm).

## Acceptance criteria
- [ ] Banner: khi route đổi → unsubscribe route cũ, subscribe route mới; dispose vẫn cân bằng.
- [ ] `_armSplashBudget`: cancel timer cũ trước khi tạo mới.
- [ ] `_scheduleFirstSecondaryLoad`: remove listener cũ trước khi add (idempotent).
- [ ] Shimmer: guard không tạo controller trùng.

## Test
- [ ] Widget test: push→pop→push banner ở route khác nhau vẫn nhận đúng RouteAware event.
