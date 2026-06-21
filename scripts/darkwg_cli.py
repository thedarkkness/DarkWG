#!/usr/bin/env python3
"""DarkWG CLI — управление пирами напрямую с сервера, без похода в API.

Использует ту же логику и ту же базу (/etc/darkwg/api.env), что и REST API,
так что пиры, созданные через CLI, сразу видны через API и наоборот.

Примеры:
    darkwg-cli add-peer --telegram-user-id 0 --ttl-days 0 --out /etc/darkwg/peers/peer1
    darkwg-cli list-peers
    darkwg-cli remove-peer --id 1
"""
from __future__ import annotations

import argparse
import base64
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, "/opt/darkwg")

from dotenv import load_dotenv  # noqa: E402

load_dotenv("/etc/darkwg/api.env")

from api import wireguard  # noqa: E402
from api.config_template import build_client_config, config_to_qr_base64  # noqa: E402
from api.database import PeerStore  # noqa: E402
from api.ip_pool import IPPoolExhausted, allocate_ip  # noqa: E402
from scripts.generate_obfuscation_params import ObfuscationParams  # noqa: E402

IFACE = os.environ.get("DARKWG_IFACE", "darkwg0")
SUBNET = os.environ.get("DARKWG_SUBNET", "10.13.0.0/16")
SERVER_IP = os.environ.get("DARKWG_SERVER_IP", "10.13.0.1")
SERVER_PUBLIC_KEY = os.environ["DARKWG_SERVER_PUBLIC_KEY"]
ENDPOINT_HOST = os.environ["DARKWG_ENDPOINT_HOST"]
ENDPOINT_PORT = int(os.environ.get("DARKWG_ENDPOINT_PORT", "28741"))
CLIENT_DNS = os.environ.get("DARKWG_CLIENT_DNS", "1.1.1.1")
DB_PATH = os.environ.get("DARKWG_DB_PATH", "/opt/darkwg/darkwg.db")

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


def cmd_add_peer(args: argparse.Namespace) -> None:
    private_key, public_key = wireguard.generate_keypair()
    ip_address = allocate_ip(SUBNET, store.used_ips(), SERVER_IP)

    expires_at = None
    if args.ttl_days and args.ttl_days > 0:
        expires_at = (datetime.now(timezone.utc) + timedelta(days=args.ttl_days)).isoformat()

    wireguard.add_peer(IFACE, public_key, ip_address)
    peer = store.create(
        telegram_user_id=args.telegram_user_id,
        public_key=public_key,
        private_key=private_key,
        ip_address=ip_address,
        expires_at=expires_at,
    )

    config_text = build_client_config(
        client_private_key=private_key,
        client_ip=ip_address,
        dns=CLIENT_DNS,
        obfuscation=OBFUSCATION,
        server_public_key=SERVER_PUBLIC_KEY,
        endpoint_host=ENDPOINT_HOST,
        endpoint_port=ENDPOINT_PORT,
    )

    print(f"Создан пир #{peer.id}, IP {ip_address}")

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.with_suffix(".conf").write_text(config_text)
        qr_png = base64.b64decode(config_to_qr_base64(config_text))
        out_path.with_suffix(".png").write_bytes(qr_png)
        print(f"Конфиг:  {out_path.with_suffix('.conf')}")
        print(f"QR-код:  {out_path.with_suffix('.png')}")
    else:
        print(config_text)


def cmd_list_peers(_: argparse.Namespace) -> None:
    peers = store.list_all()
    if not peers:
        print("Пиров нет")
        return
    for peer in peers:
        status = "активен" if peer.is_active else "выключен"
        print(f"#{peer.id}  tg={peer.telegram_user_id}  ip={peer.ip_address}  {status}  создан={peer.created_at}")


def cmd_remove_peer(args: argparse.Namespace) -> None:
    peer = store.delete(args.id)
    if peer is None:
        print(f"Пир #{args.id} не найден", file=sys.stderr)
        sys.exit(1)
    try:
        wireguard.remove_peer(IFACE, peer.public_key)
    except wireguard.WireGuardError:
        pass
    print(f"Пир #{args.id} удалён")


def main() -> None:
    parser = argparse.ArgumentParser(description="DarkWG CLI")
    subparsers = parser.add_subparsers(required=True)

    add_parser = subparsers.add_parser("add-peer")
    add_parser.add_argument("--telegram-user-id", type=int, required=True)
    add_parser.add_argument("--ttl-days", type=int, default=0, help="0 = бессрочно")
    add_parser.add_argument("--out", type=str, default=None, help="путь без расширения для .conf/.png")
    add_parser.set_defaults(func=cmd_add_peer)

    list_parser = subparsers.add_parser("list-peers")
    list_parser.set_defaults(func=cmd_list_peers)

    remove_parser = subparsers.add_parser("remove-peer")
    remove_parser.add_argument("--id", type=int, required=True)
    remove_parser.set_defaults(func=cmd_remove_peer)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
