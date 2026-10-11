import 'dart:io';

import '../core/log.dart';

const _log = Logger('desktop');

/// Start-at-login on macOS through a per-user LaunchAgent
/// (`~/Library/LaunchAgents/io.thelxis.app.plist`).
///
/// The `launch_at_startup` plugin has no macOS implementation in this build,
/// and a plain plist needs no native code, no entitlement and no helper app.
/// launchd picks the file up at the next login, so nothing is loaded or
/// started now (which would launch a second instance because of RunAtLoad).
class MacLoginItem {
  MacLoginItem({String? homeDir, String? executable})
      : homeDir = homeDir ?? Platform.environment['HOME'] ?? '',
        executable = executable ?? Platform.resolvedExecutable;

  static const String label = 'io.thelxis.app';

  /// Login starts stay in the tray; see `--minimized` in `main.dart`.
  static const List<String> arguments = ['--minimized'];

  final String homeDir;

  /// The app binary the agent launches (the running one by default).
  final String executable;

  File get plistFile => File('$homeDir/Library/LaunchAgents/$label.plist');

  /// Gatekeeper's App Translocation runs a freshly downloaded app from a
  /// randomized read-only path that disappears on quit; an agent pointing
  /// there would never find the app again.
  bool get _isTranslocated => executable.contains('/AppTranslocation/');

  /// The agent definition for [executable].
  String buildPlist() {
    final args = [executable, ...arguments].map((a) => '    <string>${_xmlEscape(a)}</string>').join('\n');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '  <key>Label</key>\n'
        '  <string>$label</string>\n'
        '  <key>ProgramArguments</key>\n'
        '  <array>\n'
        '$args\n'
        '  </array>\n'
        '  <key>RunAtLoad</key>\n'
        '  <true/>\n'
        '  <key>ProcessType</key>\n'
        '  <string>Interactive</string>\n'
        '  <key>LimitLoadToSessionType</key>\n'
        '  <string>Aqua</string>\n'
        '</dict>\n'
        '</plist>\n';
  }

  /// True when the agent exists and launches this very executable.
  Future<bool> isEnabled() async {
    try {
      final file = plistFile;
      if (!await file.exists()) return false;
      return _pointsAtThisApp(await file.readAsString());
    } on Object catch (e) {
      _log.d('reading the login item failed: $e');
      return false;
    }
  }

  /// Makes the agent match [enabled]: written (or rewritten when it points at
  /// a moved or replaced app) or removed. Never throws.
  Future<void> sync(bool enabled) async {
    try {
      if (!enabled) {
        await _remove();
        return;
      }
      if (_isTranslocated) {
        _log.w('not registering start-at-login from a translocated app path');
        return;
      }
      if (homeDir.isEmpty) {
        _log.w('no home directory; start-at-login unavailable');
        return;
      }
      if (await isEnabled()) return;
      await _write();
    } on Object catch (e) {
      _log.w('changing start-at-login failed', e);
    }
  }

  Future<void> enable() => sync(true);
  Future<void> disable() => sync(false);

  bool _pointsAtThisApp(String xml) {
    // The first <string> inside ProgramArguments is the program itself.
    final match = RegExp(r'<key>ProgramArguments</key>\s*<array>\s*<string>(.*?)</string>', dotAll: true).firstMatch(xml);
    if (match == null) return false;
    return _xmlUnescape(match.group(1)!) == executable;
  }

  Future<void> _write() async {
    final file = plistFile;
    await file.parent.create(recursive: true);
    // Rename is atomic: launchd never reads a half-written file.
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(buildPlist(), flush: true);
    await temp.rename(file.path);
  }

  Future<void> _remove() async {
    final file = plistFile;
    if (await file.exists()) await file.delete();
  }
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
