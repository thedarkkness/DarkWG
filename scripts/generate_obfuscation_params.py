#!/usr/bin/env python3
"""Генератор валидных обфускационных параметров для тоннеля DarkWG (полный
набор, включая то, что добавилось в более новых версиях драйвера).

Ограничения на значения (проверено эмпирически и соответствует поведению
драйвера интерфейса):
  - Jc:  1 <= Jc <= 128            (рекомендуемый диапазон 4..12)
  - Jmin < Jmax <= 1280            (с учётом MTU)
  - S1 <= 1132, S2 <= 1188, S1 + 56 != S2
  - S3 <= 64, S4 <= 32             (паддинг Cookie Reply / Data-пакетов)
  - H1..H4: уникальные значения в диапазоне 5..2^32-1
  - I1..I5: decoy-пакеты перед хендшейком, формат CPS (<r N> — N случайных
    байт, <t> — таймстамп). Используем только случайный шум, не копируем
    готовые "похожие на протокол X" байт-сигнатуры из чужих проектов —
    если все используют один и тот же байт-снимок, это сам становится
    новой узнаваемой сигнатурой.

H1-H4, S1-S4 должны быть одинаковыми у сервера и ВСЕХ его клиентов.
Jc/Jmin/Jmax можно генерировать отдельно на каждом клиенте.
I1-I5 не обязаны совпадать (это decoy-пакеты, не часть самого хендшейка),
но мы всё равно выдаём одинаковые клиенту и серверу для простоты.
"""
from __future__ import annotations

import json
import secrets
from dataclasses import asdict, dataclass


@dataclass
class ObfuscationParams:
    Jc: int
    Jmin: int
    Jmax: int
    S1: int
    S2: int
    S3: int
    S4: int
    H1: int
    H2: int
    H3: int
    H4: int
    I1: str
    I2: str
    I3: str
    I4: str
    I5: str

    def as_conf_lines(self) -> str:
        return "\n".join(f"{k} = {v}" for k, v in asdict(self).items())


def _random_h() -> int:
    return secrets.randbelow(2**32 - 5) + 5  # диапазон 5..2^32-1


def _random_decoy_packet() -> str:
    """Чистый случайный шум разного размера, без копирования чужих
    байт-сигнатур — каждый деплой получает уникальный набор."""
    size = secrets.randbelow(241) + 16  # 16..256 байт
    if secrets.randbelow(2) == 0:
        return f"<r {size}><t>"
    return f"<r {size}>"


def generate_server_params() -> ObfuscationParams:
    """Параметры для сервера: H1-H4 уникальны, S1/S2 не нарушают S1+56 != S2."""
    h_values: set[int] = set()
    while len(h_values) < 4:
        h_values.add(_random_h())
    h1, h2, h3, h4 = h_values

    jc = secrets.randbelow(9) + 4          # 4..12
    jmin = secrets.randbelow(33) + 8       # 8..40
    jmax = min(jmin + secrets.randbelow(161) + 40, 1280)

    while True:
        s1 = secrets.randbelow(136) + 15   # 15..150
        s2 = secrets.randbelow(136) + 15   # 15..150
        if s1 + 56 != s2:
            break

    s3 = secrets.randbelow(65)             # 0..64
    s4 = secrets.randbelow(33)             # 0..32

    i1, i2, i3, i4, i5 = (_random_decoy_packet() for _ in range(5))

    return ObfuscationParams(
        Jc=jc, Jmin=jmin, Jmax=jmax,
        S1=s1, S2=s2, S3=s3, S4=s4,
        H1=h1, H2=h2, H3=h3, H4=h4,
        I1=i1, I2=i2, I3=i3, I4=i4, I5=i5,
    )


def client_jitter(server_params: ObfuscationParams) -> ObfuscationParams:
    """Для конкретного клиента можно (не обязательно) выдать свои Jc/Jmin/Jmax,
    остальное обязано совпадать с серверными — иначе хендшейк не пройдёт."""
    jc = secrets.randbelow(9) + 4
    jmin = secrets.randbelow(33) + 8
    jmax = min(jmin + secrets.randbelow(161) + 40, 1280)
    return ObfuscationParams(
        Jc=jc, Jmin=jmin, Jmax=jmax,
        S1=server_params.S1, S2=server_params.S2,
        S3=server_params.S3, S4=server_params.S4,
        H1=server_params.H1, H2=server_params.H2,
        H3=server_params.H3, H4=server_params.H4,
        I1=server_params.I1, I2=server_params.I2, I3=server_params.I3,
        I4=server_params.I4, I5=server_params.I5,
    )


if __name__ == "__main__":
    params = generate_server_params()
    print(json.dumps(asdict(params), indent=2))