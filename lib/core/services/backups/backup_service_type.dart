// ignore_for_file: constant_identifier_names

import 'package:flutter/material.dart';
import 'package:storypad/widgets/sp_icons.dart';

enum BackupServiceType {
  google_drive(id: 'google_drive', displayName: 'Google Drive', hasGlobalUserId: true),
  // CloudKit's fetchUserRecordID gives a real, stable per-account identifier
  // — aliased into RevenueCat identity same as Drive/Nextcloud. See
  // ICloudUserObject.globalId.
  icloud(id: 'icloud', displayName: 'iCloud', hasGlobalUserId: true),
  // Dropbox's account_id (from /2/users/get_current_account) is a real,
  // stable, cross-device identity — same aliasing scheme as Drive/iCloud.
  // See DropboxUserObject.globalId.
  dropbox(id: 'dropbox', displayName: 'Dropbox', hasGlobalUserId: true),
  nextcloud(id: 'nextcloud', displayName: 'Nextcloud', hasGlobalUserId: true),
  // An S3 access key identifies a credential, not a person, so unlike the
  // account-based services above it can't be aliased into RevenueCat identity
  // (see S3UserObject.globalId).
  s3(id: 's3', displayName: 'S3', hasGlobalUserId: false);

  final String id;
  final String displayName;
  final bool hasGlobalUserId;

  bool get googleDrive => this == google_drive;
  bool get icloudService => this == icloud;
  bool get dropboxService => this == dropbox;
  bool get nextcloudService => this == nextcloud;
  bool get s3Service => this == s3;

  /// Only Google Drive syncs for free — Nextcloud, iCloud, Dropbox and S3 require Pro.
  bool get isProOnly => this != google_drive;

  const BackupServiceType({
    required this.id,
    required this.displayName,
    required this.hasGlobalUserId,
  });

  /// Get the icon for this service type
  ///
  /// Returns the appropriate IconData for display in UI.
  IconData get icon {
    switch (this) {
      case BackupServiceType.google_drive:
        return SpIcons.googleDrive;
      case BackupServiceType.nextcloud:
        return SpIcons.nextcloud;
      case BackupServiceType.icloud:
        return SpIcons.icloud;
      case BackupServiceType.dropbox:
        return SpIcons.dropbox;
      case BackupServiceType.s3:
        return SpIcons.s3;
    }
  }
}
