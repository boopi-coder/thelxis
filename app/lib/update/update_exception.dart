/// Why an update step failed. The UI maps each kind to a localized message;
/// [UpdateException.detail] is for logs only and never contains secrets.
enum UpdateErrorKind {
  /// DNS, connection, TLS, timeout or a dropped stream.
  network,

  /// The server answered with an unexpected HTTP status.
  http,

  /// `update.json.sig` could not be fetched.
  signatureMissing,

  /// The manifest signature does not verify against the embedded key.
  signatureInvalid,

  /// The (correctly signed) manifest is malformed or too large.
  manifest,

  /// The manifest has no build for this platform / ABI / install type.
  noAsset,

  /// Downloaded size differs from the manifest.
  size,

  /// Downloaded SHA-256 differs from the manifest.
  hash,

  /// Disk full or the update directory is not writable.
  storage,

  /// The platform installer could not be started or failed.
  install,

  /// The user declined the elevation prompt (UAC / polkit).
  elevationDenied,

  /// The operation was cancelled by the user.
  cancelled,
}

class UpdateException implements Exception {
  const UpdateException(this.kind, this.detail, {this.status, this.cause});

  final UpdateErrorKind kind;
  final String detail;

  /// HTTP status for [UpdateErrorKind.http].
  final int? status;
  final Object? cause;

  @override
  String toString() => 'UpdateException(${kind.name}): $detail';
}

/// Cooperative cancellation for downloads. Cancelling aborts in-flight HTTP
/// requests through the registered callbacks.
class UpdateCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final l in listeners) {
      l();
    }
  }

  /// Registers [callback] to run on cancellation (immediately when already
  /// cancelled). Returns a function that unregisters it.
  void Function() onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const UpdateException(UpdateErrorKind.cancelled, 'cancelled');
    }
  }
}
