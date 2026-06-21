"""DarkWG API — управление пирами VPN-тоннеля для интеграции с телеграм-ботом.

Запуск (из корня репозитория):
    uvicorn api.main:app --host 127.0.0.1 --port 8765

Настройки берутся из переменных окружения (см. /etc/darkwg/api.env),
который читается через python-dotenv при старте.
"""
from __future__ import annotations

import os
import secrets
from datetime import datetime, timedelta, timezone

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from api import wireguard
from api.config_template import build_client_config, config_to_qr_base64
from api.database import PeerStore
from api.ip_pool import IPPoolExhausted, allocate_ip
from scripts.generate_obfuscation_params import ObfuscationParams

load_dotenv("/etc/darkwg/api.env")

IFACE = os.environ.get("DARKWG_IFACE", "darkwg0")
SUBNET = os.environ.get("DARKWG_SUBNET", "10.13.0.0/16")
SERVER_IP = os.environ.get("DARKWG_SERVER_IP", "10.13.0.1")
SERVER_PUBLIC_KEY = os.environ["DARKWG_SERVER_PUBLIC_KEY"]
ENDPOINT_HOST = os.environ["DARKWG_ENDPOINT_HOST"]
ENDPOINT_PORT = int(os.environ.get("DARKWG_ENDPOINT_PORT", "28741"))
CLIENT_DNS = os.environ.get("DARKWG_CLIENT_DNS", "1.1.1.1")
DB_PATH = os.environ.get("DARKWG_DB_PATH", "/opt/darkwg/darkwg.db")
API_KEY = os.environ["DARKWG_API_KEY"]

OBFUSCATION = ObfuscationParams(
    Jc=int(os.environ["DARKWG_JC"]),
    Jmin=int(os.environ["DARKWG_JMIN"]),
    Jmax=int(os.environ["DARKWG_JMAX"]),
    S1=int(os.environ["DARKWG_S1"]),
    S2=int(os.environ["DARKWG_S2"]),
    H1=int(os.environ["DARKWG_H1"]),
    H2=int(os.environ["DARKWG_H2"]),
    H3=int(os.environ["DARKWG_H3"]),
    H4=int(os.environ["DARKWG_H4"]),
)

store = PeerStore(DB_PATH)
app = FastAPI(title="DarkWG API", version="1.0.0")


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if x_api_key is None or not secrets.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=401, detail="invalid API key")


class CreatePeerRequest(BaseModel):
    telegram_user_id: int
    ttl_days: int | None = None  # None = бессрочно (например, на пробный период)


class PeerResponse(BaseModel):
    id: int
    telegram_user_id: int
    ip_address: str
    created_at: str
    expires_at: str | None
    is_active: bool
    config_text: str | None = None
    qr_base64: str | None = None


def _peer_to_response(peer, include_config: bool = False) -> PeerResponse:
    config_text = None
    qr_base64 = None
    if include_config:
        config_text = build_client_config(
            client_private_key=peer.private_key,
            client_ip=peer.ip_address,
            dns=CLIENT_DNS,
            obfuscation=OBFUSCATION,
            server_public_key=SERVER_PUBLIC_KEY,
            endpoint_host=ENDPOINT_HOST,
            endpoint_port=ENDPOINT_PORT,
        )
        qr_base64 = config_to_qr_base64(config_text)
    return PeerResponse(
        id=peer.id,
        telegram_user_id=peer.telegram_user_id,
        ip_address=peer.ip_address,
        created_at=peer.created_at,
        expires_at=peer.expires_at,
        is_active=bool(peer.is_active),
        config_text=config_text,
        qr_base64=qr_base64,
    )


@app.post("/peers", response_model=PeerResponse, dependencies=[Depends(require_api_key)])
def create_peer(body: CreatePeerRequest) -> PeerResponse:
    private_key, public_key = wireguard.generate_keypair()

    try:
        ip_address = allocate_ip(SUBNET, store.used_ips(), SERVER_IP)
    except IPPoolExhausted as exc:
        raise HTTPException(status_code=507, detail=str(exc)) from exc

    expires_at = None
    if body.ttl_days is not None:
        expires_at = (datetime.now(timezone.utc) + timedelta(days=body.ttl_days)).isoformat()

    wireguard.add_peer(IFACE, public_key, ip_address)

    peer = store.create(
        telegram_user_id=body.telegram_user_id,
        public_key=public_key,
        private_key=private_key,
        ip_address=ip_address,
        expires_at=expires_at,
    )
    return _peer_to_response(peer, include_config=True)


@app.get("/peers", response_model=list[PeerResponse], dependencies=[Depends(require_api_key)])
def list_peers() -> list[PeerResponse]:
    return [_peer_to_response(p) for p in store.list_all()]


@app.get(
    "/peers/by-user/{telegram_user_id}",
    response_model=list[PeerResponse],
    dependencies=[Depends(require_api_key)],
)
def list_peers_by_user(telegram_user_id: int) -> list[PeerResponse]:
    return [_peer_to_response(p) for p in store.get_by_telegram_id(telegram_user_id)]


@app.get("/peers/{peer_id}", response_model=PeerResponse, dependencies=[Depends(require_api_key)])
def get_peer(peer_id: int) -> PeerResponse:
    peer = store.get(peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="peer not found")
    return _peer_to_response(peer, include_config=True)


@app.delete("/peers/{peer_id}", dependencies=[Depends(require_api_key)])
def delete_peer(peer_id: int) -> dict:
    peer = store.delete(peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="peer not found")
    try:
        wireguard.remove_peer(IFACE, peer.public_key)
    except wireguard.WireGuardError:
        # пир уже мог быть удалён из живого интерфейса вручную — это не блокирующая ошибка
        pass
    return {"deleted": peer_id}


@app.post("/peers/{peer_id}/disable", dependencies=[Depends(require_api_key)])
def disable_peer(peer_id: int) -> dict:
    peer = store.get(peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="peer not found")
    wireguard.remove_peer(IFACE, peer.public_key)
    store.set_active(peer_id, False)
    return {"disabled": peer_id}


@app.post("/peers/{peer_id}/enable", dependencies=[Depends(require_api_key)])
def enable_peer(peer_id: int) -> dict:
    peer = store.get(peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="peer not found")
    wireguard.add_peer(IFACE, peer.public_key, peer.ip_address)
    store.set_active(peer_id, True)
    return {"enabled": peer_id}


@app.get("/stats", dependencies=[Depends(require_api_key)])
def stats() -> list[dict]:
    """Живая статистика прямо с интерфейса — handshake/трафик по каждому пиру."""
    by_pubkey = {p.public_key: p for p in store.list_all()}
    result = []
    for peer_stat in wireguard.dump_peers(IFACE):
        peer = by_pubkey.get(peer_stat.public_key)
        result.append(
            {
                "peer_id": peer.id if peer else None,
                "telegram_user_id": peer.telegram_user_id if peer else None,
                "public_key": peer_stat.public_key,
                "endpoint": peer_stat.endpoint,
                "latest_handshake": peer_stat.latest_handshake,
                "transfer_rx": peer_stat.transfer_rx,
                "transfer_tx": peer_stat.transfer_tx,
            }
        )
    return result


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
