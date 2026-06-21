"""Тонкая обёртка над CLI-инструментом DarkWG для управления интерфейсом тоннеля.

Все вызовы идут через subprocess — никакого парсинга .conf вручную,
источник правды — сам живой интерфейс ядра.
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass


class WireGuardError(RuntimeError):
    pass


def _run(args: list[str]) -> str:
    try:
        result = subprocess.run(
            args, check=True, capture_output=True, text=True, timeout=10
        )
        return result.stdout
    except subprocess.CalledProcessError as exc:
        raise WireGuardError(f"{' '.join(args)} failed: {exc.stderr.strip()}") from exc
    except subprocess.TimeoutExpired as exc:
        raise WireGuardError(f"{' '.join(args)} timed out") from exc


def generate_keypair() -> tuple[str, str]:
    """Возвращает (private_key, public_key) в base64, как у wg genkey/pubkey."""
    private_key = _run(["darkwg", "genkey"]).strip()
    public_key = subprocess.run(
        ["darkwg", "pubkey"], input=private_key, capture_output=True, text=True, check=True
    ).stdout.strip()
    return private_key, public_key


def add_peer(iface: str, public_key: str, allowed_ip: str) -> None:
    _run(["darkwg", "set", iface, "peer", public_key, "allowed-ips", f"{allowed_ip}/32"])


def remove_peer(iface: str, public_key: str) -> None:
    _run(["darkwg", "set", iface, "peer", public_key, "remove"])


@dataclass
class PeerStats:
    public_key: str
    endpoint: str | None
    allowed_ips: str
    latest_handshake: int  # unix timestamp, 0 если ещё не подключался
    transfer_rx: int
    transfer_tx: int


def dump_peers(iface: str) -> list[PeerStats]:
    """Парсит `awg show <iface> dump` — формат идентичен `wg show dump`:
    первая строка — данные интерфейса, далее одна строка на пира:
    public_key  preshared_key  endpoint  allowed_ips  latest_handshake  rx  tx  keepalive
    """
    output = _run(["darkwg", "show", iface, "dump"])
    lines = output.strip().splitlines()
    peers: list[PeerStats] = []
    for line in lines[1:]:  # первая строка — сам интерфейс, пропускаем
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        public_key, _preshared, endpoint, allowed_ips, handshake, rx, tx = parts[:7]
        peers.append(
            PeerStats(
                public_key=public_key,
                endpoint=None if endpoint == "(none)" else endpoint,
                allowed_ips=allowed_ips,
                latest_handshake=int(handshake),
                transfer_rx=int(rx),
                transfer_tx=int(tx),
            )
        )
    return peers
