"""Выделение свободного IP из подсети тоннеля.

Резервирует .1 под сам сервер, .0 и широковещательный адрес не выдаёт.
"""
from __future__ import annotations

import ipaddress


class IPPoolExhausted(RuntimeError):
    pass


def allocate_ip(subnet_cidr: str, used_ips: set[str], server_ip: str) -> str:
    network = ipaddress.ip_network(subnet_cidr, strict=False)
    reserved = used_ips | {server_ip}
    for host in network.hosts():
        host_str = str(host)
        if host_str not in reserved:
            return host_str
    raise IPPoolExhausted(f"В подсети {subnet_cidr} не осталось свободных адресов")
