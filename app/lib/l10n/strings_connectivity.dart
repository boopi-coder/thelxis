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
  'share.viaGateway': ('Also through the office gateway', 'Также через офисный шлюз'),
  'share.note': (
    'The invite identifies this device as {id}; the other side checks that ID cryptographically, so a wrong address can never connect them to a different device.',
    'Приглашение указывает это устройство как {id}; другая сторона криптографически проверяет этот ID, поэтому неверный адрес не соединит её с чужим устройством.',
  ),

  // --- connect by code ---
  'code.title': ('Connect by code', 'Подключение по коду'),
  'code.intro': (
    'When neither device can accept connections (for example both are behind a provider NAT), swap two short codes through any messenger. No server and no router setup are needed.',
    'Если ни одно устройство не принимает подключения (например, оба за NAT провайдера), обменяйтесь двумя короткими кодами через любой мессенджер. Сервер и настройка роутера не нужны.',
  ),
  'code.mode.share': ('My code', 'Мой код'),
  'code.mode.enter': ('I have a code', 'У меня есть код'),
  'code.share.hint': (
    'Create a code and send it to the person who will control this device. Then paste the code they send back.',
    'Создайте код и отправьте тому, кто будет управлять этим устройством. Затем вставьте код, который он пришлёт в ответ.',
  ),
  'code.create': ('Create code', 'Создать код'),
  'code.creating': ('Preparing the code…', 'Готовим код…'),
  'code.yourCode': ('Your code', 'Ваш код'),
  'code.copy': ('Copy code', 'Скопировать код'),
  'code.noun': ('Code', 'Код'),
  'code.expiresIn': ('Valid for {time}', 'Действителен ещё {time}'),
  'code.expired': ('This code has expired. Create a new one.', 'Срок кода истёк. Создайте новый.'),
  'code.pasteAnswer': ('Paste their answer code (TX2…)', 'Вставьте ответный код (TX2…)'),
  'code.pasteOffer': ('Paste the code you received (TX1…)', 'Вставьте полученный код (TX1…)'),
  'code.apply': ('Connect', 'Подключиться'),
  'code.answer': ('Answer', 'Ответить'),
  'code.answerReady': (
    'Send this answer code back. The connection starts when the other person pastes it.',
    'Отправьте этот ответный код обратно. Подключение начнётся, когда собеседник вставит его.',
  ),
  'code.answerNoun': ('Answer code', 'Ответный код'),
  'code.confirm.title': ('Connect to this device?', 'Подключиться к этому устройству?'),
  'code.confirm.body': (
    'The code comes from the device below. Check its ID with the person who sent the code (by phone, for example) before you continue.',
    'Код выпущен устройством ниже. Перед продолжением сверьте его ID с тем, кто прислал код (например, по телефону).',
  ),
  'code.confirm.known': ('Known device', 'Известное устройство'),
  'code.confirm.new': ('New device', 'Новое устройство'),
  'code.confirm.trust': ('Connect', 'Подключиться'),
  'code.error.malformed': (
    'This is not a valid code. Copy it again completely, including the TX1. or TX2. start.',
    'Это неверный код. Скопируйте его заново полностью, вместе с началом TX1. или TX2.',
  ),
  'code.error.tooLarge': ('The code is too long to be genuine.', 'Код слишком длинный для настоящего.'),
  'code.error.unsupported': (
    'This code comes from a newer version of Thelxis. Update the app.',
    'Этот код создан более новой версией Thelxis. Обновите приложение.',
  ),
  'code.error.expired': ('This code has expired. Ask for a new one.', 'Срок кода истёк. Попросите новый.'),
  'code.error.badSignature': (
    'The code\'s signature is wrong: it was altered or does not belong to this connection.',
    'Подпись кода неверна: его изменили или он не относится к этому подключению.',
  ),
  'code.error.mismatch': (
    'This code does not belong here. Use the answer to the code you created.',
    'Этот код сюда не подходит. Используйте ответ на созданный вами код.',
  ),
  'code.tooBig': (
    'The connection data is too large for a code.',
    'Данные подключения слишком велики для кода.',
  ),
  'code.failed': ('Could not prepare the connection.', 'Не удалось подготовить подключение.'),
  'code.waiting': ('Waiting for the other device…', 'Ждём второе устройство…'),
  'code.started': ('Connecting. The other device will ask for access.', 'Подключаемся. Второе устройство запросит доступ.'),
  'code.hint.punch': (
    'Needs internet on both sides. Public STUN servers are used for this connection.',
    'Нужен интернет с обеих сторон. Для этого подключения используются публичные STUN-серверы.',
  ),

  // --- reachability ---
  'reach.off': ('Not accepting', 'Не принимает подключения'),
  'reach.off.detail': (
    'Incoming connections are switched off. Nobody can connect to this device.',
    'Входящие подключения отключены. Никто не сможет подключиться к этому устройству.',
  ),
  'reach.noListener': ('Listener unavailable', 'Приём подключений недоступен'),
  'reach.internet': ('Reachable from internet', 'Доступно из интернета'),
  'reach.lan': ('LAN only', 'Только в локальной сети'),

  // Advice per situation: title, one friendly sentence, steps (one per line),
  // and a one-line hint for Home.
  'reach.steps.title': ('What you can do', 'Что можно сделать'),
  'reach.action.enableIncoming': ('Accept incoming connections', 'Принимать подключения'),
  'reach.action.enableMapping': ('Turn on automatic port mapping', 'Включить автоматический проброс'),
  'reach.action.manualForwarding': ('Set up manual forwarding', 'Настроить ручной проброс'),

  'reach.off.title': ('Incoming connections are off', 'Входящие подключения отключены'),
  'reach.off.body': (
    'Nobody can connect to this device while this is off.',
    'Пока это выключено, никто не сможет подключиться к этому устройству.',
  ),

  'reach.portInUse.title': ('Can\'t listen on port 47100', 'Не удаётся открыть порт 47100'),
  'reach.portInUse.body': (
    'Another program is using the port, or a firewall is blocking Thelxis.',
    'Порт занят другой программой, либо Thelxis блокирует брандмауэр.',
  ),
  'reach.portInUse.steps': (
    'Close the other program that uses port 47100 (maybe a second Thelxis) and press Re-scan.\nIf the firewall asks, allow Thelxis.',
    'Закройте другую программу, занимающую порт 47100 (возможно, вторую копию Thelxis), и нажмите «Проверить заново».\nЕсли брандмауэр спросит, разрешите Thelxis.',
  ),
  'reach.portInUse.hint': (
    'Port 47100 is busy. Tap to see what to do.',
    'Порт 47100 занят. Нажмите, чтобы узнать, что делать.',
  ),

  'reach.direct.title': ('Reachable from the internet', 'Доступно из интернета'),
  'reach.direct.body': (
    'This device has a public address of its own. Nothing to set up.',
    'У этого устройства собственный публичный адрес. Ничего настраивать не нужно.',
  ),

  'reach.mapped.title': ('Reachable via your router ({method})', 'Доступно через роутер ({method})'),
  'reach.mapped.body': (
    'Your router opened the ports automatically. Nothing to set up.',
    'Роутер сам открыл порты. Ничего настраивать не нужно.',
  ),

  'reach.manual.title': ('Reachable via your manual forwarding', 'Доступно через ваш ручной проброс'),
  'reach.manual.body': (
    'Thelxis cannot check a manual forward from inside your network.',
    'Thelxis не может проверить ручной проброс изнутри вашей сети.',
  ),
  'reach.manual.steps': (
    'To test, connect to this device from a phone on mobile data.',
    'Для проверки подключитесь к этому устройству с телефона через мобильный интернет.',
  ),

  'reach.ipv6.title': ('Reachable over IPv6', 'Доступно по IPv6'),
  'reach.ipv6.body': (
    'People whose network has IPv6 can connect directly.',
    'Подключиться напрямую смогут те, у кого в сети есть IPv6.',
  ),
  'reach.ipv6.steps': (
    'For people without IPv6, turn on UPnP on the router or forward the ports by hand.',
    'Для тех, у кого нет IPv6, включите UPnP на роутере или пробросьте порты вручную.',
  ),

  'reach.gateway.title': ('Reachable through office gateway {name}', 'Доступно через офисный шлюз {name}'),
  'reach.gateway.body': (
    'People on the internet can connect to this device through {name}. No router setup is needed here.',
    'Подключиться к этому устройству из интернета можно через {name}. Настраивать роутер здесь не нужно.',
  ),

  'reach.cgnat.title': ('Your provider blocks incoming connections', 'Провайдер блокирует входящие подключения'),
  'reach.cgnat.body': (
    'Your provider shares one public address between many customers (CGNAT), so nobody can reach this device from the internet over IPv4.',
    'Провайдер выдаёт один публичный адрес многим клиентам (CGNAT), поэтому из интернета по IPv4 до этого устройства не достучаться.',
  ),
  'reach.cgnat.steps': (
    'Use "Connect by code" on the Home page: no router setup, works through CGNAT.\nOr use "Let them control this device": the connection goes out from you instead.\nOr ask the provider for a public IP, or use IPv6 or a VPN.',
    'Используйте «Подключение по коду» на главной: без настройки роутера, работает через CGNAT.\nЛибо используйте «Дать им управлять этим устройством»: подключение пойдёт от вас.\nИли попросите у провайдера публичный IP, либо используйте IPv6 или VPN.',
  ),
  'reach.cgnat.hint': (
    'Your provider blocks incoming (CGNAT). Tap for options.',
    'Провайдер блокирует входящие (CGNAT). Нажмите, чтобы увидеть варианты.',
  ),

  'reach.doubleNat.title': ('Two routers in a row', 'Два роутера подряд'),
  'reach.doubleNat.body': (
    'Another router sits between your router and the internet (double NAT), so the ports your router opens lead nowhere.',
    'Между вашим роутером и интернетом стоит ещё один роутер (двойной NAT), поэтому открытые порты никуда не ведут.',
  ),
  'reach.doubleNat.steps': (
    'Switch the first router or modem to bridge mode.\nOr forward the ports on both routers.\nOr use "Let them control this device": the connection goes out from you.',
    'Переведите первый роутер или модем в режим моста.\nЛибо пробросьте порты на обоих роутерах.\nЛибо используйте «Дать им управлять этим устройством»: подключение пойдёт от вас.',
  ),
  'reach.doubleNat.hint': (
    'Two routers in a row (double NAT). Tap for options.',
    'Два роутера подряд (двойной NAT). Нажмите, чтобы увидеть варианты.',
  ),

  'reach.mappingFailed.title': ('Your router did not open the ports', 'Роутер не открыл порты'),
  'reach.mappingFailed.body': (
    'The router answered, but it refused to forward the ports automatically.',
    'Роутер ответил, но отказался пробросить порты автоматически.',
  ),
  'reach.mappingFailed.steps': (
    'Forward the ports by hand (manual forwarding in Settings).\nOr check that UPnP is on in the router, restart it and press Re-scan.',
    'Пробросьте порты вручную (ручной проброс в настройках).\nИли убедитесь, что UPnP включён на роутере, перезагрузите его и нажмите «Проверить заново».',
  ),
  'reach.mappingFailed.hint': (
    'The router did not open the ports. Tap to fix.',
    'Роутер не открыл порты. Нажмите, чтобы исправить.',
  ),

  'reach.mappingOff.title': ('Automatic port mapping is off', 'Автоматический проброс отключён'),
  'reach.mappingOff.body': (
    'Without it, only devices in your own network can connect.',
    'Без него подключаться смогут только устройства вашей сети.',
  ),
  'reach.mappingOff.steps': (
    'Turn on automatic port mapping.\nOr forward the ports by hand (manual forwarding in Settings).',
    'Включите автоматический проброс портов.\nИли пробросьте порты вручную (ручной проброс в настройках).',
  ),
  'reach.mappingOff.hint': (
    'Automatic port mapping is off. Tap to turn it on.',
    'Автоматический проброс отключён. Нажмите, чтобы включить.',
  ),

  'reach.noRouter.title': ('Reachable only inside your network', 'Доступно только в вашей сети'),
  'reach.noRouter.body': (
    'No router that can open ports by itself was found, so only devices on the same network (or VPN) can connect.',
    'Роутер, который сам открывает порты, не найден, поэтому подключаться смогут только устройства из той же сети (или VPN).',
  ),
  'reach.noRouter.steps': (
    'Enable UPnP on the router, then press Re-scan.\nOr forward the ports by hand (manual forwarding in Settings).\nOr use "Let them control this device": the connection goes out from you.',
    'Включите UPnP на роутере и нажмите «Проверить заново».\nИли пробросьте порты вручную (ручной проброс в настройках).\nИли используйте «Дать им управлять этим устройством»: подключение пойдёт от вас.',
  ),
  'reach.noRouter.hint': (
    'Only reachable inside your network. Tap to see how to fix it.',
    'Доступно только в вашей сети. Нажмите, чтобы узнать, как исправить.',
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
  'diag.manual': ('Manual forwarding', 'Ручной проброс'),
  'diag.manual.on': ('Set (cannot be verified from inside)', 'Задан (изнутри не проверить)'),
  'diag.mappings': ('Port mappings', 'Проброшенные порты'),
  'diag.how': (
    'Thelxis has no server. A device is reachable when it has a public IPv6 address, a router mapping (UPnP / NAT-PMP), or a manual port forward of 47100 (TCP and UDP) and 47101 (TCP). If only the other side is reachable, use "Let them control this device" to connect in reverse.',
    'У Thelxis нет сервера. Устройство доступно, если у него есть публичный IPv6-адрес, проброс портов на роутере (UPnP / NAT-PMP) или ручной проброс 47100 (TCP и UDP) и 47101 (TCP). Если доступна только другая сторона, используйте «Дать им управлять этим устройством» — подключение пойдёт в обратную сторону.',
  ),
};
