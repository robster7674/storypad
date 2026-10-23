import 'package:storypad/core/objects/s3_user_object.dart';
import 'package:storypad/core/storages/base_object_storages/object_storage.dart';
import 'package:storypad/core/storages/storage_adapters/base_storage_adapter.dart';
import 'package:storypad/core/storages/storage_adapters/secure_storage_adaptor.dart';

/// Holds the S3 access key + secret, so — like the Nextcloud app password and
/// Dropbox tokens — it goes through secure storage, not shared preferences.
class S3UserStorage extends ObjectStorage<S3UserObject> {
  @override
  Future<BaseStorageAdapter<String>> get adapter async => SecureStorageAdaptor();

  @override
  S3UserObject decode(Map<String, dynamic> json) => S3UserObject.fromJson(json);

  @override
  Map<String, dynamic> encode(S3UserObject object) => object.toJson();
}
