/// A parsed S3 endpoint, split into the three pieces the `minio` client takes
/// separately (bare host, optional port, TLS on/off).
///
/// Users paste endpoints in many shapes — `https://s3.eu-central-003.backblazeb2.com`,
/// `minio.example.com:9000`, `http://192.168.1.5:9000` — so the connect flow
/// normalizes them here once, instead of leaking URL parsing into the service.
class S3Endpoint {
  const S3Endpoint({
    required this.host,
    required this.port,
    required this.useSsl,
  });

  /// Lower-cased host name or IPv4 address, no scheme/port/path.
  final String host;

  /// Null means "the scheme's default" (443 for https, 80 for http).
  final int? port;

  final bool useSsl;

  /// `host` or `host:port` — what's shown to the user and used in identifiers.
  String get authority => port != null ? '$host:$port' : host;

  /// Parses a user-typed endpoint. A missing scheme means `https`, so plain
  /// (non-TLS) endpoints must be typed as `http://…` explicitly.
  ///
  /// Returns null for anything that can't be used as-is: empty input, an
  /// unsupported scheme, or a URL with a path/query/credentials. A path is
  /// rejected rather than silently dropped because the `minio` client only
  /// supports host-level endpoints — dropping it would send requests to the
  /// wrong place with no hint why.
  static S3Endpoint? tryParse(String? input) {
    final trimmed = input?.trim() ?? '';
    if (trimmed.isEmpty) return null;

    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) return null;

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;

    return S3Endpoint(
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      useSsl: scheme == 'https',
    );
  }
}
