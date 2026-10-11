import 'package:flutter/widgets.dart';

import '../remote_fs.dart';
import '../transfer.dart';

/// All user-facing text of the file-transfer UI, Russian and English.
///
/// Deliberately self-contained so the module can ship before the app's own
/// l10n exists; the core will migrate these into its ARB files. Russian is
/// used for `ru` locales, English for everything else.
class FilesStrings {
  const FilesStrings._(this.ru);

  factory FilesStrings.of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'ru' ? ru_ : en_;

  /// Resolves by language code, for code without a [BuildContext].
  factory FilesStrings.forLanguage(String languageCode) => languageCode == 'ru' ? ru_ : en_;

  static const FilesStrings en_ = FilesStrings._(false);
  static const FilesStrings ru_ = FilesStrings._(true);

  final bool ru;

  String _t(String en, String ruText) => ru ? ruText : en;

  // --- panel -----------------------------------------------------------------
  String get panelTitle => _t('Files', 'Файлы');
  String get tabTransfers => _t('Transfers', 'Передачи');
  String get tabRemote => _t('Remote files', 'Файлы устройства');
  String get close => _t('Close', 'Закрыть');

  // --- transfers tab ---------------------------------------------------------
  String get emptyTransfersTitle => _t('No transfers yet', 'Передач пока нет');
  String get emptyTransfersHint => _t(
        'Drop files onto the screen or press Send to share them with the other device.',
        'Перетащите файлы на экран или нажмите «Отправить», чтобы передать их на другое устройство.',
      );
  String get emptyTransfersHintViewer => _t(
        'Drop files onto the screen, press Send, or pick files in Remote files to download them.',
        'Перетащите файлы на экран, нажмите «Отправить» или выберите файлы во вкладке «Файлы устройства».',
      );
  String get send => _t('Send', 'Отправить');
  String get sendFiles => _t('Send files…', 'Отправить файлы…');
  String get sendFolder => _t('Send folder…', 'Отправить папку…');
  String get clearFinished => _t('Clear finished', 'Очистить завершённые');
  String get cancel => _t('Cancel', 'Отменить');
  String get showInFolder => _t('Show in folder', 'Показать в папке');
  String get couldNotOpenFolder => _t('Could not open the folder', 'Не удалось открыть папку');
  String get sectionActive => _t('In progress', 'Выполняются');
  String get sectionFinished => _t('Finished', 'Завершены');

  String statusLabel(Transfer t) {
    switch (t.status) {
      case TransferStatus.queued:
        return _t('Waiting in queue', 'В очереди');
      case TransferStatus.waiting:
        return t.isSend
            ? _t('Waiting for the other side…', 'Ожидание ответа…')
            : _t('Requesting…', 'Запрос файла…');
      case TransferStatus.active:
        return t.isSend ? _t('Sending', 'Отправка') : _t('Receiving', 'Получение');
      case TransferStatus.verifying:
        return _t('Verifying…', 'Проверка целостности…');
      case TransferStatus.completed:
        return t.isSend ? _t('Sent', 'Отправлено') : _t('Received', 'Получено');
      case TransferStatus.cancelled:
        return t.endedByPeer
            ? _t('Cancelled by the other side', 'Отменено другой стороной')
            : _t('Cancelled', 'Отменено');
      case TransferStatus.failed:
        return errorLabel(t.error);
    }
  }

  String errorLabel(TransferError? e) {
    switch (e) {
      case TransferError.denied:
        return _t('Not allowed', 'Не разрешено');
      case TransferError.exists:
        return _t('File already exists', 'Файл уже существует');
      case TransferError.noSpace:
        return _t('Not enough disk space', 'Недостаточно места на диске');
      case TransferError.hash:
        return _t('Checksum mismatch — file discarded', 'Контрольная сумма не совпала — файл удалён');
      case TransferError.unsafeName:
        return _t('Unsafe file name refused', 'Небезопасное имя файла отклонено');
      case TransferError.notFound:
        return _t('File not found', 'Файл не найден');
      case TransferError.timeout:
        return _t('No response from the other side', 'Нет ответа от другой стороны');
      case TransferError.closed:
        return _t('Connection lost', 'Соединение потеряно');
      case TransferError.protocol:
        return _t('Protocol error', 'Ошибка протокола');
      case TransferError.io:
      case null:
        return _t('File error', 'Ошибка файла');
    }
  }

  String activeCount(int n) => ru
      ? _plural(n, 'активная передача', 'активные передачи', 'активных передач', prefix: '$n ')
      : '$n active';

