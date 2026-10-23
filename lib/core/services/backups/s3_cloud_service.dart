import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:minio/minio.dart' as s3;
import 'package:storypad/core/objects/backup_exceptions/backup_exception.dart' as exp;
import 'package:storypad/core/objects/cloud_file_object.dart';
import 'package:storypad/core/objects/cloud_storage_quota_object.dart';
import 'package:storypad/core/objects/s3_endpoint.dart';
import 'package:storypad/core/objects/s3_user_object.dart';
import 'package:storypad/core/objects/yearly_backup_files_object.dart';
import 'package:storypad/core/services/backups/backup_cloud_service.dart';
import 'package:storypad/core/services/backups/backup_service_type.dart';
import 'package:storypad/core/services/logger/app_logger.dart';
import 'package:storypad/core/storages/s3_user_storage.dart';

/// Backup target for any S3-compatible object store (AWS S3, Backblaze B2,
/// Cloudflare R2, Wasabi, MinIO, Garage, …), reached with a user-supplied
/// endpoint + access key — no StoryPad server involved.
///
/// Mapping onto [BackupCloudService]:
/// - **IDs** — the full object key is used as [CloudFileObject.id] everywhere
///   (like Nextcloud's path); S3 has no separate stable file ID.
/// - **Folders** — S3 has none; `<folder>/backups/…` is just a key prefix, so
///   nothing needs creating before an upload.
/// - **Trash** — S3 has no trash and no rename, so [trashFile] is
///   copy-to-`.trash/` + delete, and [restoreFileFromTrash] the reverse.
/// - **Quota** — S3 exposes none; [fetchStorageQuota] reports StoryPad's own
///   usage only (no account usage or limit).
/// - **Auth** — static keys don't expire or refresh, so there is no silent
///   re-auth: a 401/403 is surfaced as a revoked grant (reconnect) just like a
///   revoked Nextcloud app password.
class S3CloudService extends BackupCloudService {
  @override
  BackupServiceType get serviceType => BackupServiceType.s3;

  /// The `minio` client uses `package:http` with no timeout of its own, so a
  /// stalled connection would otherwise hang a whole sync forever.
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// Listings (several pages) and file transfers.
  static const Duration _bulkTimeout = Duration(minutes: 5);

  S3UserObject? _currentUser;

  @override
  S3UserObject? get currentUser => _currentUser;

  @override
  bool get isSignedIn => _currentUser != null;

  s3.Minio? _client;

  /// The account's configured key prefix, e.g. `Journals/MyDiary` — falls back
  /// to [S3UserObject.defaultFolderName] when left blank.
  String get _rootFolder => _currentUser?.folderName ?? S3UserObject.defaultFolderName;

  // ---------------------------------------------------------------------------
  // Pure helpers (no I/O) — static so they can be tested directly.
  // ---------------------------------------------------------------------------

  /// Replaces `+`, the one character the `minio` client's request signer can't
  /// handle in an object key: its canonical-path encoder turns a `+` into `%20`
  /// (reading it as a space), while a literal `+` in the request path means a
  /// plus to the server — so the two sides compute different signatures and the
  /// request fails with `SignatureDoesNotMatch`. (Spaces and non-ASCII
  /// characters are fine; those are percent-encoded consistently.)
  ///
  /// Matters because backup file names embed the device model, which can
  /// contain `+`. Assumption, not verified by running it: Dart's `Uri` leaves
  /// `+` unencoded in a path.
  static String sanitizeFileName(String fileName) => fileName.replaceAll('+', '-');

  /// Trims slashes, drops empty/`.`/`..` segments and returns a clean relative
  /// prefix, or null (meaning "use the default") when nothing usable is left.
  /// An object key can contain `..` literally, but a prefix that looks like a
  /// path traversal is never what the user means, so it's dropped defensively.
  /// Also applies [sanitizeFileName]'s `+` rule, since the prefix is part of
  /// every key.
  static String? sanitizeFolderName(String? input) {
    if (input == null) return null;

    final segments = input
        .split('/')
        .map((segment) => sanitizeFileName(segment.trim()))
        .where((segment) => segment.isNotEmpty && segment != '.' && segment != '..');

    final cleaned = segments.join('/');
    return cleaned.isEmpty ? null : cleaned;
  }

