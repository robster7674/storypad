import 'package:flutter_test/flutter_test.dart';
import 'package:storypad/core/objects/s3_endpoint.dart';

void main() {
  group('S3Endpoint.tryParse', () {
    test('a bare host means https on the default port', () {
      final endpoint = S3Endpoint.tryParse('s3.eu-central-003.backblazeb2.com')!;

      expect(endpoint.host, 's3.eu-central-003.backblazeb2.com');
      expect(endpoint.port, isNull);
      expect(endpoint.useSsl, isTrue);
      expect(endpoint.authority, 's3.eu-central-003.backblazeb2.com');
    });

    test('keeps an explicit port', () {
      final endpoint = S3Endpoint.tryParse('minio.example.com:9000')!;

      expect(endpoint.host, 'minio.example.com');
      expect(endpoint.port, 9000);
      expect(endpoint.useSsl, isTrue);
      expect(endpoint.authority, 'minio.example.com:9000');
    });

    test('http:// turns TLS off', () {
      final endpoint = S3Endpoint.tryParse('http://192.168.1.5:9000')!;

      expect(endpoint.host, '192.168.1.5');
      expect(endpoint.port, 9000);
      expect(endpoint.useSsl, isFalse);
    });

    test('https:// with a trailing slash is accepted', () {
      final endpoint = S3Endpoint.tryParse('https://s3.example.com/')!;

      expect(endpoint.host, 's3.example.com');
      expect(endpoint.useSsl, isTrue);
    });

    test('lower-cases the host and trims whitespace', () {
      expect(S3Endpoint.tryParse('  S3.Example.COM  ')!.host, 's3.example.com');
    });

    test('localhost with a port (no scheme) is not mistaken for a scheme', () {
      final endpoint = S3Endpoint.tryParse('localhost:9000')!;

      expect(endpoint.host, 'localhost');
      expect(endpoint.port, 9000);
    });

    test('rejects empty input', () {
      expect(S3Endpoint.tryParse(null), isNull);
      expect(S3Endpoint.tryParse(''), isNull);
      expect(S3Endpoint.tryParse('   '), isNull);
    });

    test('rejects unsupported schemes', () {
      expect(S3Endpoint.tryParse('ftp://s3.example.com'), isNull);
      expect(S3Endpoint.tryParse('s3://bucket'), isNull);
    });

    test('rejects a path, query, fragment or credentials instead of dropping them', () {
      expect(S3Endpoint.tryParse('https://example.com/s3'), isNull);
      expect(S3Endpoint.tryParse('https://example.com/?x=1'), isNull);
      expect(S3Endpoint.tryParse('https://example.com/#frag'), isNull);
      expect(S3Endpoint.tryParse('https://user:pass@example.com'), isNull);
    });
  });
}
