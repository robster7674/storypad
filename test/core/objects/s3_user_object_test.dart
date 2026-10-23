import 'package:flutter_test/flutter_test.dart';
import 'package:storypad/core/objects/s3_user_object.dart';
import 'package:storypad/core/services/backups/backup_service_type.dart';

S3UserObject buildUser({
  String endpointHost = 's3.example.com',
  int? endpointPort,
  String bucket = 'my-journal',
  String? folderName,
  bool? autoBackupEnabled = true,
}) {
  return S3UserObject(
    endpointHost: endpointHost,
    endpointPort: endpointPort,
    useSsl: true,
    region: 'eu-central-1',
    bucket: bucket,
    accessKeyId: 'AKIAEXAMPLEKEYID',
    secretAccessKey: 'super-secret-value',
    pathStyle: true,
    autoBackupEnabled: autoBackupEnabled,
    folderName: folderName,
  );
}

void main() {
  group('S3UserObject', () {
    test('serviceType is s3', () {
      expect(buildUser().serviceType, BackupServiceType.s3);
    });

    test('identifier is bucket@host[:port] and never includes the keys', () {
      expect(buildUser().identifier, 'my-journal@s3.example.com');
      expect(buildUser(endpointPort: 9000).identifier, 'my-journal@s3.example.com:9000');
      expect(buildUser().identifier, isNot(contains('AKIA')));
      expect(buildUser().identifier, isNot(contains('super-secret')));
    });

    test('has no globalId: an access key is not an account', () {
      expect(buildUser().globalId, isNull);
      expect(BackupServiceType.s3.hasGlobalUserId, isFalse);
    });

    test('destinationKey folds in the effective folder, defaulting to StoryPad', () {
      expect(buildUser().destinationKey, 'my-journal@s3.example.com/StoryPad');
      expect(buildUser(folderName: 'Journals/MyDiary').destinationKey, 'my-journal@s3.example.com/Journals%2FMyDiary');
    });

    test('destinationKey differs for different folders in the same bucket', () {
      expect(buildUser(folderName: 'a').destinationKey, isNot(buildUser(folderName: 'b').destinationKey));
    });

    test('configuration shows the location but never a credential', () {
      final shown = buildUser().configuration.map((entry) => '${entry.label}=${entry.value}').join('\n');

      expect(shown, contains('s3.example.com'));
      expect(shown, contains('eu-central-1'));
      expect(shown, contains('my-journal'));
      expect(shown, contains('StoryPad/'));
      expect(shown, isNot(contains('AKIA')));
      expect(shown, isNot(contains('super-secret')));
    });

    test('withAutoBackupEnabled changes only that flag', () {
      final original = buildUser(endpointPort: 9000, folderName: 'x');
      final changed = original.withAutoBackupEnabled(false);

      expect(changed.autoBackupEnabled, isFalse);
      expect(changed.endpointHost, original.endpointHost);
      expect(changed.endpointPort, original.endpointPort);
      expect(changed.bucket, original.bucket);
      expect(changed.accessKeyId, original.accessKeyId);
      expect(changed.secretAccessKey, original.secretAccessKey);
      expect(changed.folderName, original.folderName);
    });
  });

  group('S3UserObject JSON', () {
    test('round-trips every field', () {
      final original = buildUser(endpointPort: 9000, folderName: 'Journals/MyDiary', autoBackupEnabled: false);
      final decoded = S3UserObject.fromJson(original.toJson());

      expect(decoded.endpointHost, original.endpointHost);
      expect(decoded.endpointPort, 9000);
      expect(decoded.useSsl, original.useSsl);
      expect(decoded.region, original.region);
      expect(decoded.bucket, original.bucket);
      expect(decoded.accessKeyId, original.accessKeyId);
      expect(decoded.secretAccessKey, original.secretAccessKey);
      expect(decoded.pathStyle, original.pathStyle);
      expect(decoded.folderName, 'Journals/MyDiary');
      expect(decoded.autoBackupEnabled, isFalse);
    });

    test('uses snake_case keys like the other stored users', () {
      expect(
        buildUser().toJson().keys,
        containsAll([
          'endpoint_host',
          'endpoint_port',
          'use_ssl',
          'region',
          'bucket',
          'access_key_id',
          'secret_access_key',
          'path_style',
          'folder_name',
          'auto_backup_enabled',
        ]),
      );
    });

    test('falls back to safe defaults for optional fields missing from stored JSON', () {
      final decoded = S3UserObject.fromJson({
        'endpoint_host': 's3.example.com',
        'bucket': 'my-journal',
        'access_key_id': 'id',
        'secret_access_key': 'secret',
      });

      expect(decoded.useSsl, isTrue);
      expect(decoded.pathStyle, isTrue);
      expect(decoded.region, S3UserObject.defaultRegion);
      expect(decoded.endpointPort, isNull);
      expect(decoded.folderName, isNull);
      expect(decoded.autoBackupEnabled, isNull);
    });
  });

  group('BackupServiceType.s3', () {
    test('is Pro-only, like every service except Google Drive', () {
      expect(BackupServiceType.s3.isProOnly, isTrue);
    });

    test('has a stable id used as the cloudDestinations key', () {
      expect(BackupServiceType.s3.id, 's3');
      expect(BackupServiceType.s3.s3Service, isTrue);
      expect(BackupServiceType.google_drive.s3Service, isFalse);
    });
  });
}
