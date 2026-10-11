/// Settings page and its dialogs.
final Map<String, (String, String)> kSettingsStrings = {
  'settings.title': ('Settings', 'Настройки'),
  'settings.device': ('Device', 'Устройство'),
  'settings.deviceName': ('Device name', 'Имя устройства'),
  'settings.deviceName.hint': (
    'Shown to the people who connect to this device.',
    'Это имя видят те, кто подключается к устройству.',
  ),

  'settings.security': ('Security', 'Безопасность'),
  'settings.permanent': ('Permanent password', 'Постоянный пароль'),
  'settings.permanent.set': ('Set — for unattended access', 'Задан — для доступа без присутствия'),
  'settings.permanent.unset': ('Not set', 'Не задан'),
  'settings.permanent.setBtn': ('Set', 'Задать'),
  'settings.permanent.change': ('Change', 'Изменить'),
  'settings.permanent.remove': ('Remove', 'Удалить'),
  'settings.approval': ('Ask before every connection', 'Спрашивать при каждом подключении'),
  'settings.approval.hint': (
    'Even with the right password, someone here must accept.',
    'Даже с верным паролем кто-то на этом устройстве должен принять подключение.',
  ),
  'settings.rotate': (
    'New one-time password after each session',
    'Новый одноразовый пароль после каждого сеанса',
  ),
  'settings.defaults': ('Default permissions', 'Разрешения по умолчанию'),
  'settings.defaults.control': (
    'Allow control (mouse and keyboard)',
    'Разрешить управление (мышь и клавиатура)',
  ),
  'settings.defaults.control.hint': ('Off means viewers can only watch.', 'Если выключено, зрители смогут только смотреть.'),
  'settings.defaults.clipboard': ('Allow clipboard sync', 'Разрешить обмен буфером обмена'),
  'settings.defaults.files': ('Allow file transfer', 'Разрешить передачу файлов'),

  'settings.trusted': ('Trusted devices', 'Доверенные устройства'),
  'trusted.empty': ('No trusted devices', 'Доверенных устройств нет'),
  'trusted.empty.hint': (
    'Tick "Always allow this device" when accepting a request to add one.',
    'Отметьте «Всегда разрешать это устройство» при принятии запроса, чтобы добавить его.',
  ),
  'trusted.control': ('May control', 'Может управлять'),
  'trusted.clipboard': ('May use the clipboard', 'Может использовать буфер обмена'),
  'trusted.files': ('May transfer files', 'Может передавать файлы'),
  'trusted.revoke': ('Revoke', 'Отозвать'),
  'trusted.revoked': ('{name} is no longer trusted', '{name} больше не доверенное устройство'),

  'settings.connectivity': ('Connectivity', 'Связь'),
  'settings.incoming': ('Allow incoming connections', 'Разрешить входящие подключения'),
  'settings.incoming.hint': (
    'Turning this off also stops UPnP mapping and the embedded relay.',
    'При отключении также останавливаются проброс UPnP и встроенный ретранслятор.',
  ),
  'settings.upnp': ('Automatic port mapping (UPnP, NAT-PMP)', 'Автоматический проброс портов (UPnP, NAT-PMP)'),
  'settings.upnp.hint': (
    'Asks your router to make this device reachable from the internet.',
    'Просит роутер сделать это устройство доступным из интернета.',
  ),
  'settings.lan': ('Show this device on the local network', 'Показывать это устройство в локальной сети'),
  'settings.lan.hint': (
    'Answers discovery requests from other Thelxis apps on your LAN.',
    'Отвечает на запросы поиска от других приложений Thelxis в вашей сети.',
  ),
  'settings.stun': ('Use a public STUN server', 'Использовать публичный STUN-сервер'),
  'settings.stun.hint': (
    'Off by default. Helps when both sides are behind NAT, but tells the STUN server (Google) your IP address. No media or content is sent.',
    'По умолчанию выключено. Помогает, когда обе стороны за NAT, но сообщает STUN-серверу (Google) ваш IP-адрес. Видео и данные не передаются.',
  ),
  'settings.diagnostics': ('Diagnostics', 'Диагностика'),
  'settings.diagnostics.hint': (
    'Why can or can\'t others reach this device?',
    'Почему другие могут или не могут подключиться к этому устройству?',
  ),

  'settings.appearance': ('Appearance', 'Оформление'),
  'settings.theme': ('Theme', 'Тема'),
  'settings.theme.dark': ('Dark', 'Тёмная'),
  'settings.theme.light': ('Light', 'Светлая'),
  'settings.theme.system': ('System', 'Системная'),
  'settings.language': ('Language', 'Язык'),
  'settings.language.system': ('System', 'Системный'),

  'settings.startup': ('Startup', 'Запуск'),
  'settings.autostart': ('Start Thelxis when I sign in', 'Запускать Thelxis при входе в систему'),
  'settings.autostart.hint': (
    'Starts hidden in the tray and keeps this device reachable after a restart.',
    'Запускается скрыто в трее и сохраняет доступность устройства после перезагрузки.',
  ),

  'settings.updates': ('Updates', 'Обновления'),
  'settings.about': ('About', 'О программе'),
  'settings.version': ('Version {version} · {os} {arch}', 'Версия {version} · {os} {arch}'),
  'settings.noServers': ('No servers, no accounts', 'Никаких серверов и аккаунтов'),
  'settings.noServers.hint': (
    'Devices connect directly and everything is end-to-end encrypted. Your identity key never leaves this device.',
    'Устройства соединяются напрямую, всё защищено сквозным шифрованием. Ключ вашей личности никогда не покидает это устройство.',
  ),

  'perm.pw.intro': (
    'Lets you connect to this device without anyone present. Only a key derived from the password is stored, never the password itself.',
    'Позволяет подключаться к этому устройству, когда рядом никого нет. Хранится только ключ, полученный из пароля, но не сам пароль.',
  ),
  'perm.pw.new': ('New password', 'Новый пароль'),
  'perm.pw.repeat': ('Repeat password', 'Повторите пароль'),
  'perm.pw.short': ('Use at least 8 characters.', 'Используйте не менее 8 символов.'),
  'perm.pw.mismatch': ('The two passwords do not match.', 'Пароли не совпадают.'),
};
