import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minio/minio.dart' as s3;
import 'package:minio/src/minio_client.dart' show MinioResponse;
import 'package:storypad/core/objects/backup_exceptions/backup_exception.dart';
import 'package:storypad/core/services/backups/backup_service_type.dart';
import 'package:storypad/core/services/backups/s3_cloud_service.dart';

/// What the `minio` client throws for a failed request: the HTTP status lives on
/// the response, the S3 error code (when the body had one) on [s3.Error].
s3.MinioS3Error s3Error(int status, {String? code}) {
  return s3.MinioS3Error(
    'S3 said no',
    s3.Error(code, null, 'S3 said no', null),
    MinioResponse.bytes(Uint8List(0), status),
  );
}

void main() {
  group('S3CloudService', () {
    late S3CloudService service;

    setUp(() {
      service = S3CloudService();
    });

    test('serviceType is s3', () {
      expect(service.serviceType, BackupServiceType.s3);
    });

    test('hasCompression is true (shared with every provider)', () {
      expect(service.hasCompression, isTrue);
    });

    test('is not signed in before initialize/connect', () {
      expect(service.isSignedIn, isFalse);
      expect(service.currentUser, isNull);
    });

    test('generic signIn() is a no-op that reports the current state', () async {
      expect(await service.signIn(), isFalse);
    });

    test('canAccessRequestedScopes/requestScope are false when signed out', () async {
      expect(await service.canAccessRequestedScopes(), isFalse);
      expect(await service.requestScope(), isFalse);
    });

    test('fetchStorageQuota is null when signed out', () async {
      expect(await service.fetchStorageQuota(), isNull);
    });

    test('reauthenticateIfNeeded throws signInRequired when never connected', () async {
      await expectLater(
        service.reauthenticateIfNeeded(),
        throwsA(isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.signInRequired)),
      );
    });

    test('file operations throw signInRequired when not connected', () async {
      await expectLater(
        service.deleteFile('StoryPad/backups/whatever.zip'),
        throwsA(isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.signInRequired)),
      );
      await expectLater(
        service.uploadFile('a.zip', File('a.zip')),
        throwsA(isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.signInRequired)),
      );
      await expectLater(
        service.fetchYearlyBackups(),
        throwsA(isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.signInRequired)),
      );
    });

    test('connect rejects an unparseable endpoint before any network access', () async {
      await expectLater(
        service.connect(
          endpoint: 'ftp://nope',
          region: '',
          bucket: 'my-journal',
          accessKeyId: 'id',
          secretAccessKey: 'secret',
        ),
        throwsA(isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.signInFailed)),
      );
      expect(service.isSignedIn, isFalse);
    });

    test('connect rejects an invalid bucket name before any network access', () async {
      // The client validates bucket names itself; connect() must turn that into
      // a sign-in failure instead of letting a raw client error escape.
      await expectLater(
        service.connect(
          endpoint: 's3.example.com',
          region: '',
          bucket: 'x',
          accessKeyId: 'id',
          secretAccessKey: 'secret',
        ),
        throwsA(isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.signInFailed)),
      );
      expect(service.isSignedIn, isFalse);
    });
  });

  group('S3CloudService.sanitizeFolderName', () {
    test('returns null for null or blank input (use the default)', () {
      expect(S3CloudService.sanitizeFolderName(null), isNull);
      expect(S3CloudService.sanitizeFolderName(''), isNull);
      expect(S3CloudService.sanitizeFolderName('   '), isNull);
    });

    test('trims surrounding whitespace and slashes', () {
      expect(S3CloudService.sanitizeFolderName('  myjournal  '), 'myjournal');
      expect(S3CloudService.sanitizeFolderName('/myjournal/'), 'myjournal');
    });

    test('preserves a nested prefix and collapses empty segments', () {
      expect(S3CloudService.sanitizeFolderName('Journals/MyDiary'), 'Journals/MyDiary');
      expect(S3CloudService.sanitizeFolderName('Journals//MyDiary'), 'Journals/MyDiary');
    });

    test('drops "." and ".." segments defensively', () {
      expect(S3CloudService.sanitizeFolderName('../etc/myjournal'), 'etc/myjournal');
      expect(S3CloudService.sanitizeFolderName('./myjournal'), 'myjournal');
      expect(S3CloudService.sanitizeFolderName('..'), isNull);
    });

    test('keeps spaces (they are percent-encoded consistently) but rewrites "+"', () {
      expect(S3CloudService.sanitizeFolderName('My Diary'), 'My Diary');
      expect(S3CloudService.sanitizeFolderName('Notes+Journal'), 'Notes-Journal');
    });
  });

  group('S3CloudService key helpers', () {
    test('sanitizeFileName rewrites "+" and leaves everything else alone', () {
      const withPlus = 'Backup__4__2025__1734350000000__Galaxy S21+__id.zip';
      const withSpaces = 'Backup__4__2025__1__iPhone 15 Pro__id.zip';

      expect(S3CloudService.sanitizeFileName(withPlus), 'Backup__4__2025__1734350000000__Galaxy S21-__id.zip');
      expect(S3CloudService.sanitizeFileName(withSpaces), withSpaces);
      expect(S3CloudService.sanitizeFileName('1700000000000.jpg'), '1700000000000.jpg');
    });

    test('buildKey joins root, optional folder and file name', () {
      expect(
        S3CloudService.buildKey(rootFolder: 'StoryPad', folderName: 'backups', fileName: 'a.zip'),
        'StoryPad/backups/a.zip',
      );
      expect(S3CloudService.buildKey(rootFolder: 'StoryPad', fileName: 'a.zip'), 'StoryPad/a.zip');
      expect(
        S3CloudService.buildKey(rootFolder: 'Journals/MyDiary', folderName: 'images', fileName: '1.jpg'),
        'Journals/MyDiary/images/1.jpg',
      );
    });

    test('parentOf returns the directory part of a key', () {
      expect(S3CloudService.parentOf('StoryPad/backups/a.zip'), 'StoryPad/backups');
      expect(S3CloudService.parentOf('a.zip'), '');
    });

    test('trashKeyFor mirrors the location relative to the root under .trash', () {
      expect(
        S3CloudService.trashKeyFor(rootFolder: 'StoryPad', key: 'StoryPad/images/1.jpg'),
        'StoryPad/.trash/images/1.jpg',
      );
      expect(
        S3CloudService.trashKeyFor(rootFolder: 'Journals/MyDiary', key: 'Journals/MyDiary/images/1.jpg'),
        'Journals/MyDiary/.trash/images/1.jpg',
      );
    });

    test('trashKeyFor still lands under the root for a key outside it', () {
      expect(S3CloudService.trashKeyFor(rootFolder: 'StoryPad', key: 'other/1.jpg'), 'StoryPad/.trash/other/1.jpg');
    });

    test('copySourceFor percent-encodes each segment but keeps the slashes', () {
      expect(
        S3CloudService.copySourceFor(bucket: 'my-journal', key: 'StoryPad/images/1.jpg'),
        '/my-journal/StoryPad/images/1.jpg',
      );
    });

    test('copySourceFor encodes spaces, plus signs and non-ASCII (device models in backup names)', () {
      const key = 'StoryPad/backups/Backup__4__2025__1__iPhone 15 Pro__id.zip';

      expect(
        S3CloudService.copySourceFor(bucket: 'b', key: key),
        '/b/StoryPad/backups/Backup__4__2025__1__iPhone%2015%20Pro__id.zip',
      );
      expect(S3CloudService.copySourceFor(bucket: 'b', key: 'a/b+c.zip'), '/b/a/b%2Bc.zip');
      expect(S3CloudService.copySourceFor(bucket: 'b', key: 'a/é.zip'), '/b/a/%C3%A9.zip');
    });
  });

  group('S3CloudService.buildException', () {
    final service = S3CloudService();

    test('passes an existing BackupException through untouched', () {
      final original = QuotaException(
        'full',
        QuotaExceptionType.storageQuotaExceeded,
        serviceType: BackupServiceType.s3,
      );
      expect(identical(service.buildException(original, 'x'), original), isTrue);
    });

    test('403 AccessDenied means the credentials/permissions need attention (reconnect)', () {
      final result = service.buildException(s3Error(403, code: 'AccessDenied'), 'uploadFile');

      expect(result, isA<AuthException>().having((e) => e.type, 'type', AuthExceptionType.tokenRevoked));
      expect((result as AuthException).requiresReconnect, isTrue);
    });

    test('a bodiless 403 (e.g. HEAD) is still an auth failure: status is checked before code', () {
      // The client fills the "code" of a bodiless error from the HTTP reason phrase.
      final result = service.buildException(s3Error(403, code: 'Forbidden'), 'findFileById');

      expect(result, isA<AuthException>());
    });

    test('401 and InvalidAccessKeyId/SignatureDoesNotMatch are auth failures', () {
      expect(service.buildException(s3Error(401), 'x'), isA<AuthException>());
      expect(service.buildException(s3Error(400, code: 'InvalidAccessKeyId'), 'x'), isA<AuthException>());
      expect(service.buildException(s3Error(400, code: 'SignatureDoesNotMatch'), 'x'), isA<AuthException>());
    });

    test('clock skew is NOT reported as a revoked credential', () {
      final result = service.buildException(s3Error(403, code: 'RequestTimeTooSkewed'), 'uploadFile');

      expect(result, isNot(isA<AuthException>()));
      expect(result, isA<ServiceException>());
      expect(result.message.toLowerCase(), contains('clock'));
    });

    test('404 NoSuchKey is a "not found" file error with the status attached', () {
      final result = service.buildException(s3Error(404, code: 'NoSuchKey'), 'trashFile');

      expect(result, isA<FileOperationException>().having((e) => e.statusCode, 'statusCode', 404));
      // The cloud-optimize cleanup reads this phrase as "already gone".
      expect(result.toString().toLowerCase(), contains('not found'));
    });

    test('a missing bucket is a 404 too, but must not read as "file not found"', () {
      final result = service.buildException(s3Error(404, code: 'NoSuchBucket'), 'trashFile');

      expect(result, isA<FileOperationException>());
      expect(result.toString().toLowerCase(), isNot(contains('not found')));
    });

    test('file operation type follows the failing method', () {
      FileOperationType typeFor(String method) =>
          (service.buildException(s3Error(404, code: 'NoSuchKey'), method) as FileOperationException).operation;

      expect(typeFor('uploadFile'), FileOperationType.upload);
      expect(typeFor('updateFile'), FileOperationType.upload);
      expect(typeFor('deleteFile'), FileOperationType.delete);
      expect(typeFor('trashFile'), FileOperationType.delete);
      expect(typeFor('getFileContent'), FileOperationType.download);
      expect(typeFor('downloadFileBytes'), FileOperationType.download);
      expect(typeFor('listFilesInFolder'), FileOperationType.list);
    });

    test('429, 503 and SlowDown are rate limits', () {
      for (final error in [s3Error(429), s3Error(503), s3Error(200, code: 'SlowDown')]) {
        expect(
          service.buildException(error, 'x'),
          isA<QuotaException>().having((e) => e.type, 'type', QuotaExceptionType.rateLimitExceeded),
        );
      }
    });

    test('507 is storage full', () {
      expect(
        service.buildException(s3Error(507), 'uploadFile'),
        isA<QuotaException>().having((e) => e.type, 'type', QuotaExceptionType.storageQuotaExceeded),
      );
    });

    test('other 5xx are treated as a (retryable) server/network problem', () {
      final result = service.buildException(s3Error(502), 'x');

      expect(result, isA<NetworkException>());
      expect(result.isRetryable, isTrue);
    });

    test('socket errors and timeouts are network errors', () {
      expect(service.buildException(const SocketException('down'), 'x'), isA<NetworkException>());
      expect(service.buildException(TimeoutException('slow'), 'x'), isA<NetworkException>());
    });

    test('anything unrecognised becomes an unexpected ServiceException', () {
      expect(
        service.buildException(StateError('boom'), 'x'),
        isA<ServiceException>().having((e) => e.type, 'type', ServiceExceptionType.unexpectedError),
      );
    });

    test('every classified exception carries the service type', () {
      expect(service.buildException(s3Error(403), 'x').serviceType, BackupServiceType.s3);
      expect(service.buildException(s3Error(404), 'x').serviceType, BackupServiceType.s3);
      expect(service.buildException(TimeoutException('t'), 'x').serviceType, BackupServiceType.s3);
    });
  });

  group('S3CloudService.describeConnectFailure', () {
    String describe(Object error) => S3CloudService.describeConnectFailure(error);

    test('explains the common mistakes in plain words', () {
      expect(describe(s3Error(404, code: 'NoSuchBucket')), contains('bucket'));
      expect(describe(s3Error(403, code: 'InvalidAccessKeyId')), contains('access key'));
      expect(describe(s3Error(403, code: 'SignatureDoesNotMatch')), contains('secret'));
      expect(describe(s3Error(403, code: 'RequestTimeTooSkewed')), contains('clock'));
      expect(describe(s3Error(403, code: 'AccessDenied')), contains('permission'));
      expect(describe(s3Error(400, code: 'AuthorizationHeaderMalformed')), contains('region'));
    });

    test('reports the client\'s own input validation (bad bucket name)', () {
      expect(describe(s3.MinioInvalidBucketNameError('Invalid bucket name: x')), contains('Invalid bucket name'));
    });

    test('network failures point at the endpoint, not the credentials', () {
      expect(describe(const SocketException('x')), contains('reach the server'));
      expect(describe(TimeoutException('x')), contains('reach the server'));
    });

    test('a non-XML 200 (e.g. a captive portal) is reported as not being S3', () {
      expect(describe(const FormatException('x')), contains('S3'));
    });

    test('never echoes a secret even if the underlying error mentions one', () {
      expect(describe(StateError('secret=hunter2')), isNot(contains('hunter2')));
    });
  });
}
