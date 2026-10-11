/// Home screen, sharing, reachability and diagnostics.
final Map<String, (String, String)> kConnectivityStrings = {
  // --- home hero card ---
  'home.thisDevice': ('This device', 'Это устройство'),
  'home.yourId': ('Your Thelxis ID', 'Ваш Thelxis ID'),
  'home.idNoun': ('ID', 'ID'),
  'home.copyId': ('Copy ID', 'Копировать ID'),
  'home.otp': ('One-time password', 'Одноразовый пароль'),
  'home.otp.noun': ('Password', 'Пароль'),
  'home.otp.show': ('Show', 'Показать'),
  'home.otp.hide': ('Hide', 'Скрыть'),
  'home.otp.copy': ('Copy password', 'Копировать пароль'),
  'home.otp.refresh': ('New password', 'Новый пароль'),
  'home.allowIncoming': ('Allow incoming connections', 'Разрешить входящие подключения'),
  'home.allowIncoming.hint': (
    'Lets other devices connect with your ID and password.',
    'Другие устройства смогут подключаться по вашему ID и паролю.',
  ),
  'home.allowIncoming.unsupported': (
    'This device can connect to others but cannot be controlled.',
    'Это устройство может подключаться к другим, но им нельзя управлять.',
  ),
  'home.share': ('Share access', 'Поделиться доступом'),

  // --- OS permissions ---
  'perm.screen': (
    'Screen recording permission is needed to share this screen.',
    'Для показа экрана нужно разрешение на запись экрана.',
  ),
  'perm.input': (
    'Accessibility permission is needed to let others use the mouse and keyboard.',
    'Чтобы другие могли управлять мышью и клавиатурой, нужно разрешение «Универсальный доступ».',
  ),
  'perm.android.restricted': (
    'If the switch is greyed out ("Restricted setting"): open Settings → Apps → Thelxis → ⋮ → Allow restricted settings, then enable the accessibility service.',
    'Если переключатель неактивен («Ограниченная настройка»): откройте Настройки → Приложения → Thelxis → ⋮ → «Разрешить ограниченные настройки», затем включите службу специальных возможностей.',
  ),
  'perm.grant': ('Grant', 'Разрешить'),

  // --- connect card ---
  'connect.title': ('Connect to a device', 'Подключиться к устройству'),
  'connect.hint': (
    'Paste an invite link, or type ID@address or an address.',
    'Вставьте ссылку-приглашение или введите ID@адрес либо адрес.',
  ),
  'connect.paste': ('Paste', 'Вставить'),
  'connect.button': ('Connect', 'Подключиться'),
  'connect.connecting': ('Connecting…', 'Подключение…'),
  'connect.more': ('More ways to connect', 'Другие способы подключения'),
  'connect.viewOnly': ('Connect, view only', 'Подключиться только для просмотра'),
  'connect.reverse': ('Let them control this device', 'Дать им управлять этим устройством'),
  'connect.recent': ('Recent', 'Недавние'),
  'connect.offered': ('Offered control of this device.', 'Управление этим устройством предложено.'),

  // --- share access ---
  'share.title': ('Share access', 'Поделиться доступом'),
  'share.intro': (
    'Give this to someone you trust. They also need your one-time password, or you must accept their request.',
    'Передайте это тому, кому доверяете. Ему также понадобится ваш одноразовый пароль, либо вам придётся принять его запрос.',
  ),
  'share.link': ('Invite link', 'Ссылка-приглашение'),
  'share.qr': ('QR code with the invite link', 'QR-код со ссылкой-приглашением'),
  'share.idAt': ('ID and address', 'ID и адрес'),
  'share.reachableAt': ('Reachable at', 'Доступно по адресам'),
  'share.noAddress': (
    'No address found yet. Connect to a network, or open the connectivity diagnostics in Settings.',
    'Адрес пока не найден. Подключитесь к сети или откройте диагностику связи в настройках.',
  ),
  'share.note': (
    'The invite identifies this device as {id}; the other side checks that ID cryptographically, so a wrong address can never connect them to a different device.',
    'Приглашение указывает это устройство как {id}; другая сторона криптографически проверяет этот ID, поэтому неверный адрес не соединит её с чужим устройством.',
  ),

  // --- reachability ---
  'reach.off': ('Not accepting', 'Не принимает подключения'),
  'reach.off.detail': (
    'Incoming connections are switched off. Nobody can connect to this device.',
    'Входящие подключения отключены. Никто не сможет подключиться к этому устройству.',
  ),
  'reach.noListener': ('Listener unavailable', 'Приём подключений недоступен'),
  'reach.noListener.detail': (
    'The signaling port could not be opened. Another program may be using port 47100.',
    'Не удалось открыть порт сигнализации. Возможно, порт 47100 занят другой программой.',
  ),
  'reach.internet': ('Reachable from internet', 'Доступно из интернета'),
  'reach.internet.detail': (
    'Devices on the internet can connect directly to this one.',
    'Устройства из интернета могут подключаться напрямую.',
  ),
  'reach.lan': ('LAN only', 'Только в локальной сети'),
  'reach.lan.detail': (
    'Devices on your network can connect. For internet access, enable UPnP or forward ports 47100 (TCP and UDP) and 47101 (TCP) on your router.',
    'Подключаться могут устройства вашей сети. Для доступа из интернета включите UPnP или пробросьте на роутере порты 47100 (TCP и UDP) и 47101 (TCP).',
  ),
  'reach.cgnat.detail': (
    'Your provider shares one public address between customers (CGNAT), so inbound IPv4 is not possible. IPv6, a VPN, or a reverse connection can still work.',
    'Провайдер выдаёт один публичный адрес многим клиентам (CGNAT), поэтому входящий IPv4 невозможен. Могут помочь IPv6, VPN или обратное подключение.',
  ),

  // --- diagnostics ---
  'diag.title': ('Connectivity diagnostics', 'Диагностика связи'),
  'diag.rescan': ('Re-scan', 'Проверить заново'),
  'diag.section.device': ('This device', 'Это устройство'),
  'diag.section.router': ('Router', 'Роутер'),
  'diag.section.problems': ('Problems', 'Проблемы'),
  'diag.section.how': ('How connections work', 'Как работают подключения'),
  'diag.listening': ('Listening on TCP 47100', 'Приём на TCP 47100'),
  'diag.relay': ('Embedded STUN/TURN', 'Встроенный STUN/TURN'),
  'diag.running': ('Running', 'Работает'),
  'diag.stopped': ('Stopped', 'Остановлен'),
  'diag.lanIPv4': ('LAN IPv4', 'IPv4 в локальной сети'),
  'diag.ipv6': ('Global IPv6', 'Глобальный IPv6'),
  'diag.gateway': ('UPnP / NAT-PMP / PCP gateway', 'Шлюз UPnP / NAT-PMP / PCP'),
  'diag.gateway.found': ('Found ({method})', 'Найден ({method})'),
  'diag.gateway.none': ('Not found', 'Не найден'),
  'diag.externalIp': ('External IPv4', 'Внешний IPv4'),
  'diag.publicAddress': ('Public address', 'Публичный адрес'),
  'diag.directAddress': ('Address on this machine', 'Адрес на этом компьютере'),
  'diag.directAddress.yes': ('Yes — no router mapping needed', 'Да — проброс на роутере не нужен'),
  'diag.cgnat': ('Carrier-grade NAT', 'NAT оператора (CGNAT)'),
  'diag.detected': ('Detected', 'Обнаружен'),
  'diag.mappings': ('Port mappings', 'Проброшенные порты'),
  'diag.how': (
    'Thelxis has no server. A device is reachable when it has a public IPv6 address, a router mapping (UPnP / NAT-PMP), or a manual port forward of 47100 (TCP and UDP) and 47101 (TCP). If only the other side is reachable, use "Let them control this device" to connect in reverse.',
    'У Thelxis нет сервера. Устройство доступно, если у него есть публичный IPv6-адрес, проброс портов на роутере (UPnP / NAT-PMP) или ручной проброс 47100 (TCP и UDP) и 47101 (TCP). Если доступна только другая сторона, используйте «Дать им управлять этим устройством» — подключение пойдёт в обратную сторону.',
  ),
};
