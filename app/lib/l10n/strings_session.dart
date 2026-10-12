/// The session (viewer) screen: toolbar, overlays, stats, special keys, files.
final Map<String, (String, String)> kSessionStrings = {
  'session.connecting': ('Connecting', 'Подключение'),
  'session.connectingTo': ('Connecting to {name}…', 'Подключение к {name}…'),
  'session.authorizing': ('Authorizing…', 'Авторизация…'),
  'session.waitingAccept': ('Waiting for {name} to accept…', 'Ожидание подтверждения от {name}…'),
  'session.firstFrame': ('Waiting for the first frame…', 'Ожидание первого кадра…'),
  'session.reconnecting': ('Reconnecting…', 'Восстановление связи…'),
  'session.reconnectingShort': ('Reconnecting', 'Восстановление связи'),
  'session.reconnecting.hint': (
    'The picture will resume when the connection returns.',
    'Картинка появится снова, когда связь восстановится.',
  ),
  'session.ended': ('Session ended', 'Сеанс завершён'),
  'session.idLine': ('ID {id}', 'ID {id}'),
  'session.password': ('Password', 'Пароль'),
  'session.requestInstead': ('Request access instead', 'Запросить доступ вместо пароля'),

  'ended.denied': ('The other side denied the connection.', 'Другая сторона отклонила подключение.'),
  'ended.remote': ('{name} ended the session.', '{name} завершил(а) сеанс.'),
  'ended.timeout': ('The connection timed out.', 'Время ожидания соединения истекло.'),
  'ended.security': (
    'The connection was closed because it could not be verified.',
    'Соединение закрыто, потому что его не удалось проверить.',
  ),
  'ended.error': ('The connection failed.', 'Не удалось установить соединение.'),
  'ended.user': ('Session ended.', 'Сеанс завершён.'),

  // --- viewer auth notices ---
  'viewer.denied': ('The host denied the connection.', 'Владелец отклонил подключение.'),
  'viewer.notReady': (
    'The secure channel is not ready yet. Try again.',
    'Защищённый канал ещё не готов. Повторите попытку.',
  ),
  'viewer.wrongPassword': ('Wrong password. Try again.', 'Неверный пароль. Попробуйте ещё раз.'),
  'viewer.wrongPassword.final': ('Wrong password.', 'Неверный пароль.'),
  'viewer.locked': (
    'Too many wrong attempts. The host locked password entry for 5 minutes.',
    'Слишком много неверных попыток. Владелец заблокировал ввод пароля на 5 минут.',
  ),
  'viewer.notAllowed': (
    'The other device did not allow screen sharing, or could not start it.',
    'Другое устройство не разрешило показ экрана или не смогло его начать.',
  ),
  'viewer.refused': ('This device is not allowed to connect.', 'Этому устройству подключаться нельзя.'),
  'viewer.waitingAccept': (
    'Waiting for the other side to accept…',
    'Ждём, пока другая сторона примет запрос…',
  ),

  // --- toolbar ---
  'toolbar.back': ('Back to Thelxis', 'Назад в Thelxis'),
  'toolbar.display': ('Display', 'Экран'),
  'toolbar.display.main': ('(main)', '(основной)'),
  'toolbar.quality': ('Quality', 'Качество'),
  'toolbar.keys': ('Special keys', 'Специальные клавиши'),
  'toolbar.keyboard': ('Keyboard', 'Клавиатура'),
  'toolbar.keyboard.hide': ('Hide keyboard', 'Скрыть клавиатуру'),
  'toolbar.touchMode': ('Touch mode', 'Режим касаний'),
  'toolbar.touchpad': ('Touchpad (relative cursor)', 'Тачпад (относительный курсор)'),
  'toolbar.direct': ('Direct touch', 'Прямое касание'),
  'toolbar.clipboard.on': ('Clipboard sync on', 'Синхронизация буфера включена'),
  'toolbar.clipboard.off': ('Clipboard sync off', 'Синхронизация буфера выключена'),
  'toolbar.files': ('Files', 'Файлы'),
  'toolbar.viewOnly.on': ('View only (tap to control)', 'Только просмотр (нажмите для управления)'),
  'toolbar.viewOnly.off': ('Controlling (tap for view only)', 'Управление (нажмите для просмотра)'),
  'toolbar.zoom': ('Zoom', 'Масштаб'),
  'toolbar.fit': ('Fit to window', 'По размеру окна'),
  'toolbar.actual': ('Actual size (1:1)', 'Реальный размер (1:1)'),
  'toolbar.fullscreen': ('Full screen', 'Во весь экран'),
  'toolbar.fullscreen.exit': ('Exit full screen', 'Выйти из полноэкранного режима'),
  'toolbar.stats': ('Statistics', 'Статистика'),
  'toolbar.end': ('End', 'Завершить'),
  'toolbar.mouseButtons': ('Mouse buttons', 'Кнопки мыши'),
  'mouse.left': ('Left', 'Левая'),
  'mouse.right': ('Right', 'Правая'),
  'mouse.left.a11y': ('Left mouse button', 'Левая кнопка мыши'),
  'mouse.right.a11y': ('Right mouse button', 'Правая кнопка мыши'),
  'mouse.drag': ('Drag to move', 'Перетащите, чтобы переместить'),

  'quality.auto': ('Auto', 'Авто'),
  'quality.speed': ('Speed (30 fps, low bandwidth)', 'Скорость (30 к/с, мало трафика)'),
  'quality.balanced': ('Balanced', 'Баланс'),
  'quality.quality': ('Quality (60 fps)', 'Качество (60 к/с)'),

  'stats.rtt': ('Latency', 'Задержка'),
  'stats.fps': ('FPS', 'Кадры/с'),
  'stats.bitrate': ('Bitrate', 'Битрейт'),
  'stats.loss': ('Loss', 'Потери'),
  'stats.resolution': ('Resolution', 'Разрешение'),
  'stats.codec': ('Codec', 'Кодек'),
  'stats.path': ('Path', 'Маршрут'),

  'key.back': ('Back', 'Назад'),
  'key.home': ('Home', 'Домой'),
  'key.recents': ('Recent apps', 'Недавние приложения'),
  'key.notifications': ('Notifications', 'Уведомления'),
  'key.power': ('Power menu', 'Меню питания'),
  'key.lock': ('Lock screen', 'Заблокировать экран'),
  'key.taskManager': ('Task Manager', 'Диспетчер задач'),

  // --- input_state banners (viewer: why the picture ignores us; host: what to fix) ---
  'session.input.permission': (
    'Control is unavailable: the remote device has not granted the permission to control it (Accessibility). The request is already shown on that device.',
    'Управление недоступно: на удалённом устройстве не выдано разрешение на управление (Универсальный доступ / Специальные возможности). Запрос уже показан на том устройстве.',
  ),
  'session.input.blocked': (
    'Windows blocks input into a window running as administrator. Switch to another window or run Thelxis as administrator.',
    'Windows блокирует ввод в окно, запущенное от имени администратора. Переключитесь на другое окно или запустите Thelxis от имени администратора.',
  ),
  'banner.input.permission.macos': (
    'Control is unavailable: grant Thelxis the "Accessibility" permission in System Settings. If the switch is already on, turn it off and on again.',
    'Управление недоступно: выдайте Thelxis разрешение „Универсальный доступ“ в Системных настройках. Если переключатель уже включён — выключите и включите его снова.',
  ),
  'banner.input.permission.android': (
    'Control is unavailable: turn on the Thelxis service in Settings → Accessibility. If it is already on, turn it off and on again.',
    'Управление недоступно: включите службу Thelxis в Настройках → «Специальные возможности». Если она уже включена — выключите и включите её снова.',
  ),
  'banner.input.openSettings': ('Open settings', 'Открыть настройки'),

  // --- files panel ---
  'files.unavailable': ('File transfer is not available yet', 'Передача файлов пока недоступна'),
  'files.unavailable.hint': (
    'The file channel opens right after the connection is authorized. Try again in a moment.',
    'Канал файлов открывается сразу после авторизации подключения. Повторите через мгновение.',
  ),
};
