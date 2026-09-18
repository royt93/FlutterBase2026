// T219 — i18n presets for CcpaOptOutStrings/VipDialogStrings: a named `.en`
// preset (previously only reachable as an implicit, unnamed default), a
// `.vi` preset for both (VipDialogStrings previously had none at all — its
// Vietnamese text lived only as a copy-paste example in a doc comment), and
// a `resolve(locale)` helper on each that picks between the two. Does not
// change any existing default — a host that passes nothing still gets
// exactly the same (English) strings as before.

import 'dart:convert';

import 'package:applovin_admob_sdk/src/consent/ccpa_opt_out_strings.dart';
import 'package:applovin_admob_sdk/src/consent/ccpa_opt_out_toggle.dart';
import 'package:applovin_admob_sdk/src/core/ad_manager.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:applovin_admob_sdk/src/vip/vip_redeem_screen.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so this file's VipRedeemScreen test doesn't hit the real
/// (unavailable-in-test) flutter_secure_storage platform channel — mirrors
/// vip_redeem_screen_test.dart's own fixture exactly.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;

  @override
  Future<String?> getRaw() async => _raw;

  @override
  Future<void> setRaw(String json) async => _raw = json;
}

void main() {
  group('CcpaOptOutStrings', () {
    test('.en is identical to the plain default', () {
      expect(CcpaOptOutStrings.en.title, const CcpaOptOutStrings().title);
    });

    test('.vi is unchanged from before this task', () {
      expect(CcpaOptOutStrings.vi.title,
          'Không bán hoặc chia sẻ thông tin cá nhân của tôi');
    });

    test('resolve() picks .vi/.en correctly', () {
      expect(CcpaOptOutStrings.resolve(const Locale('vi')),
          same(CcpaOptOutStrings.vi));
      expect(CcpaOptOutStrings.resolve(const Locale('en')),
          same(CcpaOptOutStrings.en));
    });
  });

  group('VipDialogStrings (T219 — previously had NO named presets at all)',
      () {
    test('.en is identical to the plain default', () {
      expect(VipDialogStrings.en.verifyingTitle,
          const VipDialogStrings().verifyingTitle);
      expect(VipDialogStrings.en.successMessage('2026-01-01'),
          const VipDialogStrings().successMessage('2026-01-01'));
    });

    test('.vi matches the Vietnamese text from this class\'s own doc '
        'comment example, now a real tested preset', () {
      expect(VipDialogStrings.vi.verifyingTitle, 'Đang xác thực');
      expect(VipDialogStrings.vi.failedTitle, 'Mã không hợp lệ');
      expect(VipDialogStrings.vi.successMessage('01/01/2026'),
          'VIP của bạn có hiệu lực đến 01/01/2026.');
    });

    test('resolve() picks .vi/.en correctly', () {
      expect(VipDialogStrings.resolve(const Locale('vi')),
          same(VipDialogStrings.vi));
      expect(VipDialogStrings.resolve(const Locale('en')),
          same(VipDialogStrings.en));
    });
  });

  group(
      'VipRedeemStrings (T219 — found mid-task: a separate, ~30-field '
      'string class for the full VIP redeem SCREEN, distinct from '
      'VipDialogStrings\' small redeem-dialog subset; previously had NO '
      'presets at all)', () {
    test('.en is identical to the plain default', () {
      expect(VipRedeemStrings.en.redeemTitle,
          const VipRedeemStrings().redeemTitle);
      expect(VipRedeemStrings.en.activeEntries(3),
          const VipRedeemStrings().activeEntries(3));
    });

    test('.vi translates every field, including the parameterized ones',
        () {
      expect(VipRedeemStrings.vi.statusActive, 'VIP ĐANG HOẠT ĐỘNG');
      expect(VipRedeemStrings.vi.redeemTitle, 'Nhập mã VIP');
      expect(VipRedeemStrings.vi.activateButton, 'Kích hoạt');
      expect(VipRedeemStrings.vi.expiresAt('01/01/2026'),
          'Hết hạn: 01/01/2026');
      expect(VipRedeemStrings.vi.remainingDays(5), 'còn 5 ngày');
      expect(VipRedeemStrings.vi.remainingHours(4), 'còn 4 giờ');
      expect(VipRedeemStrings.vi.remainingExtraHours(2), '2 giờ');
      expect(VipRedeemStrings.vi.activeEntries(2), 'VIP đang hoạt động (2)');
    });

    test('resolve() picks .vi/.en correctly', () {
      expect(VipRedeemStrings.resolve(const Locale('vi')),
          same(VipRedeemStrings.vi));
      expect(VipRedeemStrings.resolve(const Locale('en')),
          same(VipRedeemStrings.en));
    });

    testWidgets('VipRedeemScreen renders VipRedeemStrings.vi text when '
        'passed the Vietnamese preset', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      final store = _FakeVipEntriesStore(prefs);
      final vip = VipManager(prefs, vipEntriesStore: store);
      await vip.load();
      AdManager().debugVipManager = vip;
      addTearDown(() {
        AdManager().debugVipManager = null;
        vip.dispose();
      });

      final keyPair = await Ed25519().newKeyPair();
      final pub =
          base64Url.encode((await keyPair.extractPublicKey()).bytes);

      await tester.pumpWidget(MaterialApp(
        home: VipRedeemScreen(
          publicKeyBase64: pub,
          strings: VipRedeemStrings.vi,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('VIP CHƯA KÍCH HOẠT'), findsOneWidget);
      expect(find.text('Nhập mã VIP'), findsOneWidget);
      expect(find.text('VIP NOT ACTIVE'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('widget rendering — the resolved preset actually reaches the UI',
      () {
    testWidgets('CcpaOptOutToggle renders CcpaOptOutStrings.vi text when '
        'passed the Vietnamese preset', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CcpaOptOutToggle(strings: CcpaOptOutStrings.vi),
        ),
      ));
      await tester.pump();

      expect(find.text(CcpaOptOutStrings.vi.title), findsOneWidget);
      expect(find.text(CcpaOptOutStrings.en.title), findsNothing);
    });
  });
}
