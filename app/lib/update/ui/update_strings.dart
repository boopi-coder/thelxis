import 'package:flutter/widgets.dart';

import '../installers/installer.dart';
import '../update_exception.dart';

/// Russian and English texts of the update UI. Russian is used for `ru`
/// locales, English for everything else (same rule as the rest of the app).
class UpdateStrings {
  const UpdateStrings._(this.ru);

  const UpdateStrings.english() : ru = false;

  factory UpdateStrings.of(BuildContext context) =>
      UpdateStrings._(Localizations.maybeLocaleOf(context)?.languageCode == 'ru');

  final bool ru;

  String _t(String en, String ru) => this.ru ? ru : en;

  // ------------------------------------------------------------- banner

  String availableTitle(String version) =>
      _t('Version $version is available', 'Доступна версия $version');
  String get availableSubtitle => _t(
        'Signed by the Thelxis release key.',
        'Подписано ключом выпуска Thelxis.',
      );
  String get update => _t('Update', 'Обновить');
  String get dismiss => _t('Dismiss', 'Скрыть');
  String get skip => _t('Skip', 'Пропустить');
  String get whatsNew => _t("What's new", 'Что нового');
  String get cancel => _t('Cancel', 'Отмена');
  String get retry => _t('Try again', 'Повторить');
  String get continueInstall => _t('Continue', 'Продолжить');
  String get installNow => _t('Install now', 'Установить сейчас');

  String downloadingTitle(String version) =>
      _t('Downloading version $version', 'Загрузка версии $version');
  String downloadProgress(int received, int total, double bytesPerSecond) {
    final base = _t(
      '${megabytes(received)} of ${megabytes(total)} MB',
      '${megabytes(received)} из ${megabytes(total)} МБ',
    );
    if (bytesPerSecond < 1024) return base;
    return '$base · ${megabytes(bytesPerSecond.round())} ${_t('MB/s', 'МБ/с')}';
  }

  String get verifying => _t('Verifying integrity…', 'Проверка целостности…');

  String readyTitle(String version) =>
      _t('Version $version is ready to install', 'Версия $version готова к установке');
  String get readyConfirm => _t(
        'The system will ask you to confirm the installation.',
        'Система попросит подтвердить установку.',
      );
  String get readyWaiting => _t(
        'Will install after the session ends',
        'Установится после завершения сессии',
      );
  String get readyPreparing => _t('Preparing the installation…', 'Подготовка к установке…');

  String installingTitle(String version) =>
      _t('Installing version $version', 'Установка версии $version');
  String get installing => _t(
        'Installing… the app will restart',
        'Установка… приложение перезапустится',
      );

  String get manualTitle => _t('Finish the installation', 'Завершите установку');
  String manualReason(ManualInstallReason? reason, String? location) {
    final where = location == null ? '' : '\n$location';
    switch (reason) {
      case ManualInstallReason.installPermission:
        return _t(
          'Allow installing apps from Thelxis in the settings that just opened, then come back and press Continue.',
          'Разрешите Thelxis устанавливать приложения в открывшихся настройках, затем вернитесь и нажмите «Продолжить».',
        );
      case ManualInstallReason.notWritable:
        return _t(
          'Thelxis has no permission to replace itself. The downloaded file was opened for a manual install.$where',
          'У Thelxis нет прав заменить себя. Скачанный файл открыт для ручной установки.$where',
        );
      case ManualInstallReason.noPolkit:
        return _t(
          'Administrator rights are unavailable (pkexec is missing). Install the downloaded package manually.$where',
          'Права администратора недоступны (нет pkexec). Установите скачанный пакет вручную.$where',
        );
      case null:
        return _t('Install the downloaded file manually.$where', 'Установите скачанный файл вручную.$where');
    }
  }

  String get failedTitle => _t('Update failed', 'Не удалось обновиться');