  // --- remote files tab ------------------------------------------------------
  String get places => _t('Places', 'Места');
  String get up => _t('Up', 'Вверх');
  String get refresh => _t('Refresh', 'Обновить');
  String get showHidden => _t('Show hidden files', 'Показывать скрытые файлы');
  String get hideHidden => _t('Hide hidden files', 'Скрыть скрытые файлы');
  String get uploadHere => _t('Upload here', 'Загрузить сюда');
  String get uploadFiles => _t('Files…', 'Файлы…');
  String get uploadFolder => _t('Folder…', 'Папка…');
  String get clearSelection => _t('Clear selection', 'Снять выделение');
  String get emptyFolder => _t('This folder is empty', 'Папка пуста');
  String get emptyFolderHidden => _t('Only hidden files here', 'Здесь только скрытые файлы');
  String get tryAgain => _t('Try again', 'Повторить');
  String get openFolder => _t('Open folder', 'Открыть папку');
  String get loadingFolder => _t('Loading…', 'Загрузка…');
  String get itemsTruncated => _t('Showing the first items only', 'Показаны только первые элементы');

  String download(int n) => n <= 1 ? _t('Download', 'Скачать') : _t('Download ($n)', 'Скачать ($n)');
  String selected(int n) => ru ? 'Выбрано: $n' : '$n selected';
  String itemsCount(int n) => ru
      ? _plural(n, 'элемент', 'элемента', 'элементов', prefix: '$n ')
      : (n == 1 ? '1 item' : '$n items');
  String queuedDownloads(int n) => ru
      ? _plural(n, 'загрузка добавлена в очередь', 'загрузки добавлены в очередь', 'загрузок добавлено в очередь', prefix: '$n ')
      : (n == 1 ? '1 download queued' : '$n downloads queued');

  String remoteError(RemoteFsErrorKind kind) {
    switch (kind) {
      case RemoteFsErrorKind.notFound:
        return _t('This folder no longer exists', 'Этой папки больше нет');
      case RemoteFsErrorKind.denied:
        return _t('Access to files is not allowed on the other device', 'Доступ к файлам на другом устройстве не разрешён');
      case RemoteFsErrorKind.timeout:
        return _t('The other device did not respond', 'Другое устройство не отвечает');
      case RemoteFsErrorKind.closed:
        return _t('Connection lost', 'Соединение потеряно');
      case RemoteFsErrorKind.unsupported:
        return _t('Browsing is not available here', 'Просмотр здесь недоступен');
      case RemoteFsErrorKind.io:
        return _t('Could not read this folder', 'Не удалось прочитать папку');
    }
  }

  /// Label for a root the host reported, localised by its `kind` hint.
  String rootLabel(String name, String? kind) {
    switch (kind) {
      case 'home':
        return _t('Home', 'Домашняя папка');
      case 'desktop':
        return _t('Desktop', 'Рабочий стол');
      case 'documents':
        return _t('Documents', 'Документы');
      case 'downloads':
        return _t('Downloads', 'Загрузки');
      case 'storage':
        return _t('App files', 'Файлы приложения');
      default:
        return name;
    }
  }

  // --- drop target / picking -------------------------------------------------
  String get dropTitle => _t('Drop files to send', 'Отпустите файлы, чтобы отправить');
  String get dropSubtitle => _t('Folders are sent with everything inside', 'Папки отправляются вместе с содержимым');
  String get nothingToSend => _t('Nothing to send', 'Нечего отправлять');
  String get notAllowed => _t('File transfer is not allowed in this session', 'Передача файлов в этой сессии не разрешена');
  String get connectionClosed => _t('The connection is closed', 'Соединение закрыто');
  String get sendFailed => _t('Could not start the transfer', 'Не удалось начать передачу');
  String sendingCount(int n) => ru
      ? _plural(n, 'файл отправляется', 'файла отправляются', 'файлов отправляются', prefix: '$n ')
      : (n == 1 ? 'Sending 1 file' : 'Sending $n files');

  // --- notifications for the core -------------------------------------------
  String fileReceivedFrom(String peer, String name) =>
      _t('$peer sent $name', 'Получен файл «$name» от $peer');
  String incomingFrom(String peer, String name) =>
      _t('$peer is sending $name', '$peer отправляет файл «$name»');
  String fileSent(String name) => _t('Sent $name', 'Отправлено: $name');
  String transferFailed(String name) => _t('Transfer failed: $name', 'Передача не удалась: $name');

  // --- number formatting -----------------------------------------------------
  String get decimalSeparator => ru ? ',' : '.';
  List<String> get sizeUnits => ru ? const ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'] : const ['B', 'KB', 'MB', 'GB', 'TB'];
  String get perSecond => _t('/s', '/с');
  String get seconds => _t('s', 'с');
  String get minutes => _t('min', 'мин');
  String get hours => _t('h', 'ч');
  String left(String eta) => _t('$eta left', 'ещё $eta');

  static String _plural(int n, String one, String few, String many, {required String prefix}) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    final form = (mod100 >= 11 && mod100 <= 14)
        ? many
        : mod10 == 1
            ? one
            : (mod10 >= 2 && mod10 <= 4)
                ? few
                : many;
    return '$prefix$form';
  }
}
