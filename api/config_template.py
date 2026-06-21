"""Сборка клиентского конфига и QR-кода для DarkWG-совместимых приложений."""
from __future__ import annotations

import base64
import io

import qrcode

from scripts.generate_obfuscation_params import ObfuscationParams


def build_client_config(
    *,
    client_private_key: str,
    client_ip: str,
    dns: str,
    obfuscation: ObfuscationParams,
    server_public_key: str,
    endpoint_host: str,
    endpoint_port: int,
) -> str:
    return (
        "[Interface]\n"
        f"PrivateKey = {client_private_key}\n"
        f"Address = {client_ip}/32\n"
        f"DNS = {dns}\n"
        f"{obfuscation.as_conf_lines()}\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {server_public_key}\n"
        f"Endpoint = {endpoint_host}:{endpoint_port}\n"
        "AllowedIPs = 0.0.0.0/0\n"
        "PersistentKeepalive = 25\n"
    )


def config_to_qr_base64(config_text: str) -> str:
    """Возвращает PNG QR-кода как base64-строку, готовую для вставки в JSON-ответ API."""
    img = qrcode.make(config_text)
    buffer = io.BytesIO()
    img.save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")
