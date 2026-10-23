import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:storypad/core/constants/app_constants.dart' show kIsCupertino;
import 'package:storypad/core/objects/s3_endpoint.dart';
import 'package:storypad/core/objects/s3_user_object.dart';
import 'package:storypad/core/services/backups/s3_cloud_service.dart';
import 'package:storypad/providers/backup_provider.dart';
import 'package:storypad/widgets/bottom_sheets/base_bottom_sheet.dart';
import 'package:storypad/widgets/sp_icons.dart';

/// Connect form for an S3-compatible bucket.
///
/// With [existing] set (a reconnect after the stored keys stopped working) the
/// location fields are fixed — only the access key and secret are asked for —
/// so re-submitting can't silently point the account at a different bucket and
/// leave stale import history / asset bookkeeping behind.
class SpConnectS3Sheet extends BaseBottomSheet {
  const SpConnectS3Sheet({this.existing});

  final S3UserObject? existing;

  @override
  bool get fullScreen => false;

  @override
  Widget build(BuildContext context, double bottomPadding) {
    return _ConnectS3Form(
      bottomPadding: bottomPadding,
      existing: existing,
    );
  }
}

class _ConnectS3Form extends StatefulWidget {
  const _ConnectS3Form({
    required this.bottomPadding,
    required this.existing,
  });

  final double bottomPadding;
  final S3UserObject? existing;

  @override
  State<_ConnectS3Form> createState() => _ConnectS3FormState();
}

class _ConnectS3FormState extends State<_ConnectS3Form> {
  final _formKey = GlobalKey<FormState>();

  late final bool _isReconnect = widget.existing != null;

  late final _endpointController = TextEditingController(
    text: widget.existing == null
        ? null
        : '${widget.existing!.useSsl ? 'https' : 'http'}://${widget.existing!.endpointAuthority}',
  );
  late final _regionController = TextEditingController(text: widget.existing?.region);
  late final _bucketController = TextEditingController(text: widget.existing?.bucket);
  late final _accessKeyIdController = TextEditingController(text: widget.existing?.accessKeyId);
  final _secretAccessKeyController = TextEditingController();
  late final _folderNameController = TextEditingController(
    text: widget.existing?.folderName ?? S3UserObject.defaultFolderName,
  );

  late bool _pathStyle = widget.existing?.pathStyle ?? true;

