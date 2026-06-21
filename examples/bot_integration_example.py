"""Пример того, как дёргать DarkWG API из aiogram-бота DarkVPN.

Это не готовый хендлер, а шаблон — встрой логику в свой существующий
модуль работы с подписками рядом с тем местом, где сейчас вызывается
RemnaWave API для VLESS/Hysteria.
"""
from __future__ import annotations

import httpx

DARKWG_API_BASE = "http://127.0.0.1:8765"  # API слушает только локально на ноде
DARKWG_API_KEY = "..."  # бери из своего .env, см. /etc/darkwg/api.env на ноде


async def issue_darkwg_config(telegram_user_id: int, ttl_days: int | None = 30) -> dict:
    """Выдаёт пользователю новый DarkWG-конфиг. Вызывать при покупке/продлении подписки."""
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            f"{DARKWG_API_BASE}/peers",
            headers={"X-API-Key": DARKWG_API_KEY},
            json={"telegram_user_id": telegram_user_id, "ttl_days": ttl_days},
        )
        response.raise_for_status()
        return response.json()  # {"id": ..., "config_text": "...", "qr_base64": "...", ...}


async def revoke_darkwg_config(peer_id: int) -> None:
    """Отзывает конфиг — вызывать при истечении/отмене подписки."""
    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.delete(
            f"{DARKWG_API_BASE}/peers/{peer_id}",
            headers={"X-API-Key": DARKWG_API_KEY},
        )
        response.raise_for_status()


# --- Пример хендлера aiogram ---
#
# from aiogram import Router, types
# from aiogram.filters import Command
# import base64
# from io import BytesIO
#
# router = Router()
#
# @router.message(Command("get_darkwg"))
# async def cmd_get_darkwg(message: types.Message) -> None:
#     result = await issue_darkwg_config(message.from_user.id, ttl_days=30)
#
#     qr_bytes = base64.b64decode(result["qr_base64"])
#     await message.answer_photo(
#         photo=types.BufferedInputFile(qr_bytes, filename="darkwg.png"),
#         caption="Отсканируй QR в приложении DarkWG.",
#     )
#     await message.answer_document(
#         document=types.BufferedInputFile(
#             result["config_text"].encode(), filename="darkwg.conf"
#         ),
#         caption="Или импортируй файл конфигурации напрямую.",
#     )
#
#     # Сохрани result["id"] (peer_id) в своей таблице подписок,
#     # чтобы потом можно было вызвать revoke_darkwg_config при истечении.