  /// `<root>/<folder>/<fileName>`, or `<root>/<fileName>` without a folder.
  static String buildKey({required String rootFolder, String? folderName, required String fileName}) {
    return folderName != null ? '$rootFolder/$folderName/$fileName' : '$rootFolder/$fileName';
  }

  /// The directory part of [key] (`a/b/c.zip` → `a/b`), or '' for a top-level key.
  static String parentOf(String key) {
    final index = key.lastIndexOf('/');
    return index < 0 ? '' : key.substring(0, index);
  }

  /// Where [key] lives while trashed: `<root>/.trash/<key relative to root>`,
  /// mirroring its original location so [restoreFileFromTrash] needs no lookup.
  static String trashKeyFor({required String rootFolder, required String key}) {
    final rootPrefix = '$rootFolder/';
    final relative = key.startsWith(rootPrefix) ? key.substring(rootPrefix.length) : key;
    return '$rootFolder/.trash/$relative';
  }

  /// The `x-amz-copy-source` header value for [key]. The header must be
  /// percent-encoded — and StoryPad's backup file names contain the device
  /// model (`Backup__4__…__iPhone 15 Pro__…`), i.e. spaces — while the `minio`
  /// client passes the value through verbatim.
  static String copySourceFor({required String bucket, required String key}) {
    final encodedKey = key.split('/').map(Uri.encodeComponent).join('/');
    return '/$bucket/$encodedKey';
  }

