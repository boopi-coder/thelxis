// Finding the router's LAN address for NAT-PMP / PCP (and as a hint for UPnP).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/log.dart';
import 'interfaces.dart';

const Logger _log = Logger('gateway');

/// Runs [executable] and returns stdout, or null on failure/timeout. Injected
/// in tests.
typedef CommandRunner = Future<String?> Function(
  String executable,
  List<String> arguments,
);

Future<String?> runCommand(String executable, List<String> arguments) async {
  Process process;
  try {
    process = await Process.start(executable, arguments);
  } on Object {
    return null;
  }
  final stdout = process.stdout.transform(utf8.decoder).join();
  process.stderr.drain<void>().catchError((Object _) {});
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 3));
    final text = await stdout.timeout(const Duration(seconds: 1));
    return code == 0 ? text : null;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return null;
  }
}

/// macOS: `route -n get default` -> "    gateway: 192.168.1.1".
List<InternetAddress> parseMacDefaultGateway(String output) {
  final result = <InternetAddress>[];
  for (final line in const LineSplitter().convert(output)) {
    final m = RegExp(r'^\s*gateway:\s*(\S+)').firstMatch(line);
    final a = tryParseIpv4(m?.group(1));
    if (a != null) result.add(a);
  }
  return result;
}

/// Linux: `ip route show default` -> "default via 192.168.1.1 dev eth0 ...".
List<InternetAddress> parseLinuxDefaultGateways(String output) {
  final result = <InternetAddress>[];
  for (final line in const LineSplitter().convert(output)) {
    final m = RegExp(r'^\s*default\s+via\s+(\S+)').firstMatch(line);
    final a = tryParseIpv4(m?.group(1));
    if (a != null) result.add(a);
  }
  return result;
}

/// Linux/Android without `ip`: /proc/net/route lists gateways as little-endian
/// hex ("0101A8C0" = 192.168.1.1) on the line whose destination is 00000000.
List<InternetAddress> parseProcNetRoute(String content) {
  final result = <InternetAddress>[];
  for (final line in const LineSplitter().convert(content).skip(1)) {
    final cols = line.trim().split(RegExp(r'\s+'));
    if (cols.length < 3 || cols[1] != '00000000') continue;
    final value = int.tryParse(cols[2], radix: 16);
    if (value == null || value == 0) continue;
    result.add(
      InternetAddress.fromRawAddress(
        Uint8List.fromList([
          value & 0xff,
          (value >> 8) & 0xff,
          (value >> 16) & 0xff,
          (value >> 24) & 0xff,
        ]),
      ),
    );
  }
  return result;
}

/// Windows: `route print 0.0.0.0`, rows of destination, mask, gateway,
/// interface and metric ("0.0.0.0 0.0.0.0 192.168.1.1 192.168.1.50 25").
/// Lowest metric first.
List<InternetAddress> parseWindowsDefaultGateways(String output) {
  final rows = <({InternetAddress gateway, int metric})>[];
  final row = RegExp(
    r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)\s+(\S+)\s+(\d+)',
    multiLine: true,
  );
  for (final m in row.allMatches(output)) {
    final a = tryParseIpv4(m.group(1));
    if (a != null) rows.add((gateway: a, metric: int.parse(m.group(3)!)));
  }
  rows.sort((a, b) => a.metric.compareTo(b.metric));
  return [for (final r in rows) r.gateway];
}

/// ".1" of every private /24 we sit in: the last resort when the route table
/// cannot be read (sandboxed Android, missing tools).
List<InternetAddress> guessGateways(Iterable<InternetAddress> locals) {
  final result = <InternetAddress>[];
  for (final l in locals) {
    final raw = l.rawAddress;
    if (raw.length != 4 || classifyIpv4Bytes(raw) != Ipv4Kind.private) continue;
    final guess = InternetAddress.fromRawAddress(
      Uint8List.fromList([raw[0], raw[1], raw[2], 1]),
    );
    if (guess != l) result.add(guess);
  }
  return result;
}

/// Reads the OS default route(s). Desktop and Linux-based Android only; any
/// failure yields an empty list.
Future<List<InternetAddress>> readOsDefaultGateways({
  CommandRunner run = runCommand,
  Future<String?> Function(String path)? readFile,
  String? platform,
}) async {
  final os = platform ?? Platform.operatingSystem;
  try {
    if (os == 'macos') {
      final out = await run('/sbin/route', ['-n', 'get', 'default']);
      return out == null ? const [] : parseMacDefaultGateway(out);
    }
    if (os == 'windows') {
      final out = await run('route', ['print', '0.0.0.0']);
      return out == null ? const [] : parseWindowsDefaultGateways(out);
    }
    if (os == 'linux' || os == 'android') {
      for (final exe in const [
        'ip',
        '/sbin/ip',
        '/usr/sbin/ip',
        '/system/bin/ip',
      ]) {
        final out = await run(exe, ['route', 'show', 'default']);
        if (out != null) {
          final parsed = parseLinuxDefaultGateways(out);
          if (parsed.isNotEmpty) return parsed;
        }
      }
      final content = await (readFile ?? _readProcRoute)('/proc/net/route');
      return content == null ? const [] : parseProcNetRoute(content);
    }
  } on Object catch (e) {
    _log.d('default route lookup failed: $e');
  }
  return const [];
}

Future<String?> _readProcRoute(String path) async {
  try {
    return await File(path).readAsString();
  } on Object {
    return null;
  }
}