  bool _connecting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _endpointController.dispose();
    _regionController.dispose();
    _bucketController.dispose();
    _accessKeyIdController.dispose();
    _secretAccessKeyController.dispose();
    _folderNameController.dispose();
    super.dispose();
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) return tr("general.required");
    return null;
  }

  String? _endpointValidator(String? value) {
    final required = _requiredValidator(value);
    if (required != null) return required;

    return S3Endpoint.tryParse(value) == null ? tr("input.message.invalid") : null;
  }

  Future<void> _connect() async {
    if (_formKey.currentState?.validate() != true) return;

    setState(() {
      _connecting = true;
      _errorMessage = null;
    });

    final success = await context.read<BackupProvider>().connectS3(
      context,
      endpoint: _endpointController.text.trim(),
      region: _regionController.text.trim(),
      bucket: _bucketController.text.trim(),
      accessKeyId: _accessKeyIdController.text.trim(),
      secretAccessKey: _secretAccessKeyController.text.trim(),
      pathStyle: _pathStyle,
      folderName: _isReconnect ? widget.existing!.folderName : _folderNameController.text.trim(),
    );

    if (!mounted) return;

    if (success) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _connecting = false;
        _errorMessage = tr("dialog.connect_s3.failed");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 12.0,
          children: [
            Text(
              tr(_isReconnect ? "dialog.connect_s3.reconnect_title" : "dialog.connect_s3.title"),
              style: TextTheme.of(context).titleLarge?.copyWith(color: ColorScheme.of(context).primary),
            ),
            Text(
              tr(_isReconnect ? "dialog.connect_s3.reconnect_message" : "dialog.connect_s3.message"),
              style: TextTheme.of(context).bodyLarge,
            ),
            _buildField(
              controller: _endpointController,
              hint: tr("input.s3_endpoint.hint"),
              helper: _isReconnect ? null : tr("input.s3_endpoint.helper"),
              keyboardType: TextInputType.url,
              validator: _endpointValidator,
              // Reconnect only replaces the keys for the same bucket.
              enabled: !_isReconnect,
            ),
            _buildField(
              controller: _regionController,
              hint: tr("input.s3_region.hint"),
              helper: _isReconnect ? null : tr("input.s3_region.helper"),
              validator: null,
              enabled: !_isReconnect,
            ),
            _buildField(
              controller: _bucketController,
              hint: tr("input.s3_bucket.hint"),
              validator: _requiredValidator,
              enabled: !_isReconnect,
            ),
            _buildField(
              controller: _accessKeyIdController,
              hint: tr("input.s3_access_key_id.hint"),
              validator: _requiredValidator,
              autofocus: _isReconnect,
            ),
            _buildField(
              controller: _secretAccessKeyController,
              hint: tr("input.s3_secret_access_key.hint"),
              validator: _requiredValidator,
              obscureText: true,
            ),
            if (!_isReconnect) _buildFolderNameField(context),
            if (!_isReconnect)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(tr("input.s3_path_style.title")),
                subtitle: Text(tr("input.s3_path_style.subtitle")),
                value: _pathStyle,
                onChanged: _connecting ? null : (value) => setState(() => _pathStyle = value),
              ),
            if (_errorMessage != null)
              Text(
                _errorMessage!,
                style: TextTheme.of(context).bodySmall?.copyWith(color: ColorScheme.of(context).error),
              ),
            const SizedBox(height: 4.0),
            SizedBox(width: double.infinity, child: _buildConnectButton(context)),
            SizedBox(height: widget.bottomPadding),
          ],
        ),
      ),
    );
  }

  /// Optional, pre-filled with the default, with a live preview of the
  /// effective prefix — which also shows when [S3CloudService.sanitizeFolderName]
  /// rewrites what was typed (stray slashes, `..`, `+`).
  Widget _buildFolderNameField(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _folderNameController,
      builder: (context, value, _) {
        final effective = S3CloudService.sanitizeFolderName(value.text) ?? S3UserObject.defaultFolderName;

        return _buildField(
          controller: _folderNameController,
          hint: tr("input.s3_folder_name.hint"),
          helper: tr("input.s3_folder_name.helper", namedArgs: {'SP_PATH': effective}),
          validator: null,
        );
      },
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required String? Function(String?)? validator,
    String? helper,
    TextInputType keyboardType = TextInputType.text,
    bool obscureText = false,
    bool autofocus = false,
    bool enabled = true,
  }) {
    if (kIsCupertino) {
      return FormField<String>(
        // Without this, a pre-filled field the user never types into stays
        // null internally, so validate() rejects it as empty even though the
        // CupertinoTextField clearly shows text.
        initialValue: controller.text,
        validator: validator,
        builder: (state) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4.0,
            children: [
              CupertinoTextField(
                controller: controller,
                placeholder: hint,
                keyboardType: keyboardType,
                obscureText: obscureText,
                autocorrect: false,
                enableSuggestions: !obscureText,
                autofocus: autofocus,
                enabled: enabled,
                onChanged: (value) => state.didChange(value),
              ),
              if (helper != null && !state.hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    helper,
                    style: TextTheme.of(context).bodySmall?.copyWith(color: ColorScheme.of(context).outline),
                  ),
                ),
              // Material's TextFormField shows this through its decoration;
              // Cupertino has no equivalent, so without it a failed validation
              // would block submission with zero visible feedback.
              if (state.hasError)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    state.errorText!,
                    style: TextTheme.of(context).bodySmall?.copyWith(color: ColorScheme.of(context).error),
                  ),
                ),
            ],
          );
        },
      );
    }

    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      obscureText: obscureText,
      autocorrect: false,
      enableSuggestions: !obscureText,
      autofocus: autofocus,
      enabled: enabled,
      decoration: InputDecoration(hintText: hint, helperText: helper, helperMaxLines: 3),
    );
  }

  Widget _buildConnectButton(BuildContext context) {
    if (kIsCupertino) {
      return CupertinoButton.filled(
        sizeStyle: CupertinoButtonSize.medium,
        onPressed: _connecting ? null : _connect,
        child: _connecting
            ? const CupertinoActivityIndicator()
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                spacing: 8.0,
                children: [
                  const Icon(SpIcons.s3),
                  Text(tr(_isReconnect ? "button.reconnect" : "button.connect")),
                ],
              ),
      );
    }

    return FilledButton.icon(
      icon: _connecting
          ? const SizedBox.square(dimension: 16.0, child: CircularProgressIndicator.adaptive())
          : const Icon(SpIcons.s3),
      label: Text(tr(_isReconnect ? "button.reconnect" : "button.connect")),
      onPressed: _connecting ? null : _connect,
    );
  }
}