  /// A short, user-readable reason a connection attempt failed — shown in the
  /// failure snackbar. Never includes credentials.
  static String describeConnectFailure(Object error) {
    if (error is s3.MinioS3Error) {
      final status = error.response?.statusCode;
      final code = error.error?.code;

      switch (code) {
        case 'NoSuchBucket':
          return 'The bucket does not exist. Check the bucket name, region and endpoint.';
        case 'InvalidAccessKeyId':
          return 'The access key ID was not recognized by this endpoint.';
        case 'SignatureDoesNotMatch':
          return 'The secret access key is wrong (or the region does not match).';
        case 'RequestTimeTooSkewed':
          return "This device's clock is out of sync with the server. Check the date and time settings.";
        case 'AccessDenied':
          return 'Access denied. The key needs list, read, write and delete permission on the bucket.';
        case 'AuthorizationHeaderMalformed':
        case 'PermanentRedirect':
          return 'The region looks wrong for this bucket.';
      }

      if (status == 301) return 'The region looks wrong for this bucket.';
      if (status == 403) return 'Access denied. Check the access key, secret key and bucket permissions.';
      if (status == 404) return 'Not found. Check the endpoint and bucket name.';

      return 'The server answered with ${status ?? 'an error'}${code != null ? ' ($code)' : ''}.';
    }

    if (error is TimeoutException ||
        error is io.SocketException ||
        error is io.TlsException ||
        error is http.ClientException) {
      return 'Could not reach the server. Check the endpoint and your connection.';
    }

    // E.g. an HTML captive-portal/login page answering where XML was expected.
    if (error is FormatException) return 'The endpoint did not respond like an S3 service.';

    // The client's own input validation (bucket name, endpoint, port): its
    // messages describe the setting, never a credential.
    if (error is s3.MinioError) return 'Invalid S3 settings: ${error.message}';

    return 'Unexpected error (${error.runtimeType}).';
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> initialize() async {
    _currentUser = await S3UserStorage().readObject();

    final user = _currentUser;
    if (user == null) return;

    try {
      _client = _buildClient(user);
    } catch (e) {
      // Stored settings the client now rejects: keep the user (so the UI shows
      // a connection that needs attention) but leave no client, which makes
      // every operation report "sign in required" instead of crashing startup.
      AppLogger.d('S3CloudService#initialize: could not build client: $e');
    }
  }

  s3.Minio _buildClient(S3UserObject user) {
    return s3.Minio(
      endPoint: user.endpointHost,
      port: user.endpointPort,
      useSSL: user.useSsl,
      accessKey: user.accessKeyId,
      secretKey: user.secretAccessKey,
      // Always explicit: without it the client first asks the bucket for its
      // region (an AWS-specific call), and for AWS endpoints it requires one.
      region: user.region,
      pathStyle: user.pathStyle,
    );
  }

  @override
  void setAutoBackupEnabled(bool enabled) {
    if (_currentUser == null) return;

    _currentUser = _currentUser!.withAutoBackupEnabled(enabled);
    S3UserStorage().writeObject(_currentUser!);
  }

  /// Not part of [BackupCloudService] — S3 auth is a multi-field form, not a
  /// no-argument OAuth flow, so the connect sheet calls this directly instead
  /// of the generic [signIn].
  ///
  /// Verifies the settings before saving anything: that the bucket can be
  /// listed *and* written to, so a read-only key fails here with a clear
  /// message instead of "connecting" and then failing the first backup.
  Future<bool> connect({
    required String endpoint,
    required String region,
    required String bucket,
    required String accessKeyId,
    required String secretAccessKey,
    bool pathStyle = true,
    String? folderName,
  }) async {
    final parsedEndpoint = S3Endpoint.tryParse(endpoint);
    if (parsedEndpoint == null) {
      throw _signInFailed(
        'Invalid endpoint. Use a host like s3.example.com — add http:// for a non-TLS server, or :port if needed.',
      );
    }

    final trimmedRegion = region.trim();

    final candidate = S3UserObject(
      endpointHost: parsedEndpoint.host,
      endpointPort: parsedEndpoint.port,
      useSsl: parsedEndpoint.useSsl,
      region: trimmedRegion.isEmpty ? S3UserObject.defaultRegion : trimmedRegion,
      bucket: bucket.trim(),
      accessKeyId: accessKeyId.trim(),
      secretAccessKey: secretAccessKey.trim(),
      pathStyle: pathStyle,
      // Reconnect (rotated keys for the *same* bucket) calls this without
      // signing out first, so `_currentUser` still holds the prior preference —
      // keep it rather than silently re-enabling auto-backup. A fresh connect
      // has no `_currentUser`, so it defaults on.
      autoBackupEnabled: _currentUser?.autoBackupEnabled ?? true,
      folderName: sanitizeFolderName(folderName),
    );

    final s3.Minio client;
    try {
      client = _buildClient(candidate);
    } on s3.MinioError catch (e) {
      throw _signInFailed('Invalid S3 settings: ${e.message}');
    }

    try {
      await _verifyConnection(client, candidate);
    } catch (e) {
      throw _signInFailed('Could not connect to S3: ${describeConnectFailure(e)}');
    }

    _client = client;
    _currentUser = candidate;
    await S3UserStorage().writeObject(candidate);
    return true;
  }

  Future<void> _verifyConnection(s3.Minio client, S3UserObject user) async {
    final root = user.folderName ?? S3UserObject.defaultFolderName;

    // Proves endpoint, region, credentials and bucket in one request.
    await _listOnePage(client, user.bucket, '$root/');

    // Proves write access (and cleans up after itself).
    final probeKey = '$root/.connection-check';
    final probe = Uint8List.fromList(utf8.encode('StoryPad'));
    await client
        .putObject(user.bucket, probeKey, Stream<Uint8List>.value(probe), size: probe.length)
        .timeout(_requestTimeout);

    try {
      await _removeObject(client, user.bucket, probeKey).timeout(_requestTimeout);
    } catch (e) {
      // A create-only key can write but not delete; that must not fail the
      // connection (backups never need to delete to succeed).
      AppLogger.d('S3CloudService#_verifyConnection: could not remove probe object: $e');
    }
  }

  /// A single-object-at-most listing — the cheapest authenticated request.
  Future<void> _listOnePage(s3.Minio client, String bucket, String prefix) {
    return client.listObjectsV2Query(bucket, prefix, null, '/', 1, null).timeout(_requestTimeout);
  }

  /// Generic no-argument sign-in doesn't apply to this service — the connect
  /// sheet calls [connect] with the form values instead.
  @override
  Future<bool> signIn() async => isSignedIn;

  @override
  Future<void> signOut() async {
    await S3UserStorage().remove();
    _currentUser = null;
    _client = null;
  }

  @override
  Future<bool> reauthenticateIfNeeded() async {
    final user = _currentUser;
    final client = _client;
    if (user == null || client == null) {
      throw exp.AuthException(
        'No stored user found',
        exp.AuthExceptionType.signInRequired,
        serviceType: serviceType,
      );
    }

    try {
      await _listOnePage(client, user.bucket, '$_rootFolder/');
      return true;
    } catch (e) {
      // Static keys never refresh, so a confirmed 401/403 means they were
      // revoked or lost permission — but a transient network failure must not
      // be reported as "needs reconnect" (new keys can't fix an outage).
      throw buildException(e, 'reauthenticateIfNeeded');
    }
  }

  @override
  Future<bool> canAccessRequestedScopes() async => isSignedIn;

  @override
  Future<bool> requestScope() async => isSignedIn;

  // ---------------------------------------------------------------------------
  // Backups
  // ---------------------------------------------------------------------------

  @override
  Future<YearlyBackupFilesObject> fetchYearlyBackups() async {
    final files = await _listFolder('backups', methodName: 'fetchYearlyBackups');
    return YearlyBackupFilesObject.fromFiles(files);
  }

  @override
  Future<List<CloudFileObject>> listFilesInFolder(String folderName) {
    return _listFolder(folderName, methodName: 'listFilesInFolder');
  }

  Future<List<CloudFileObject>> _listFolder(String folderName, {required String methodName}) async {
    final (client, bucket) = _authenticated();
    final prefix = '$_rootFolder/$folderName/';

    return _execute(
      methodName: methodName,
      timeout: _bulkTimeout,
      operation: () async {
        // Non-recursive: this is "the files in a folder", not its descendants.
        final objects = await _listObjects(client, bucket, prefix, recursive: false);
        return objects.map(_toCloudFile).toList();
      },
    );
  }

  @override
  Future<(String, int)?> getFileContent(CloudFileObject file) async {
    final (client, bucket) = _authenticated();

    return _execute(
      methodName: 'getFileContent',
      timeout: _bulkTimeout,
      operation: () async {
        final bytes = await _readBytes(client, bucket, file.id);
        if (bytes == null) return null;

        if (file.getFileInfo()?.hasCompression == true) {
          final decoded = io.gzip.decode(bytes);
          return (utf8.decode(decoded), bytes.length);
        }

        return (utf8.decode(bytes), bytes.length);
      },
    );
  }

  @override
  Future<List<int>?> downloadFileBytes(String fileId) async {
    final (client, bucket) = _authenticated();

    return _execute(
      methodName: 'downloadFileBytes',
      timeout: _bulkTimeout,
      // A 404 must NOT be swallowed to null here: this is the raw read
      // backfillFromOtherService uses to source an asset from another connected
      // service, and it needs the miss to surface as a FileOperationException so
      // it can clear the stale cloudDestinations entry (same contract as
      // NextcloudCloudService.downloadFileBytes).
      operation: () => _readBytes(client, bucket, fileId, swallow404: false),
    );
  }

  Future<List<int>?> _readBytes(
    s3.Minio client,
    String bucket,
    String key, {
    bool swallow404 = true,
  }) async {
    try {
      final stream = await client.getObject(bucket, key);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on s3.MinioS3Error catch (e) {
      if (swallow404 && e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<CloudFileObject?> findFileById(String fileId) async {
    final (client, bucket) = _authenticated();

    return _execute(
      methodName: 'findFileById',
      operation: () => _stat(client, bucket, fileId),
    );
  }

  @override
  Future<CloudFileObject?> findFileByIdIncludingTrashed(String fileId) async {
    final (client, bucket) = _authenticated();
    final trashKey = trashKeyFor(rootFolder: _rootFolder, key: fileId);

    return _execute(
      methodName: 'findFileByIdIncludingTrashed',
      operation: () async {
        final direct = await _stat(client, bucket, fileId);
        if (direct != null) return direct;

        return _stat(client, bucket, trashKey, trashed: true);
      },
    );
  }

  /// Null when the object doesn't exist.
  ///
  /// `retrieveAcls: false` matters: the client's default also requests the
  /// object's ACL, which several S3-compatible stores don't implement (so a
  /// plain existence check would fail on them).
  Future<CloudFileObject?> _stat(s3.Minio client, String bucket, String key, {bool trashed = false}) async {
    try {
      final stat = await client.statObject(bucket, key, retrieveAcls: false);
      return CloudFileObject.fromS3(
        key: key,
        sizeInBytes: stat.size,
        lastModified: stat.lastModified,
        trashed: trashed,
      );
    } on s3.MinioS3Error catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<bool> deleteFile(String cloudFileId) async {
    final (client, bucket) = _authenticated();

    return _execute(
      methodName: 'deleteFile',
      operation: () async {
        await _removeObject(client, bucket, cloudFileId);
        return true;
      },
    );
  }

  @override
  Future<bool> trashFile(String cloudFileId) async {
    final (client, bucket) = _authenticated();
    final trashKey = trashKeyFor(rootFolder: _rootFolder, key: cloudFileId);

    return _execute(
      methodName: 'trashFile',
      operation: () async {
        // Copy first, delete second: if the delete fails the file is merely
        // duplicated, never lost. A missing source fails the copy with a 404,
        // which is reported as "not found" (the cloud-optimize screen treats
        // that as already trashed).
        await client.copyObject(bucket, trashKey, copySourceFor(bucket: bucket, key: cloudFileId));
        await _removeObject(client, bucket, cloudFileId);
        return true;
      },
    );
  }

  @override
  Future<bool> restoreFileFromTrash(String cloudFileId) async {
    final (client, bucket) = _authenticated();
    final trashKey = trashKeyFor(rootFolder: _rootFolder, key: cloudFileId);

    return _execute(
      methodName: 'restoreFileFromTrash',
      operation: () async {
        await client.copyObject(bucket, cloudFileId, copySourceFor(bucket: bucket, key: trashKey));
        await _removeObject(client, bucket, trashKey);
        return true;
      },
    );
  }

  @override
  Future<CloudFileObject?> uploadFile(
    String fileName,
    io.File file, {
    String? folderName,
  }) async {
    final (client, bucket) = _authenticated();
    final key = buildKey(rootFolder: _rootFolder, folderName: folderName, fileName: sanitizeFileName(fileName));

    return _execute(
      methodName: 'uploadFile',
      timeout: _bulkTimeout,
      operation: () => _putFile(client, bucket, key, file, fileName: fileName),
    );
  }

  @override
  Future<CloudFileObject?> updateFile({
    required String fileId,
    required String fileName,
    required io.File file,
  }) async {
    final (client, bucket) = _authenticated();
    final parent = parentOf(fileId);
    final safeFileName = sanitizeFileName(fileName);
    final key = parent.isEmpty ? safeFileName : '$parent/$safeFileName';

    return _execute(
      methodName: 'updateFile',
      timeout: _bulkTimeout,
      operation: () async {
        final uploaded = await _putFile(client, bucket, key, file, fileName: fileName);

        // Yearly backup filenames embed a timestamp, so an "update" writes a
        // new key; clean up the old one once the new content has landed.
        if (key != fileId) {
          try {
            await _removeObject(client, bucket, fileId);
          } catch (e) {
            AppLogger.d('S3CloudService#updateFile: failed to remove old file $fileId: $e');
          }
        }

        return uploaded;
      },
    );
  }

  Future<CloudFileObject> _putFile(
    s3.Minio client,
    String bucket,
    String key,
    io.File file, {
    required String fileName,
  }) async {
    if (!file.existsSync()) {
      throw exp.FileOperationException(
        'Local file does not exist: ${file.path}',
        exp.FileOperationType.upload,
        context: fileName,
        serviceType: serviceType,
      );
    }

    final length = await file.length();

    // `size` matters: without it the client assumes a huge object, picks a huge
    // part size and buffers the entire stream before sending anything. With it,
    // files under 64 MB go as one PUT and larger ones as multipart.
    await client.putObject(bucket, key, _openRead(file), size: length);

    return CloudFileObject.fromS3(key: key, sizeInBytes: length, lastModified: DateTime.now().toUtc());
  }

  static Stream<Uint8List> _openRead(io.File file) {
    return file.openRead().map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
  }

  /// Treats any 2xx as success: the client insists on exactly 204 for a delete,
  /// which not every S3-compatible store sends (some answer 200).
  Future<void> _removeObject(s3.Minio client, String bucket, String key) async {
    try {
      await client.removeObject(bucket, key);
    } on s3.MinioS3Error catch (e) {
      final status = e.response?.statusCode;
      if (status != null && status >= 200 && status < 300) return;
      rethrow;
    }
  }

  Future<List<s3.Object>> _listObjects(
    s3.Minio client,
    String bucket,
    String prefix, {
    required bool recursive,
  }) async {
    final objects = <s3.Object>[];

    await for (final page in client.listObjectsV2(bucket, prefix: prefix, recursive: recursive)) {
      for (final object in page.objects) {
        final key = object.key;
        // Some consoles create zero-byte "folder" placeholder objects (`foo/`).
        if (key == null || key.endsWith('/')) continue;
        objects.add(object);
      }
    }

    return objects;
  }

  CloudFileObject _toCloudFile(s3.Object object) {
    return CloudFileObject.fromS3(
      key: object.key!,
      sizeInBytes: object.size,
      lastModified: object.lastModified,
    );
  }

  @override
  Future<CloudStorageQuotaObject?> fetchStorageQuota() async {
    if (_currentUser == null) return null;

    try {
      final (client, bucket) = _authenticated();
      final prefix = '$_rootFolder/';

      final total = await _execute(
        methodName: 'fetchStorageQuota',
        timeout: _bulkTimeout,
        operation: () async {
          final objects = await _listObjects(client, bucket, prefix, recursive: true);
          return objects.fold<int>(0, (sum, object) => sum + (object.size ?? 0));
        },
      );

      // S3 has no account usage or limit to report.
      return CloudStorageQuotaObject(appUsageInBytes: total);
    } catch (e, s) {
      AppLogger.error('S3CloudService#fetchStorageQuota failed: $e', stackTrace: s);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  /// Runs [operation] with a timeout and translates anything it throws into a
  /// [exp.BackupException]. No silent re-auth-and-retry (compare Nextcloud):
  /// static keys have nothing to refresh.
  Future<T> _execute<T>({
    required String methodName,
    required Future<T> Function() operation,
    Duration timeout = _requestTimeout,
  }) async {
    try {
      return await operation().timeout(timeout);
    } catch (e) {
      throw buildException(e, methodName);
    }
  }

  (s3.Minio, String) _authenticated() {
    final client = _client;
    final user = _currentUser;
    if (client == null || user == null) {
      throw exp.AuthException(
        'Failed to get authenticated S3 client',
        exp.AuthExceptionType.signInRequired,
        serviceType: serviceType,
      );
    }
    return (client, user.bucket);
  }

  exp.AuthException _signInFailed(String message) {
    return exp.AuthException(
      message,
      exp.AuthExceptionType.signInFailed,
      context: 'connect',
      serviceType: serviceType,
    );
  }

  /// Error codes that mean "these credentials don't (or no longer) work".
  static const Set<String> _credentialErrorCodes = {
    'InvalidAccessKeyId',
    'SignatureDoesNotMatch',
    'AccessDenied',
    'ExpiredToken',
    'InvalidToken',
    'AllAccessDisabled',
    'AccountProblem',
    'InvalidSecurity',
    'NotSignedUp',
  };

  /// Classifies by HTTP status first and S3 error code second: the client
  /// derives the "code" of a bodiless response (every HEAD error) from the
  /// HTTP reason phrase, so the status is the only reliable signal there.
  @visibleForTesting
  exp.BackupException buildException(Object error, String methodName) {
    if (error is exp.BackupException) return error;

    if (error is s3.MinioS3Error) {
      final status = error.response?.statusCode;
      final code = error.error?.code;

      // A 403 that is the *device's* fault, not the credentials': reconnecting
      // can't fix it, so don't route the user to the reconnect flow.
      if (code == 'RequestTimeTooSkewed') {
        return exp.ServiceException(
          "The device clock is out of sync with the S3 server (during $methodName)",
          exp.ServiceExceptionType.unexpectedError,
          context: methodName,
          serviceType: serviceType,
        );
      }

      if (status == 401 || status == 403 || _credentialErrorCodes.contains(code)) {
        return exp.AuthException(
          'Authentication failed during $methodName',
          exp.AuthExceptionType.tokenRevoked,
          context: methodName,
          serviceType: serviceType,
        );
      }

      if (status == 404) {
        if (code == 'NoSuchBucket') {
          // Deliberately not worded "not found": callers such as the
          // cloud-optimize cleanup read that phrase as "file already gone".
          return exp.FileOperationException(
            'The bucket does not exist ($methodName)',
            exp.FileOperationType.list,
            context: methodName,
            serviceType: serviceType,
            statusCode: 404,
          );
        }

        return exp.FileOperationException(
          'File not found during $methodName',
          _getFileOperationType(methodName),
          context: methodName,
          serviceType: serviceType,
          statusCode: 404,
        );
      }

      if (status == 507) {
        return exp.QuotaException(
          'Storage quota exceeded during $methodName',
          exp.QuotaExceptionType.storageQuotaExceeded,
          context: methodName,
          serviceType: serviceType,
        );
      }

      if (status == 429 || status == 503 || code == 'SlowDown') {
        return exp.QuotaException(
          'Rate limit exceeded during $methodName',
          exp.QuotaExceptionType.rateLimitExceeded,
          context: methodName,
          serviceType: serviceType,
        );
      }

      if (status != null && status >= 500) {
        return exp.NetworkException(
          'S3 server error ($status) during $methodName',
          context: methodName,
          serviceType: serviceType,
        );
      }

      return exp.ServiceException(
        'S3 error during $methodName: ${status ?? '?'} ${code ?? ''} ${error.message ?? ''}'.trim(),
        exp.ServiceExceptionType.unexpectedError,
        context: methodName,
        serviceType: serviceType,
      );
    }

    if (error is TimeoutException ||
        error is io.SocketException ||
        error is io.TlsException ||
        error is http.ClientException) {
      return exp.NetworkException(
        'Network error during $methodName: $error',
        context: methodName,
        serviceType: serviceType,
      );
    }

    return exp.ServiceException(
      'Unknown error during $methodName: $error',
      exp.ServiceExceptionType.unexpectedError,
      context: methodName,
      serviceType: serviceType,
    );
  }

  exp.FileOperationType _getFileOperationType(String methodName) {
    switch (methodName) {
      case 'uploadFile':
      case 'updateFile':
        return exp.FileOperationType.upload;
      case 'deleteFile':
      case 'trashFile':
      case 'restoreFileFromTrash':
        return exp.FileOperationType.delete;
      case 'getFileContent':
      case 'downloadFileBytes':
        return exp.FileOperationType.download;
      default:
        return exp.FileOperationType.list;
    }
  }
}
