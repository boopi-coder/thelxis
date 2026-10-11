import 'strings_util.dart';

/// Common words, navigation, tray, badge, relative time, prompts and errors.
final Map<String, (String, String)> kCoreStrings = {
  // --- common ---
  'common.cancel': ('Cancel', 'Отмена'),
  'common.close': ('Close', 'Закрыть'),
  'common.copy': ('Copy', 'Копировать'),
  'common.copied': ('{what} copied', '{what}: скопировано'),
  'common.done': ('Done', 'Готово'),
  'common.more': ('More', 'Ещё'),
  'common.no': ('No', 'Нет'),
  'common.yes': ('Yes', 'Да'),
  'common.none': ('None', 'Нет'),
  'common.ok': ('OK', 'ОК'),
  'common.save': ('Save', 'Сохранить'),
  'common.unknown': ('Unknown', 'Неизвестно'),
  'common.unknownOs': ('Unknown OS', 'Неизвестная ОС'),

  // --- navigation ---
  'nav.home': ('Home', 'Главная'),
  'nav.devices': ('Devices', 'Устройства'),
  'nav.sessions': ('Sessions', 'Сеансы'),
  'nav.settings': ('Settings', 'Настройки'),

  // --- tray ---
  'tray.open': ('Open Thelxis', 'Открыть Thelxis'),
  'tray.copyId': ('Copy my ID', 'Копировать мой ID'),
  'tray.allowIncoming': ('Allow incoming connections', 'Разрешить входящие подключения'),
  'tray.quit': ('Quit', 'Выйти'),

  // --- session badge (native always-on-top window) ---
  'badge.one': ('Connected: {name}', 'Подключён: {name}'),
  ...plural(
    'badge.many',
    enOne: 'Connected: {n}',
    enOther: 'Connected: {n}',
    ruOne: 'Подключён: {n}',
    ruFew: 'Подключено: {n}',
    ruMany: 'Подключено: {n}',
  ),
  'badge.stop': ('Disconnect', 'Отключить'),

  // --- banner ---
  'banner.controlledBy': ('Controlled by {names}', 'Устройством управляет {names}'),
  'banner.viewedBy': ('Screen visible to {names}', 'Экран виден: {names}'),
  'banner.stop': ('Stop', 'Остановить'),
  'banner.stopAll': ('Stop all', 'Остановить все'),
  'banner.pauseControl': ('Pause control', 'Приостановить управление'),
  'banner.allowControl': ('Allow control', 'Разрешить управление'),

  // --- relative time ---
  'time.never': ('never', 'никогда'),
  'time.justNow': ('just now', 'только что'),
  ...plural(
    'time.min',
    enOne: '{n} min ago',
    enOther: '{n} min ago',
    ruOne: '{n} мин назад',
    ruFew: '{n} мин назад',
    ruMany: '{n} мин назад',
  ),
  ...plural(
    'time.hour',
    enOne: '{n} h ago',
    enOther: '{n} h ago',
    ruOne: '{n} ч назад',
    ruFew: '{n} ч назад',
    ruMany: '{n} ч назад',
  ),
  ...plural(
    'time.day',
    enOne: '{n} d ago',
    enOther: '{n} d ago',
    ruOne: '{n} дн. назад',
    ruFew: '{n} дн. назад',
    ruMany: '{n} дн. назад',
  ),

  // --- end reasons (history) ---
  'reason.denied': ('denied', 'отклонено'),
  'reason.remote': ('ended by peer', 'завершено собеседником'),
  'reason.timeout': ('timed out', 'истекло время'),
  'reason.error': ('failed', 'ошибка'),
  'reason.security': ('not verified', 'не проверено'),

  // --- prompts ---
  'prompt.accept.title': ('{who} wants to connect', '{who} хочет подключиться'),
  'prompt.accept.claimed': (
    'They call themselves "{user}". Only the ID above is verified.',
    'Он называет себя «{user}». Проверен только ID выше.',
  ),
  'prompt.accept.able': ('They will be able to:', 'Он сможет:'),
  'prompt.accept.view': ('See your screen', 'Видеть ваш экран'),
  'prompt.accept.control': ('Use your mouse and keyboard', 'Управлять мышью и клавиатурой'),
  'prompt.accept.control.unavailable': ('Not available on this system', 'Недоступно в этой системе'),
  'prompt.accept.clipboard': ('Share the clipboard', 'Обмениваться буфером обмена'),
  'prompt.accept.files': ('Transfer files', 'Передавать файлы'),
  'prompt.accept.always': ('Always allow this device', 'Всегда разрешать это устройство'),
  'prompt.accept.always.hint': (
    'Skips this prompt next time. Revoke it in Settings.',
    'В следующий раз вопрос не появится. Отозвать можно в настройках.',
  ),
  'prompt.accept.countdown': ('Denied automatically in {n} s', 'Будет отклонено автоматически через {n} с'),
  'prompt.accept': ('Accept', 'Принять'),
  'prompt.deny': ('Deny', 'Отклонить'),
  'prompt.decline': ('Decline', 'Отказаться'),
  'prompt.reverse.title': (
    '{name} offers you control of their computer',
    '{name} предлагает вам управлять своим компьютером',
  ),
  'prompt.reverse.body': (
    'You will see their screen and be able to use it. They can stop at any time.',
    'Вы увидите их экран и сможете им управлять. Они могут прекратить в любой момент.',
  ),
  'prompt.first.title': ('Connect to a new device?', 'Подключиться к новому устройству?'),
  'prompt.first.found': ('Found at {address}', 'Найдено по адресу {address}'),
  'prompt.first.body': (
    'Check that this ID matches the one the owner gave you. If it does not, someone else is answering at this address.',
    'Убедитесь, что этот ID совпадает с тем, который вам назвал владелец. Если нет — по этому адресу отвечает кто-то другой.',
  ),
  'prompt.first.trust': ('Trust and connect', 'Доверять и подключиться'),

  // --- warnings ---
  'warn.mismatch.title': ('Identity mismatch', 'Несовпадение личности'),
  'warn.mismatch.body': (
    'The device at {address} is not the one with the ID you entered. This can mean the address changed hands, or that someone is intercepting the connection. Nothing was sent to it.',
    'Устройство по адресу {address} — не то, чей ID вы ввели. Возможно, адрес перешёл к другому, либо кто-то перехватывает соединение. Ему ничего не отправлялось.',
  ),
  'warn.sig.title': ('Connection could not be verified', 'Соединение не удалось проверить'),
  'warn.sig.body': (
    'The connection setup message could not be verified. Someone may be intercepting this connection.',
    'Служебное сообщение установки соединения не прошло проверку. Возможно, кто-то перехватывает это соединение.',
  ),
  'warn.capture.title': ('Screen sharing was not allowed', 'Показ экрана не разрешён'),
  'warn.capture.body': (
    'Thelxis could not start sharing this screen, so the connection from {name} was ended. Accept the system screen-capture prompt to allow it.',
    'Thelxis не смог начать показ экрана, поэтому подключение {name} завершено. Чтобы разрешить, примите системный запрос на захват экрана.',
  ),

  // --- connection errors ---
  'err.noHost': ('This device cannot be controlled remotely.', 'Этим устройством нельзя управлять удалённо.'),
  'err.noAddress': (
    'No address is known for this ID yet. Ask for an invite link, or enter ID@address.',
    'Для этого ID пока неизвестен адрес. Попросите ссылку-приглашение или введите ID@адрес.',
  ),
  'err.cancelled': ('Cancelled.', 'Отменено.'),
  'err.unreachable': (
    'Could not connect. Check the address and that the device is on and allows incoming connections.',
    'Не удалось подключиться. Проверьте адрес, включено ли устройство и разрешены ли на нём входящие подключения.',
  ),
  'err.mismatch': (
    'The device at this address is not the one you expected.',
    'Устройство по этому адресу — не то, которое вы ожидали.',
  ),
  'err.badSignature': (
    'The other device could not prove its identity.',
    'Другое устройство не смогло подтвердить свою личность.',
  ),
  'err.notAccepting': (
    'This device is not accepting connections.',
    'Это устройство не принимает подключения.',
  ),
  'err.busy': ('This device is busy.', 'Это устройство занято.'),
  'err.rateLimited': (
    'Too many attempts. Try again in a minute.',
    'Слишком много попыток. Повторите через минуту.',
  ),
  'err.version': (
    'The other device runs an incompatible version.',
    'На другом устройстве несовместимая версия приложения.',
  ),
  'err.timeout': ('The connection timed out.', 'Время ожидания соединения истекло.'),
  'err.protocol': ('The connection was refused.', 'Соединение отклонено.'),

  // --- connect field parsing ---
  'parse.unrecognised': (
    'Enter a Thelxis ID with an address (ID@host), an address, or an invite link.',
    'Введите Thelxis ID с адресом (ID@хост), адрес или ссылку-приглашение.',
  ),
  'parse.badId': ('The Thelxis ID before "@" is not valid.', 'Thelxis ID перед «@» указан неверно.'),
  'parse.badAddress': ('The address after "@" is not valid.', 'Адрес после «@» указан неверно.'),
  'parse.brokenId': (
    'This looks like a Thelxis ID, but it is not 16 characters long. Check it and try again.',
    'Похоже на Thelxis ID, но в нём не 16 символов. Проверьте и повторите.',
  ),
  'parse.badInvite': ('This invite link is malformed.', 'Ссылка-приглашение повреждена.'),
  'parse.notInvite': ('This is not a Thelxis invite link.', 'Это не ссылка-приглашение Thelxis.'),
  'parse.inviteNoId': (
    'The invite link has no valid Thelxis ID.',
    'В ссылке-приглашении нет корректного Thelxis ID.',
  ),

  // --- link path labels ---
  'path.lan': ('LAN', 'Локальная сеть'),
  'path.direct': ('Direct', 'Напрямую'),
  'path.gateway': ('Via gateway', 'Через шлюз'),
  'path.relay': ('Via host TURN', 'Через TURN хоста'),
};
