# ai-credits

Плагин [SwiftBar](https://github.com/swiftbar/SwiftBar) для macOS: лимиты **Claude**, **Dust** и **Meta Muse**
одной строкой в меню-баре (иконка + процент), детали — в выпадающем меню.

| Сервис | Что показывает | Источник |
|---|---|---|
| Claude | кредиты API, 5-часовой и недельный лимиты | OAuth-токен Claude Code из Keychain |
| Dust | fair-use лимит AWU-кредитов, сброс, расход по дням | OAuth-токен `dust-cli` из Keychain |
| Meta Muse | недельный процент, план, остаток токенов | веб-сессия muse.ai из Safari/Chrome |

Данные не сохраняются в открытом виде: токены и cookie читаются на лету, плагин не рефрешит токен Claude.
Резюме последнего запуска пишется в `~/.cache/ai-credits/summary.json`.

## Установка

1. Установить SwiftBar и вход в Claude Code (`claude`) и `dust login`.
2. Скопировать файлы:
   ```sh
   cp swiftbar/ai-credits.10m.sh ~/Library/Application\ Support/SwiftBar/Plugins/
   mkdir -p ~/.local/bin && cp bin/ai-credits-* ~/.local/bin/
   chmod +x ~/.local/bin/ai-credits-* ~/Library/Application\ Support/SwiftBar/Plugins/ai-credits.10m.sh
   ```
3. Иконки: `~/.local/bin/ai-credits-fetch-icons` (берёт их из установленных Claude.app и Muse.app и с dust.tt).
4. Для картинки в меню-баре нужен Pillow: `pip3 install pillow`. Без него показывается текст с эмодзи.
5. Интервал обновления задаётся суффиксом имени плагина (`.10m.sh` = 10 минут).

README не клади в папку `Plugins`: SwiftBar воспримет любой файл оттуда как плагин.

## Meta Muse

У muse.ai нет публичного usage-API. Скрипт `ai-credits-muse-usage` берёт cookie-сессию и вызывает Next.js
server action `fetchSubscriptionAction` (идея из проекта CodexBar). Cookie ищутся в таком порядке:

1. `~/.config/ai-credits/muse.cookie` — Cookie-заголовок вручную (подсказка: `ai-credits-muse-cookie`);
2. Chrome (расшифровка через «Chrome Safe Storage» из Keychain);
3. Safari (`~/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore/*/Cookies/Cookies.binarycookies`).

Нужно войти на muse.ai в браузере и выдать SwiftBar **Full Disk Access**
(Системные настройки → Конфиденциальность и безопасность), иначе macOS не даст прочитать cookie.

## Цвет текста в меню-баре

По умолчанию текст светлый (под тёмную полосу). Для светлой полосы: `AI_CREDITS_DARK=0`.

## Оговорки

* Это неофициальные эндпоинты: они могут измениться без предупреждения.
* Проценты и остатки нужно сверять с официальными интерфейсами сервисов.
