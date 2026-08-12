"""Stable product identity used by BLE discovery before pairing."""

from __future__ import annotations

from pathlib import Path

from generated_constants import PRODUCT_ADVERTISED_NAMES


PRODUCTS = tuple(PRODUCT_ADVERTISED_NAMES)


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


def advertised_name(product: str) -> str:
    return PRODUCT_ADVERTISED_NAMES[product]
