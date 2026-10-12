import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../core/log_file.dart';
import 'downloader.dart';
import 'installers/installer.dart';
import 'manifest.dart';
import 'update_dependencies.dart';
import 'update_exception.dart';

const _log = Logger('update');

enum UpdateState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  ready,
  installing,
  manualInstallRequired,
  error,
}

/// Which step an [UpdateService.error] belongs to.
enum UpdatePhase { check, download, install }

/// Over-the-air updates (PROTOCOL.md section 10).
///
/// Flow: check (signed manifest) -> available -> download + verify -> ready ->
/// install. Downloading is allowed any time; *installing* waits until
/// [isBusy] reports no active session. Where the OS shows an elevation prompt
/// (Windows UAC, Linux polkit, Android installer) an automatic update stops at
/// [UpdateState.ready] with [awaitingConfirmation] until the user says
/// "install now".
class UpdateService extends ChangeNotifier {
  UpdateService({
    required this._prefs,
    bool Function()? isBusy,
    Future<UpdateDependencies> Function()? dependencies,
    void Function()? exitApp,
    DateTime Function()? now,
    this.firstCheckDelay = const Duration(seconds: 30),
    this.checkInterval = const Duration(hours: 6),
    this.busyRetryInterval = const Duration(minutes: 1),
    this.exitDelay = const Duration(milliseconds: 600),
    this.handoffGrace = const Duration(seconds: 30),
  })  : _dependencies = dependencies ?? UpdateDependencies.system,
        _exitApp = exitApp ?? _defaultExit,
        _now = now ?? DateTime.now {
    this.isBusy = isBusy ?? () => false;
  }

  static const String keyAutoCheck = 'update.autoCheck';
  static const String keyAutoInstall = 'update.autoInstall';
  static const String keyLastCheck = 'update.lastCheck';
  static const String keySkippedVersion = 'update.skippedVersion';
  static const String keyLastRunVersion = 'update.lastRunVersion';

  /// True while a session is active. Installation (never download) waits for
  /// false. Wire to the session manager; may be replaced after construction.
  late bool Function() isBusy;

  final SharedPreferences _prefs;
  final Future<UpdateDependencies> Function() _dependencies;
  final void Function() _exitApp;
  final DateTime Function() _now;

  final Duration firstCheckDelay;
  final Duration checkInterval;
  final Duration busyRetryInterval;
  final Duration exitDelay;

  /// Android: how long to show "installing" after the system installer opened
  /// before assuming it was cancelled.
  final Duration handoffGrace;

  static void _defaultExit() {
    // "Exiting for update" is the line a failed update report needs most.
    LogFile.instance?.flushSync();
    exit(0);
  }

  UpdateDependencies? _deps;
  UpdateState _state = UpdateState.idle;
  UpdateManifest? _manifest;
  UpdateAsset? _asset;
  DownloadProgress? _progress;
  UpdateException? _error;
  UpdatePhase? _errorPhase;
  ManualInstallReason? _manualReason;
  String? _manualLocation;
  File? _readyFile;
  String? _currentVersion;
  String? _justUpdated;

  bool _started = false;
  bool _disposed = false;
  bool _confirmed = false;
  bool _waitingForIdle = false;
  bool _installing = false;
  bool _exitPending = false;
  Future<void>? _downloadFlow;
  UpdateCancelToken? _cancel;
  Timer? _checkTimer;
  Timer? _busyTimer;
  Timer? _handoffTimer;

  // ---------------------------------------------------------------- state

  UpdateState get state => _state;

  /// `x.y.z` of the running app, once [start] resolved it.
  String? get currentVersion => _currentVersion;

  /// The release on offer (null when up to date, skipped or not yet checked).
  UpdateManifest? get offer => _manifest;
  String? get availableVersion => _manifest?.version.toString();
  Uri? get notesUrl => _manifest?.notesUrl;
  UpdateAsset? get asset => _asset;
  DownloadProgress? get progress => _progress;

  UpdateException? get error => _error;
  UpdatePhase? get errorPhase => _errorPhase;

  ManualInstallReason? get manualReason => _manualReason;

  /// Where the downloaded file is, for [UpdateState.manualInstallRequired].
  String? get manualLocation => _manualLocation;

