import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/fake_adapter.dart';
import 'package:applovin_admob_sdk/src/core/ad_manager.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AdMob declares banner error self-collapse capability', () {
    final adapter = AdMobAdapter();
    expect(adapter, isA<BannerErrorSelfCollapse>());
    expect(adapter.collapsesBannerOnError, isTrue);
  });

  test('non-collapsing shipped adapters do not opt into the capability', () {
    expect(AppLovinAdapter(), isNot(isA<BannerErrorSelfCollapse>()));
    expect(FakeAdProviderAdapter(), isNot(isA<BannerErrorSelfCollapse>()));
  });

  test('AdManager defaults capability to false without an adapter', () {
    final manager = AdManager();
    manager.debugSetAdapter(null);
    expect(manager.collapsesBannerOnError, isFalse);
  });
}
