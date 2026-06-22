# DarkWG

Самостоятельный VPN-туннель с обфускацией трафика против DPI-блокировок +
REST API для управления пользователями. Один Docker-контейнер `darkwg` —
туннель и API, опциональный `darkwg-nginx` — внешний HTTPS-доступ к API.

## Установка — одной командой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/thedarkkness/DarkWG/main/install.sh)
```

Скрипт сам спросит, что нужно (режим установки, порт — по умолчанию 443),
поставит Docker и ядерный модуль, поднимет туннель, API и первого
тестового пользователя. На каждом вопросе `0` — вернуться назад,
на первом экране `0` — выйти.

Подробности про архитектуру, режимы установки и ACME-сертификаты —
в [ADVANCED.md](ADVANCED.md).

## Что получаешь после установки

В конце скрипт покажет:
- публичный ключ сервера
- ключ для REST API (`DARKWG_API_KEY`)
- готового первого пользователя — `.conf` и QR в `/etc/darkwg/peers/peer1.*`

Посмотреть QR прямо в терминале, без скачивания:

```bash
qrencode -t ansiutf8 < /etc/darkwg/peers/peer1.conf
```

## Управление пользователями

**Через CLI:**

```bash
docker compose -f docker-compose.generated.yml exec darkwg \
  python3 scripts/darkwg_cli.py add-peer --telegram-user-id 123456789 --ttl-days 30 \
  --out /etc/darkwg/peers/user_123456789

docker compose -f docker-compose.generated.yml exec darkwg \
  python3 scripts/darkwg_cli.py list-peers
```

**Через REST API** (заголовок `X-API-Key`, значение в `/etc/darkwg/api.env`):

| Метод  | Путь                  | Что делает                |
|--------|------------------------|---------------------------|
| POST   | `/peers`               | Создать пользователя      |
| GET    | `/peers`               | Список пользователей      |
| DELETE | `/peers/{id}`          | Отозвать доступ            |
| POST   | `/peers/{id}/extend`   | Продлить подписку         |
| GET    | `/stats`               | Статистика трафика         |

Полный список эндпоинтов, пример интеграции с Telegram-ботом и схема
"бот на одном сервере / нода на другом" — в [ADVANCED.md](ADVANCED.md)
и `examples/bot_integration_example.py`.

## Подключение клиента

Импортируй `.conf` или отсканируй QR в любом приложении, совместимом с
обфускацией AmneziaWG (например, официальное приложение AmneziaWG).

## Лицензия

В репозитории пока нет файла `LICENSE`. Сам туннельный протокол ставится
отдельно через системный пакетный менеджер на условиях GPLv2 от своего
проекта — это не код из этого репозитория, поэтому обязательств на сам
код здесь это не накладывает.