  /// Downloaded and verified, but installation waits for the end of the
  /// current session.
  bool get waitingForIdle => _waitingForIdle;

  /// Downloaded and verified; the OS will show an elevation prompt, so the
  /// user must choose "install now" ([downloadAndInstall]) first.
  bool get awaitingConfirmation =>
      _state == UpdateState.ready && (_deps?.installer.requiresUserConfirmation ?? false) && !_confirmed;

  /// Set after the app was updated and restarted (the `--updated` flag or a
  /// version bump since the last run). Call [acknowledgeUpdated] once shown.
  String? get justUpdatedVersion => _justUpdated;

  bool get autoCheck => _prefs.getBool(keyAutoCheck) ?? true;
  bool get autoInstall => _prefs.getBool(keyAutoInstall) ?? true;
  String? get skippedVersion => _prefs.getString(keySkippedVersion);

  DateTime? get lastCheck {
    final ms = _prefs.getInt(keyLastCheck);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  // ------------------------------------------------------------ lifecycle

  /// Resolves versions, tidies old downloads and schedules the periodic check
  /// (first one after [firstCheckDelay]). Pass [updatedFlag] when the process
  /// was started with `--updated`.
  Future<void> start({bool updatedFlag = false}) async {
    if (_started || _disposed) return;
    _started = true;
    try {
      final deps = await _resolve();
      final current = deps.currentVersion;
      final last = SemVer.tryParse(_prefs.getString(keyLastRunVersion));
      final now = SemVer.tryParse(current);
      final bumped = last != null && now != null && now.compareCore(last) > 0;
      if (updatedFlag || bumped) {
        _justUpdated = current;
        _log.i('running updated version $current');
      }
      await _prefs.setString(keyLastRunVersion, current);
      unawaited(deps.downloader.cleanup(deps.downloadDir, all: _justUpdated != null));
    } on Object catch (e) {
      _log.w('update service could not initialise', e);
    }
    _scheduleCheck(firstCheckDelay);
    notifyListeners();
  }

  void acknowledgeUpdated() {
    if (_justUpdated == null) return;
    _justUpdated = null;
    notifyListeners();
  }

  /// Call when the last active session ended: a pending installation (or the
  /// pending restart of an installer that already started) proceeds.
  void notifyIdle() {
    if (_exitPending) {
      unawaited(_maybeExit());
    } else if (_waitingForIdle) {
      unawaited(_tryInstall());
    }
  }

  /// Async install/download steps may finish after the owner disposed us.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _checkTimer?.cancel();
    _busyTimer?.cancel();
    _handoffTimer?.cancel();
    _cancel?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- settings

  Future<void> setAutoCheck(bool value) async {
    await _prefs.setBool(keyAutoCheck, value);
    if (!value) {
      _checkTimer?.cancel();
    } else if (_started) {
      _scheduleCheck(firstCheckDelay);
    }
    notifyListeners();
  }

  Future<void> setAutoInstall(bool value) async {
    await _prefs.setBool(keyAutoInstall, value);
    notifyListeners();
    if (value && _state == UpdateState.available) unawaited(_begin(confirmed: false));
  }

  // ------------------------------------------------------------- commands

  /// Checks GitHub now (also when automatic checks are off: the user asked).
  Future<void> checkNow() => _check(userInitiated: true);

  /// The user wants this update: download it (if needed) and install it as soon
  /// as no session is active.
  Future<void> downloadAndInstall() => _begin(confirmed: true);

  /// Stops an in-flight download; the offer stays.
  void cancelDownload() => _cancel?.cancel();

  /// Hides [version] until a newer one appears (a manual check still shows it).
  Future<void> skip(String version) async {
    await _prefs.setString(keySkippedVersion, version);
    if (availableVersion == version) {
      _cancel?.cancel();
      _clearOffer(deleteFile: true);
      _setState(UpdateState.idle);
    } else {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- check

  Future<void> _check({required bool userInitiated}) async {
    if (_disposed) return;
    if (!userInitiated && !autoCheck) return;
    switch (_state) {
      case UpdateState.checking:
      case UpdateState.downloading:
      case UpdateState.verifying:
      case UpdateState.ready:
      case UpdateState.installing:
      case UpdateState.manualInstallRequired:
        return;
      case UpdateState.idle:
      case UpdateState.upToDate:
      case UpdateState.available:
      case UpdateState.error:
        break;
    }
    final before = _state;
    _setState(UpdateState.checking);
    try {
      final deps = await _resolve();
      final manifest = await deps.loader.load();
      await _prefs.setInt(keyLastCheck, _now().millisecondsSinceEpoch);

      final current = SemVer.tryParse(deps.currentVersion);
      if (current == null || !manifest.isNewerThan(current)) {
        _clearOffer(deleteFile: false);
        _setState(UpdateState.upToDate);
        return;
      }
      final version = manifest.version.toString();
      if (skippedVersion == version) {
        if (!userInitiated) {
          _clearOffer(deleteFile: false);
          _setState(UpdateState.idle);
          return;
        }
        await _prefs.remove(keySkippedVersion);
      }
      final asset = manifest.assetFor(deps.target);
      if (asset == null) {
        throw UpdateException(UpdateErrorKind.noAsset, 'release $version has no build for ${deps.target.assetKeys}');
      }
      if (_asset?.sha256 != asset.sha256) {
        // A different build than the one downloaded earlier (newer release).
        _readyFile = null;
        _confirmed = false;
      }
      _manifest = manifest;
      _asset = asset;
      _error = null;
      _errorPhase = null;
      _log.i('update $version available');
      _setState(UpdateState.available);
      if (autoInstall) unawaited(_begin(confirmed: false));
    } on UpdateException catch (e) {
      _fail(UpdatePhase.check, e, previous: before);
    } on Object catch (e) {
      _fail(UpdatePhase.check, UpdateException(UpdateErrorKind.network, 'unexpected: $e', cause: e), previous: before);
    }
  }

  void _scheduleCheck(Duration delay) {
    _checkTimer?.cancel();
    if (_disposed || !autoCheck) return;
    _checkTimer = Timer(delay, () async {
      await _check(userInitiated: false);
      _scheduleCheck(checkInterval);
    });
  }

  // ------------------------------------------------------------- download

  Future<void> _begin({required bool confirmed}) async {
    if (confirmed) _confirmed = true;
    if (_manifest == null || _asset == null) return;
    switch (_state) {
      case UpdateState.ready:
        await _tryInstall();
        return;
      case UpdateState.available:
      case UpdateState.error:
      case UpdateState.manualInstallRequired:
        break;
      case UpdateState.idle:
      case UpdateState.checking:
      case UpdateState.upToDate:
      case UpdateState.downloading:
      case UpdateState.verifying:
      case UpdateState.installing:
        return;
    }
    if (_readyFile != null && await _readyFile!.exists()) {
      _setState(UpdateState.ready);
      await _tryInstall();
      return;
    }
    return _downloadFlow ??= _download().whenComplete(() => _downloadFlow = null);
  }

  Future<void> _download() async {
    final asset = _asset!;
    final token = _cancel = UpdateCancelToken();
    _progress = DownloadProgress(received: 0, total: asset.size);
    _error = null;
    _errorPhase = null;
    _setState(UpdateState.downloading);
    try {
      final deps = await _resolve();
      final file = await deps.downloader.download(
        asset,
        dir: deps.downloadDir,
        cancel: token,
        onProgress: (p) {
          _progress = p;
          if (_state == UpdateState.downloading) notifyListeners();
        },
        onVerifying: () => _setState(UpdateState.verifying),
      );
      if (_manifest == null) {
        // Skipped while downloading: drop the file.
        await _deleteQuietly(file);
        return;
      }
      _readyFile = file;
      _progress = null;
      _setState(UpdateState.ready);
      await _tryInstall();
    } on UpdateException catch (e) {
      if (e.kind == UpdateErrorKind.cancelled) {
        if (_manifest != null) _setState(UpdateState.available);
      } else {
        _fail(UpdatePhase.download, e);
      }
    } on Object catch (e) {
      _fail(UpdatePhase.download, UpdateException(UpdateErrorKind.network, 'unexpected: $e', cause: e));
    } finally {
      if (identical(_cancel, token)) _cancel = null;
    }
  }

  // -------------------------------------------------------------- install

  Future<void> _tryInstall() async {
    if (_installing || _disposed || _state != UpdateState.ready) return;
    final deps = _deps;
    final file = _readyFile;
    final asset = _asset;
    if (deps == null || file == null || asset == null) return;

    if (deps.installer.requiresUserConfirmation && !_confirmed) {
      _stopBusyTimer();
      _waitingForIdle = false;
      notifyListeners();
      return;
    }
    if (isBusy()) {
      _waitForIdle();
      return;
    }

    _installing = true;
    _waitingForIdle = false;
    _stopBusyTimer();
    try {
      _setState(UpdateState.installing);
      // Re-check right before use: the file may have sat on disk for hours.
      await deps.downloader.verifyFile(file, asset, deleteOnFailure: true);
      if (isBusy()) {
        _setState(UpdateState.ready);
        _waitForIdle();
        return;
      }
      _log.i('installing ${_manifest?.version}');
      final result = await deps.installer.install(file, asset);
      switch (result.outcome) {
        case InstallOutcome.restartRequired:
          _exitPending = true;
          unawaited(_maybeExit());
        case InstallOutcome.handedOff:
          _handoffTimer?.cancel();
          _handoffTimer = Timer(handoffGrace, () {
            if (_state == UpdateState.installing) {
              // The system installer was dismissed; offer the button again.
              _confirmed = false;
              _setState(UpdateState.ready);
            }
          });
        case InstallOutcome.manualRequired:
          _manualReason = result.reason;
          _manualLocation = result.location;
          _setState(UpdateState.manualInstallRequired);
      }
    } on UpdateException catch (e) {
      if (e.kind == UpdateErrorKind.hash || e.kind == UpdateErrorKind.size || e.kind == UpdateErrorKind.storage) {
        _readyFile = null;
      }
      _confirmed = false;
      _fail(UpdatePhase.install, e);
    } on Object catch (e) {
      _confirmed = false;
      _fail(UpdatePhase.install, UpdateException(UpdateErrorKind.install, 'unexpected: $e', cause: e));
    } finally {
      _installing = false;
    }
  }

  void _waitForIdle() {
    _waitingForIdle = true;
    _busyTimer ??= Timer.periodic(busyRetryInterval, (_) {
      if (_exitPending) {
        unawaited(_maybeExit());
      } else {
        unawaited(_tryInstall());
      }
    });
    notifyListeners();
  }

  void _stopBusyTimer() {
    _busyTimer?.cancel();
    _busyTimer = null;
  }

  /// The installer/helper is already started and only waits for this process
  /// to exit. Never exit under an active session; wait for it to end.
  Future<void> _maybeExit() async {
    if (!_exitPending || _disposed) return;
    if (isBusy()) {
      _waitForIdle();
      return;
    }
    _exitPending = false;
    _stopBusyTimer();
    _waitingForIdle = false;
    await Future<void>.delayed(exitDelay);
    _log.i('exiting for update');
    _exitApp();
  }

  // -------------------------------------------------------------- helpers

  Future<UpdateDependencies> _resolve() async {
    final existing = _deps;
    if (existing != null) return existing;
    final deps = await _dependencies();
    _deps = deps;
    _currentVersion = deps.currentVersion;
    return deps;
  }

  void _fail(UpdatePhase phase, UpdateException e, {UpdateState? previous}) {
    _log.w('update ${phase.name} failed: ${e.kind.name}', e.detail);
    _error = e;
    _errorPhase = phase;
    _progress = null;
    _waitingForIdle = false;
    _stopBusyTimer();
    if (phase == UpdatePhase.check && previous == UpdateState.available) {
      // A failed re-check must not hide an offer the user can still act on.
      _setState(UpdateState.available);
      return;
    }
    _setState(UpdateState.error);
  }

  void _clearOffer({required bool deleteFile}) {
    final file = _readyFile;
    _manifest = null;
    _asset = null;
    _progress = null;
    _readyFile = null;
    _confirmed = false;
    _waitingForIdle = false;
    _error = null;
    _errorPhase = null;
    _manualReason = null;
    _manualLocation = null;
    _stopBusyTimer();
    if (deleteFile && file != null) unawaited(_deleteQuietly(file));
  }

  void _setState(UpdateState value) {
    _state = value;
    notifyListeners();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing more to do.
    }
  }
}
