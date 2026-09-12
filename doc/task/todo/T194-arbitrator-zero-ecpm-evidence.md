# T194 — Phân biệt no-evidence với eCPM bằng 0 (FIX)
Priority P1 · Status todo · Source `lib/src/monetization/monetization_arbitrator.dart:263-345`.

Getter trả 0 cho bucket chưa đủ mẫu và bucket đủ mẫu có revenue thật bằng 0; `_decide` coi cả hai là no evidence. Khuyến nghị private evidence model (`hasQualifiedSamples`, `ecpmMicros`) giữ getter public. Sentinel âm khó hiểu; đổi getter nullable là breaking.

Scrum/DoD: decision table cho estimator, warm-up, zero revenue, threshold, veto guardrail; fail-open chỉ khi chưa có mẫu.

Tests: unit mọi nhánh; widget reason zero-value; integration event stream revenue=0; device smoke không suppress/nudge vô hạn.

Loop prompt: audit+score /10, thêm unit/widget/integration mọi case và device smoke; chỉ >9/10 mới commit+push, ngược lại loop.
