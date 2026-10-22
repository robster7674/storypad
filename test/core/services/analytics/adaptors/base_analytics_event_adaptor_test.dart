import 'package:flutter_test/flutter_test.dart';
import 'package:storypad/core/services/analytics/adaptors/base_analytics_event_adaptor.dart';

class _RecordingAnalyticsEventAdaptor extends BaseAnalyticsEventAdaptor {
  final List<String> names = [];
  final List<Map<String, Object>?> parameters = [];

  @override
  Future<void> logEvent(String name, {Map<String, Object>? parameters}) async {
    names.add(name);
    this.parameters.add(parameters);
  }

  @override
  Future<void> logScreenView({
    required String screenClass,
    required String screenName,
    Map<String, Object>? parameters,
  }) async {}

  @override
  Future<void> logLogin({required String loginMethod}) async {}
}

// Events must not carry user content: search text, URL paths or query strings.
void main() {
  late _RecordingAnalyticsEventAdaptor adaptor;

  setUp(() => adaptor = _RecordingAnalyticsEventAdaptor());

  test('logSearch logs a search event without a search term', () async {
    await adaptor.logSearch();
    expect(adaptor.names, equals(['search']));
    expect(adaptor.parameters, equals([null]));
  });

  group('URL events log only scheme and host', () {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=12.345678,98.765432');
    const expected = {'scheme': 'https', 'host': 'www.google.com'};

    test('logLaunchUrl', () async {
      await adaptor.logLaunchUrl(uri: uri);
      expect(adaptor.names, equals(['launch_url']));
      expect(adaptor.parameters, equals([expected]));
    });

    test('logOpenLinkInCustomTab', () async {
      await adaptor.logOpenLinkInCustomTab(uri: uri);
      expect(adaptor.names, equals(['open_custom_tab']));
      expect(adaptor.parameters, equals([expected]));
    });

    test('a URL without a host logs only its scheme', () async {
      await adaptor.logLaunchUrl(uri: Uri.parse('mailto:someone@example.com'));
      expect(
        adaptor.parameters,
        equals([
          {'scheme': 'mailto'},
        ]),
      );
    });
  });
}
