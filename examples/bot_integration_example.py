"""Шаблон полного цикла подписки DarkWG в aiogram-боте DarkVPN.

Архитектура:
  Бот + RemnaWave + БД  ->  Финляндия, 144.31.182.217
  DarkWG API             ->  Нидерланды (нода), за nginx с TLS на
                              https://darkwg-api.jawsofplanet.space
                              (см. nginx/darkwg-api.conf.example)

Это не готовый хендлер, а шаблон — встрой в свой существующий модуль
подписок рядом с тем местом, где сейчас вызывается RemnaWave API.
"""
from __future__ import annotations

import base64

import httpx

DARKWG_API_BASE = "https://darkwg-api.jawsofplanet.space"
DARKWG_API_KEY = "..."  # бери из /etc/darkwg/api.env на ноде, храни в .env бота

# Официальные клиенты — куда отправлять пользователя за приложением
DARKWG_ANDROID_URL = "https://play.google.com/store/apps/details?id=org.amnezia.awg"
DARKWG_IOS_SEARCH_HINT = "Найди в App Store по запросу: AmneziaWG"
DARKWG_DESKTOP_HINT = "Windows/macOS/Linux — ищи 'AmneziaWG' на странице релизов проекта"


async def _api_request(method: str, path: str, **kwargs) -> dict:
    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.request(
            method, f"{DARKWG_API_BASE}{path}",
            headers={"X-API-Key": DARKWG_API_KEY},
            **kwargs,
        )
        response.raise_for_status()
        return response.json()


async def issue_subscription(telegram_user_id: int, ttl_days: int = 30) -> dict:
    """Вызывать сразу после успешной оплаты. Возвращает peer_id, config_text, qr_base64."""
    return await _api_request(
        "POST", "/peers",
        json={"telegram_user_id": telegram_user_id, "ttl_days": ttl_days},
    )


async def extend_subscription(peer_id: int, add_days: int) -> dict:
    """Вызывать при успешной оплате продления существующей подписки."""
    return await _api_request(
        "POST", f"/peers/{peer_id}/extend",
        json={"add_days": add_days},
    )


async def revoke_subscription(peer_id: int) -> None:
    """Вызывать при возврате/чарджбэке/ручной блокировке."""
    await _api_request("DELETE", f"/peers/{peer_id}")


async def get_user_peers(telegram_user_id: int) -> list[dict]:
    """Узнать, есть ли у пользователя уже выданный пир (чтобы не плодить дубликаты)."""
    return await _api_request("GET", f"/peers/by-user/{telegram_user_id}")


# --- Пример хендлеров aiogram ---
#
# from aiogram import Router, types, F
# from aiogram.filters import Command
# from aiogram.types import BufferedInputFile, InlineKeyboardMarkup, InlineKeyboardButton
#
# router = Router()
#
#
# @router.callback_query(F.data == "buy_darkwg_30d")
# async def on_payment_success_darkwg(callback: types.CallbackQuery) -> None:
#     """Вызывается из твоего существующего YooKassa-вебхука после успешной оплаты."""
#     telegram_id = callback.from_user.id
#
#     # Если у пользователя уже есть активный пир — продлеваем, а не создаём новый
#     existing = await get_user_peers(telegram_id)
#     active = [p for p in existing if p["is_active"]]
#
#     if active:
#         result = await extend_subscription(active[0]["id"], add_days=30)
#     else:
#         result = await issue_subscription(telegram_id, ttl_days=30)
#
#     qr_bytes = base64.b64decode(result["qr_base64"])
#     keyboard = InlineKeyboardMarkup(inline_keyboard=[
#         [InlineKeyboardButton(text="Скачать AmneziaWG (Android)", url=DARKWG_ANDROID_URL)],
#     ])
#
#     await callback.message.answer_photo(
#         photo=BufferedInputFile(qr_bytes, filename="darkwg.png"),
#         caption=(
#             "Подписка DarkWG активирована на 30 дней.\n\n"
#             "1) Установи приложение по кнопке ниже (или найди 'AmneziaWG' в App Store/на Windows)\n"
#             "2) Открой приложение → ➕ → Create from QR code → отсканируй это фото\n"
#             "Или импортируй файл конфигурации ниже, если приложение просит файл."
#         ),
#         reply_markup=keyboard,
#     )
#     await callback.message.answer_document(
#         document=BufferedInputFile(result["config_text"].encode(), filename="darkwg.conf"),
#         caption="Файл конфигурации — если приложение просит загрузить файл, а не QR.",
#     )
#
#     # Сохрани result["id"] (peer_id) в своей таблице подписок —
#     # пригодится для продления/отзыва в будущем.
#
#
# @router.message(Command("my_darkwg"))
# async def cmd_my_darkwg_status(message: types.Message) -> None:
#     """Показать пользователю статус его текущей подписки."""
#     peers = await get_user_peers(message.from_user.id)
#     if not peers:
#         await message.answer("У тебя пока нет активной подписки DarkWG.")
#         return
#     peer = peers[0]
#     status = "активна" if peer["is_active"] else "истекла"
#     await message.answer(
#         f"Статус: {status}\n"
#         f"Действует до: {peer['expires_at']}\n"
#     )
