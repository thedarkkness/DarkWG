"""SQLite-хранилище пиров. Намеренно без ORM — это маленький сервис,
SQLite более чем достаточно даже на тысячи активных пользователей.
"""
from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


SCHEMA = """
CREATE TABLE IF NOT EXISTS peers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    telegram_user_id INTEGER NOT NULL,
    public_key      TEXT NOT NULL UNIQUE,
    private_key     TEXT NOT NULL,
    ip_address      TEXT NOT NULL UNIQUE,
    created_at      TEXT NOT NULL,
    expires_at      TEXT,
    is_active       INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_peers_telegram_user_id ON peers(telegram_user_id);
"""


@dataclass
class Peer:
    id: int
    telegram_user_id: int
    public_key: str
    private_key: str
    ip_address: str
    created_at: str
    expires_at: str | None
    is_active: bool


class PeerStore:
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def create(
        self,
        telegram_user_id: int,
        public_key: str,
        private_key: str,
        ip_address: str,
        expires_at: str | None,
    ) -> Peer:
        created_at = datetime.now(timezone.utc).isoformat()
        with self._connect() as conn:
            cursor = conn.execute(
                """INSERT INTO peers
                   (telegram_user_id, public_key, private_key, ip_address, created_at, expires_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (telegram_user_id, public_key, private_key, ip_address, created_at, expires_at),
            )
            new_id = cursor.lastrowid
        # commit уже произошёл при выходе из `with` выше — теперь можно безопасно
        # читать через новое соединение
        peer = self.get(new_id)  # type: ignore[arg-type]
        assert peer is not None
        return peer

    def get(self, peer_id: int) -> Peer | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
            return self._row_to_peer(row) if row else None

    def get_by_telegram_id(self, telegram_user_id: int) -> list[Peer]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM peers WHERE telegram_user_id = ? ORDER BY created_at DESC",
                (telegram_user_id,),
            ).fetchall()
            return [self._row_to_peer(r) for r in rows]

    def list_all(self) -> list[Peer]:
        with self._connect() as conn:
            rows = conn.execute("SELECT * FROM peers ORDER BY created_at DESC").fetchall()
            return [self._row_to_peer(r) for r in rows]

    @staticmethod
    def _row_to_peer(row: sqlite3.Row) -> Peer:
        data = dict(row)
        data["is_active"] = bool(data["is_active"])
        return Peer(**data)

    def used_ips(self) -> set[str]:
        with self._connect() as conn:
            rows = conn.execute("SELECT ip_address FROM peers").fetchall()
            return {r["ip_address"] for r in rows}

    def delete(self, peer_id: int) -> Peer | None:
        peer = self.get(peer_id)
        if peer is None:
            return None
        with self._connect() as conn:
            conn.execute("DELETE FROM peers WHERE id = ?", (peer_id,))
        return peer

    def set_active(self, peer_id: int, is_active: bool) -> None:
        with self._connect() as conn:
            conn.execute("UPDATE peers SET is_active = ? WHERE id = ?", (int(is_active), peer_id))

    def extend_expiry(self, peer_id: int, new_expires_at: str | None) -> None:
        with self._connect() as conn:
            conn.execute("UPDATE peers SET expires_at = ? WHERE id = ?", (new_expires_at, peer_id))
