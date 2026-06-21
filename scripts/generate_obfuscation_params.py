#!/usr/bin/env python3
"""Генератор валидных обфускационных параметров для тоннеля DarkWG.

Ограничения на значения (проверено эмпирически и соответствует поведению
драйвера интерфейса):
  - Jc:  1 <= Jc <= 128            (рекомендуемый диапазон 4..12)
  - Jmin < Jmax <= 1280            (с учётом MTU)
  - S1 <= 1132, S2 <= 1188, S1 + 56 != S2
  - H1..H4: уникальные значения в диапазоне 5..2^32-1

H1-H4 и S1/S2 должны быть одинаковыми у сервера и ВСЕХ его клиентов.
Jc/Jmin/Jmax можно генерировать отдельно на каждом клиенте.
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
    H1: int
    H2: int
    H3: int
    H4: int

    def as_conf_lines(self) -> str:
        return "\n".join(f"{k} = {v}" for k, v in asdict(self).items())


def _random_h() -> int:
    return secrets.randbelow(2**32 - 5) + 5  # диапазон 5..2^32-1


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

    return ObfuscationParams(Jc=jc, Jmin=jmin, Jmax=jmax, S1=s1, S2=s2, H1=h1, H2=h2, H3=h3, H4=h4)


def client_jitter(server_params: ObfuscationParams) -> ObfuscationParams:
    """Для конкретного клиента можно (не обязательно) выдать свои Jc/Jmin/Jmax,
    H1-H4/S1/S2 обязаны совпадать с серверными — иначе хендшейк не пройдёт."""
    jc = secrets.randbelow(9) + 4
    jmin = secrets.randbelow(33) + 8
    jmax = min(jmin + secrets.randbelow(161) + 40, 1280)
    return ObfuscationParams(
        Jc=jc, Jmin=jmin, Jmax=jmax,
        S1=server_params.S1, S2=server_params.S2,
        H1=server_params.H1, H2=server_params.H2,
        H3=server_params.H3, H4=server_params.H4,
    )


if __name__ == "__main__":
    params = generate_server_params()
    print(json.dumps(asdict(params), indent=2))
