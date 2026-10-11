import 'dart:io';

/// A log-safe description of [error]: type and OS error code only.
/// `FileSystemException.toString()` embeds the full path, which must not end
/// up in logs.
String errorTag(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    return '${error.runtimeType}${code == null ? '' : ' os=$code'}';
  }
  return error.runtimeType.toString();
}
