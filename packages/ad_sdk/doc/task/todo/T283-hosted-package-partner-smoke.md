# T283 — Xác minh tích hợp package hosted trong app partner mẫu

- **Loại:** Verification / Partner integration
- **Priority:** P1 · **Severity:** MEDIUM
- **Confidence:** Evidence gap
- **Status:** todo
- **Evidence:** `packages/ad_sdk/doc/AD_PROMPT_FLUTTER.MD:101` (consumer Flutter 3.41.9 analyze/build done once; APK chưa cài, log không lưu); integration contract in `packages/ad_sdk/README.md`; round 79 example device evidence không phải consumer app
- **Dependencies:** Flutter toolchain đáp ứng floor package đang publish; Android device; Google test App ID và test ad units

## Bối cảnh & vấn đề

SDK phát hành cho partner tích hợp. Partner guide ghi nhận một app Flutter mới đã chạy `flutter analyze` và build APK từ package hosted, nhưng không cài APK, không lưu log, và không chứng minh init/UMP/ad load trong app consumer độc lập. Smoke trên SDK example không chứng minh app partner theo integration contract dùng đúng cấu hình. Cần validation tái lập, không dùng host app thật hoặc ad inventory production.

## Phạm vi

1. Tạo app consumer disposable ngoài repo; dependency `applovin_admob_sdk` lấy từ pub.dev hosted source, không path dependency.
2. Dùng Google test App ID/test units; theo README contract: navigator key/observers, init trong splash, consent flow phù hợp và test-only provider config.
3. Build, cài, chạy trên Android device; xác nhận SDK init, AdMob adapter state, ít nhất một inline test ad hiển thị, không crash. Lưu `pubspec.lock`, lệnh, device/OS, log và ảnh.
4. Không dùng app ID `com.roy.admobwrapper`, không ghi production IDs/credentials vào repo; không sửa package source trong lúc chạy consumer test.
5. Nếu toolchain/UMP geography cản test, ghi blocker; không biến `notRequired` thành EEA proof.

## Acceptance criteria

- [ ] Consumer resolves package từ hosted pub.dev; lockfile xác nhận `source: hosted` và version đúng version published tại thời điểm chạy.
- [ ] `flutter analyze` và Android debug build pass trong consumer app.
- [ ] APK cài/chạy trên thiết bị với disposable application ID; log xác nhận init, `provider=admob`, load callback/impression của Google test ad nếu inventory hỗ trợ.
- [ ] Screenshot/log và SHA-256 evidence được lưu; redact identifiers nhạy cảm, không lưu token.
- [ ] Smoke xác nhận Android partner integration path, không tuyên bố iOS, AppLovin, production inventory, EEA/legal setup hoặc host app thật.
- [ ] Unit tests SDK không đổi; chạy full SDK suite nếu ticket phát hiện và dẫn tới code change. Widget test N/A nếu chỉ validation; integration device run là acceptance chính.
- [ ] Golden N/A nếu golden/public API không đổi; interruption/network-conditioning/memory-profile/frame-jank chạy khi thay đổi có thể ảnh hưởng. Mediation chỉ chạy nếu scope có mediation; IAP thuộc host, ngoài SDK scope. Mọi N/A kèm lý do.
- [ ] Không cài đè, clear data, hay uninstall `com.roy.admobwrapper`.

## Kế hoạch kiểm thử

- **Unit:** N/A cho consumer smoke; nếu phát hiện defect SDK thì tạo test regression theo feature.
- **Widget:** N/A nếu package behavior không đổi.
- **Integration:** Consumer app độc lập, hosted dependency, Android test ads, consent/init/surface path.
- **Device smoke:** Android device thật, disposable ID, evidence log/screenshot; không chạm click/CTA.

## Prompt vòng lặp (Loop Prompt)

```markdown
Thực hiện T283 như partner release verification. Đọc ticket, `README.md`, `doc/AD_PROMPT_FLUTTER.MD` và integration-test README. Tạo disposable consumer project ngoài repo, resolve SDK từ hosted pub.dev (không path dependency), kiểm tra lockfile source/version. Dùng Google test App ID/ad units và application ID riêng; triển khai đúng README init/navigation/consent contract. Chạy analyze/build/install trên Android device, quan sát init + AdMob test ad callback/impression nếu có; lưu commands, lockfile, device/OS, logs, screenshot và SHA-256. Không chạm production inventory/credentials hoặc `com.roy.admobwrapper`; không tuyên bố EEA/iOS/AppLovin/host-app readiness. Nếu test không tái lập, ghi blocker thay vì pass. Với unit/widget/golden/interruption/network-conditioning/memory-profile/frame-jank/mediation/IAP, chạy lớp có thể bị ảnh hưởng; ghi N/A và lý do cho phần còn lại. IAP thuộc host app, ngoài SDK scope. Nếu xác nhận lỗi runtime, dừng validation-only và tạo regression ticket. Audit độc lập kết quả, score /10. Chỉ push khi có source change được yêu cầu, test áp dụng + device evidence pass, score >9/10; docs-only verification không push.
```
