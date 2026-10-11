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
  'settings.stun': ('Use public STUN servers', 'Использовать публичные STUN-серверы'),
  'settings.stun.hint': (
    'On by default. They only learn your public IP address and port, so devices behind routers can find each other. They never see your screen, files or any other data. Turn off if you only connect inside one network.',
    'Включено по умолчанию. Они узнают только ваш публичный IP-адрес и порт, чтобы устройства за роутерами могли найти друг друга. Ваш экран, файлы и любые другие данные им недоступны. Отключите, если подключаетесь только внутри одной сети.',
  ),
  'settings.manual': ('Manual port forwarding', 'Ручной проброс портов'),
  'settings.manual.hint': (
    'For routers without UPnP, or several computers behind one address. You open the ports on the router yourself.',
    'Для роутеров без UPnP или нескольких компьютеров за одним адресом. Порты на роутере вы открываете сами.',
  ),
  'settings.manual.host': ('Public IP or DDNS name (optional)', 'Внешний IP или DDNS-имя (необязательно)'),
  'settings.manual.host.hint': (
    'Leave empty to use the address Thelxis finds on its own.',
    'Оставьте пустым, чтобы использовать адрес, который Thelxis определит сам.',
  ),
  'settings.manual.badHost': ('Enter an IP address or a host name', 'Введите IP-адрес или имя хоста'),
  'settings.manual.badPort': ('A port from 1 to 65535', 'Порт от 1 до 65535'),
  'settings.manual.portSignaling': ('Connection port (TCP)', 'Порт подключения (TCP)'),
  'settings.manual.portUdp': ('Relay port (UDP)', 'Порт ретранслятора (UDP)'),
  'settings.manual.portTcp': ('Relay port (TCP)', 'Порт ретранслятора (TCP)'),
  'settings.manual.lanIp': ('<LAN IP of this computer>', '<локальный IP этого компьютера>'),
  'settings.manual.instructions': (
    'On the router, forward TCP {p1} → {ip}:47100, UDP {p2} → {ip}:47100, TCP {p3} → {ip}:47101.',
    'На роутере пробросьте TCP {p1} → {ip}:47100, UDP {p2} → {ip}:47100, TCP {p3} → {ip}:47101.',
  ),
  'settings.manual.copy': ('Copy instructions', 'Скопировать инструкцию'),
  'settings.manual.noun': ('Instructions', 'Инструкция'),
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
