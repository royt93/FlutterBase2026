# T196 — Clear nullable ConsentSettings (FIX/ENHANCE)
Priority P2 · Status todo · Source `lib/src/consent/consent_settings.dart:66-81`.

`copyWith(askedAt:null,country:null)` không xoá được giá trị cũ vì `?? this.field`. Khuyến nghị thêm `clearAskedAt`/`clearCountry` flags (non-breaking); sentinel một API nhưng typing phức tạp; đổi semantics nullable là breaking.

Tests: unit set/preserve/clear/JSON; widget privacy UI; integration persist/reload; device smoke redaction.

Loop prompt: audit+score /10, unit/widget/integration mọi case, device smoke; chỉ >9/10 commit+push.
