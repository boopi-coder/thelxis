import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// `ShellExecuteW(NULL, "runas", file, parameters, NULL, SW_HIDE)` and returns
/// its HINSTANCE-style result (greater than 32 means the process was started).
///
/// The call blocks while the UAC consent dialog is open, so it runs in a
/// short-lived isolate to keep the UI responsive.
Future<int> shellExecuteRunAs(String file, String parameters) =>
    Isolate.run(() => _shellExecuteRunAs(file, parameters));

int _shellExecuteRunAs(String file, String parameters) {
  // Microsoft asks for COM on the calling thread before ShellExecute; a fresh
  // isolate thread has none. S_FALSE (already initialised) also needs the
  // matching CoUninitialize, so only a failed call (negative HRESULT) skips it.
  final com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  final verb = 'runas'.toNativeUtf16();
  final path = file.toNativeUtf16();
  final args = parameters.toNativeUtf16();
  try {
    return ShellExecute(0, verb, path, args, nullptr, 0 /* SW_HIDE */);
  } finally {
    calloc.free(verb);
    calloc.free(path);
    calloc.free(args);
    if (com >= 0) CoUninitialize();
  }
}
