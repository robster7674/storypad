import 'package:easy_localization/easy_localization.dart';
import 'package:storypad/core/objects/cloud_service_user.dart';
import 'package:storypad/core/services/backups/backup_service_type.dart';

/// Connection details for one S3-compatible bucket (AWS S3, Backblaze B2,
/// Cloudflare R2, Wasabi, MinIO, Garage, …).
///
/// Persisted through `S3UserStorage` (secure storage), so [secretAccessKey] is
/// at rest in the OS keystore — but it must never reach logs, [identifier],
/// [destinationKey] or [configuration].
///
/// (Serialization is hand-written rather than `@JsonSerializable` so this file
/// has no generated `.g.dart` part; it can be switched to the generator's
/// conventions without changing the stored JSON keys, which are already snake_case.)
class S3UserObject extends CloudServiceUser {
  /// Kept here (rather than only in the service) since [destinationKey] needs
  /// it too, without an object → service dependency.
  static const String defaultFolderName = 'StoryPad';

  /// What the `minio` client signs requests for when a provider has no
  /// meaningful regions (MinIO, Garage) or the user leaves the field blank.
  static const String defaultRegion = 'us-east-1';

  /// Bare host (no scheme, port or path) — see `S3Endpoint`.
  final String endpointHost;

  /// Null means the scheme default (443 / 80).
  final int? endpointPort;

  final bool useSsl;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;

  /// `https://host/bucket/key` (true) vs `https://bucket.host/key` (false).
  /// Path-style works almost everywhere self-hosted; some hosted providers
  /// insist on virtual-hosted style, hence the user-facing switch.
  final bool pathStyle;

  /// Key prefix ("folder") under the bucket where StoryPad stores its data —
  /// defaults to [defaultFolderName] when null.
  final String? folderName;

  @override
  final bool? autoBackupEnabled;

  S3UserObject({
    required this.endpointHost,
    required this.endpointPort,
    required this.useSsl,
    required this.region,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.pathStyle,
    required this.autoBackupEnabled,
    this.folderName,
  });

  @override
  BackupServiceType get serviceType => BackupServiceType.s3;

  /// `host` or `host:port`.
  String get endpointAuthority => endpointPort != null ? '$endpointHost:$endpointPort' : endpointHost;

  /// Deliberately omits the access key: this is the title of the service tile
  /// and the key into `cloudDestinations` / import history, and the same
  /// bucket reached with a rotated key is still the same destination.
  @override
  String get identifier => '$bucket@$endpointAuthority';

  @override
  String? get displayName => identifier;

  @override
  String? get photoUrl => null;

  /// An access key isn't an account: it can't be used to tell that two devices
  /// belong to the same person, so S3 never takes part in purchase-identity
  /// aliasing (see `BackupServiceType.hasGlobalUserId`).
  @override
  String? get globalId => null;

  /// [identifier] alone can't tell two different folders in the same bucket
  /// apart, so the effective folder is always folded in. Percent-encoded so a
  /// nested prefix like `a/b` can't collide with another bucket/endpoint pair.
  @override
  String get destinationKey => '$identifier/${Uri.encodeComponent(folderName ?? defaultFolderName)}';

  /// Shown as plain text on the service's detail screen — never include
  /// [secretAccessKey] (or [accessKeyId]) here.
  @override
  List<({String label, String value})> get configuration => [
    (label: tr("input.s3_endpoint.hint"), value: endpointAuthority),
    (label: tr("input.s3_region.hint"), value: region),
    (label: tr("input.s3_bucket.hint"), value: bucket),
    (label: tr("input.s3_folder_name.hint"), value: "${folderName ?? defaultFolderName}/"),
  ];

  S3UserObject withAutoBackupEnabled(bool? value) {
    return S3UserObject(
      endpointHost: endpointHost,
      endpointPort: endpointPort,
      useSsl: useSsl,
      region: region,
      bucket: bucket,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      pathStyle: pathStyle,
      autoBackupEnabled: value,
      folderName: folderName,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'endpoint_host': endpointHost,
    'endpoint_port': endpointPort,
    'use_ssl': useSsl,
    'region': region,
    'bucket': bucket,
    'access_key_id': accessKeyId,
    'secret_access_key': secretAccessKey,
    'path_style': pathStyle,
    'folder_name': folderName,
    'auto_backup_enabled': autoBackupEnabled,
  };

  factory S3UserObject.fromJson(Map<String, dynamic> json) {
    return S3UserObject(
      endpointHost: json['endpoint_host'] as String,
      endpointPort: json['endpoint_port'] as int?,
      useSsl: json['use_ssl'] as bool? ?? true,
      region: json['region'] as String? ?? defaultRegion,
      bucket: json['bucket'] as String,
      accessKeyId: json['access_key_id'] as String,
      secretAccessKey: json['secret_access_key'] as String,
      pathStyle: json['path_style'] as bool? ?? true,
      autoBackupEnabled: json['auto_backup_enabled'] as bool?,
      folderName: json['folder_name'] as String?,
    );
  }
}