  String errorMessage(UpdateErrorKind kind) {
    switch (kind) {
      case UpdateErrorKind.network:
        return _t(
          'Could not reach GitHub. Check your connection.',
          'Не удалось связаться с GitHub. Проверьте подключение.',
        );
      case UpdateErrorKind.http:
        return _t('GitHub returned an error.', 'GitHub вернул ошибку.');
      case UpdateErrorKind.signatureMissing:
        return _t(
          'The release has no signature, so it was rejected.',
          'У выпуска нет подписи, поэтому он отклонён.',
        );
      case UpdateErrorKind.signatureInvalid:
        return _t(
          'The update signature is invalid, so it was rejected.',
          'Подпись обновления недействительна, поэтому оно отклонено.',
        );
      case UpdateErrorKind.manifest:
        return _t('The update information is malformed.', 'Данные об обновлении повреждены.');
      case UpdateErrorKind.noAsset:
        return _t(
          'This release has no build for this device.',
          'В этом выпуске нет сборки для этого устройства.',
        );
      case UpdateErrorKind.size:
      case UpdateErrorKind.hash:
        return _t(
          'The downloaded file failed the integrity check and was deleted.',
          'Скачанный файл не прошёл проверку целостности и удалён.',
        );
      case UpdateErrorKind.storage:
        return _t(
          'Could not save the update. Check the free disk space.',
          'Не удалось сохранить обновление. Проверьте свободное место.',
        );
      case UpdateErrorKind.install:
        return _t('The update could not be installed.', 'Не удалось установить обновление.');
      case UpdateErrorKind.elevationDenied:
        return _t('The installation was cancelled.', 'Установка отменена.');
      case UpdateErrorKind.cancelled:
        return _t('Cancelled.', 'Отменено.');
    }
  }

  // ----------------------------------------------------------- settings

  String get updatesTitle => _t('Updates', 'Обновления');
  String version(String? value) => _t('Version ${value ?? '—'}', 'Версия ${value ?? '—'}');
  String get checkNow => _t('Check now', 'Проверить');
  String get checking => _t('Checking…', 'Проверка…');
  String get statusNeverChecked => _t('Not checked yet', 'Ещё не проверялось');
  String get statusUpToDate => _t('You have the latest version', 'Установлена последняя версия');
  String statusAvailable(String version) =>
      _t('Version $version is available', 'Доступна версия $version');
  String statusSkipped(String version) =>
      _t('Version $version was skipped', 'Версия $version пропущена');
  String checkedAt(DateTime? time, {DateTime? now}) {
    if (time == null) return statusNeverChecked;
    return _t('Checked ${_ago(time, now, en: true)}', 'Проверено ${_ago(time, now, en: false)}');
  }

  String get autoCheckTitle => _t('Check for updates automatically', 'Проверять обновления автоматически');
  String get autoCheckSubtitle => _t(
        'Every 6 hours, from GitHub only. When off, Thelxis never contacts anything for updates.',
        'Раз в 6 часов и только на GitHub. Если выключено, Thelxis никуда не обращается за обновлениями.',
      );
  String get autoInstallTitle => _t('Install automatically', 'Устанавливать автоматически');
  String get autoInstallSubtitle => _t(
        'Downloads in the background and installs when no session is active.',
        'Загружает в фоне и устанавливает, когда нет активных сессий.',
      );
  String get releaseNotes => _t('Release notes', 'Заметки о выпуске');
  String get releaseNotesSubtitle => _t('Opens GitHub', 'Откроется GitHub');

  // -------------------------------------------------------------- toast

  String updatedTo(String version) =>
      _t('Thelxis was updated to version $version', 'Thelxis обновлён до версии $version');

  // ------------------------------------------------------------ helpers

  /// `12.3` for 12 898 304 bytes (decimal comma in Russian).
  String megabytes(int bytes) {
    final text = (bytes / (1024 * 1024)).toStringAsFixed(1);
    return ru ? text.replaceFirst('.', ',') : text;
  }

  String _ago(DateTime time, DateTime? now, {required bool en}) {
    final diff = (now ?? DateTime.now()).difference(time);
    if (diff.inSeconds < 45) return en ? 'just now' : 'только что';
    if (diff.inMinutes < 60) {
      return en ? '${diff.inMinutes} min ago' : '${diff.inMinutes} мин назад';
    }
    if (diff.inHours < 24) return en ? '${diff.inHours} h ago' : '${diff.inHours} ч назад';
    return en ? '${diff.inDays} d ago' : '${diff.inDays} д назад';
  }
}
