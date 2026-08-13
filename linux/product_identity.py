"""Stable product identity used by BLE discovery before pairing."""

from __future__ import annotations

from pathlib import Path
import re

from generated_constants import PRODUCT_DISCOVERY_UUIDS


PRODUCTS = tuple(PRODUCT_DISCOVERY_UUIDS)
MAX_LE_LOCAL_NAME_BYTES = 29


def select_product(sys_vendor: str, product_name: str, override: str = "auto") -> str:
    if override != "auto":
        if override not in PRODUCTS:
            raise ValueError("unsupported product override")
        return override

    identity = f"{sys_vendor} {product_name}".lower()
    if "gigabyte" in identity or "ai top atom" in identity:
        return "gigabyte"
    if "nvidia" in identity or "dgx spark" in identity:
        return "nvidia"
    return "generic"


def detect_product(override: str = "auto") -> str:
    def read_dmi(name: str) -> str:
        try:
            return Path(f"/sys/class/dmi/id/{name}").read_text().strip()
        except OSError:
            return ""

    return select_product(read_dmi("sys_vendor"), read_dmi("product_name"), override)


def advertised_name(hostname: str) -> str:
    """Return the hostname shown as the AccessorySetupKit picker subtitle."""
    safe_hostname = re.sub(r"[^A-Za-z0-9._-]+", "-", hostname).strip("-.")
    if not safe_hostname:
        return "autowifi"
    return safe_hostname[:MAX_LE_LOCAL_NAME_BYTES]
