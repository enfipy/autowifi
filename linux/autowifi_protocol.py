"""Autowifi v1 framing, validation, and NetworkManager mapping.

This module deliberately has no BlueZ or D-Bus dependency so its security-
critical parsing contract can run in CI and on macOS. A BlueZ GATT characteristic
feeds write chunks to FrameDecoder; a NetworkManager adapter consumes the
validated NetworkCredential.settings() result without logging it.
"""

from __future__ import annotations

import base64
import binascii
import json
import struct
import uuid
from dataclasses import dataclass
from typing import Any


MAX_PAYLOAD_BYTES = 65_536
SUPPORTED_SECURITY = frozenset({"open", "owe", "wpa2", "wpa3"})


class ProtocolError(ValueError):
    """A peer sent a malformed or unsupported message."""


class FrameDecoder:
    """Incrementally decode uint32-be length-prefixed payloads."""

    def __init__(self, maximum_payload_bytes: int = MAX_PAYLOAD_BYTES) -> None:
        self._buffer = bytearray()
        self._maximum = maximum_payload_bytes

    def feed(self, chunk: bytes) -> list[bytes]:
        self._buffer.extend(chunk)
        payloads: list[bytes] = []

        while len(self._buffer) >= 4:
            length = struct.unpack_from(">I", self._buffer)[0]
            if length == 0 or length > self._maximum:
                self._buffer.clear()
                raise ProtocolError("invalid frame length")
            if len(self._buffer) < 4 + length:
                break
            payloads.append(bytes(self._buffer[4 : 4 + length]))
            del self._buffer[: 4 + length]

        return payloads


@dataclass(frozen=True)
class NetworkCredential:
    request_id: str
    ssid: bytes
    hidden: bool
    security: frozenset[str]
    password: str | None

    @classmethod
    def from_payload(cls, payload: bytes) -> "NetworkCredential":
        try:
            document = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProtocolError("payload is not UTF-8 JSON") from error

        if not isinstance(document, dict):
            raise ProtocolError("payload root must be an object")
        if document.get("version") != 1 or document.get("type") != "wifi-credential":
            raise ProtocolError("unsupported message version or type")

        request_id = document.get("requestID")
        hidden = document.get("hidden")
        security_value = document.get("security")
        credential = document.get("credential")
        if not isinstance(request_id, str) or not request_id:
            raise ProtocolError("requestID must be a nonempty string")
        try:
            request_id = str(uuid.UUID(request_id))
        except ValueError as error:
            raise ProtocolError("requestID must be a UUID") from error
        if not isinstance(hidden, bool):
            raise ProtocolError("hidden must be a boolean")
        if not isinstance(security_value, list) or not security_value:
            raise ProtocolError("security must be a nonempty array")
        if not all(isinstance(item, str) for item in security_value):
            raise ProtocolError("security entries must be strings")

        security = frozenset(security_value)
        if not security <= SUPPORTED_SECURITY:
            raise ProtocolError("unsupported security policy")
        if not isinstance(credential, dict):
            raise ProtocolError("credential must be an object")

        try:
            ssid = base64.b64decode(document.get("ssid", ""), validate=True)
        except (binascii.Error, ValueError, TypeError) as error:
            raise ProtocolError("ssid must be valid base64") from error
        if not 1 <= len(ssid) <= 32:
            raise ProtocolError("SSID must contain 1 to 32 bytes")

        kind = credential.get("kind")
        password_value = credential.get("password")
        if kind == "none":
            if password_value is not None:
                raise ProtocolError("credential kind none cannot carry a password")
            password = None
        elif kind == "password":
            if not isinstance(password_value, str) or not password_value:
                raise ProtocolError("password credential requires a nonempty password")
            password = password_value
        else:
            raise ProtocolError("unsupported credential kind")

        is_open = security == {"open"}
        is_owe = "owe" in security and security <= {"open", "owe"}
        is_personal = security <= {"wpa2", "wpa3"}
        if not (is_open or is_owe or is_personal):
            raise ProtocolError("incompatible security policy combination")
        if (is_open or is_owe) and password is not None:
            raise ProtocolError("open/OWE networks cannot carry a password")
        if is_personal and password is None:
            raise ProtocolError("personal network requires a password")

        return cls(request_id, ssid, hidden, security, password)

    def networkmanager_settings(self) -> dict[str, dict[str, Any]]:
        """Return the logical a{sa{sv}} profile for NetworkManager D-Bus.

        A real adapter must wrap values in its D-Bus library's Variant type.
        The password stays a value, never a shell argument.
        """

        settings: dict[str, dict[str, Any]] = {
            "connection": {
                "id": f"autowifi-{self.request_id}",
                "type": "802-11-wireless",
                "autoconnect": True,
            },
            "802-11-wireless": {
                "ssid": self.ssid,
                "hidden": self.hidden,
                "mode": "infrastructure",
            },
            "ipv4": {"method": "auto"},
            "ipv6": {"method": "auto"},
        }

        if self.security != {"open"}:
            if "owe" in self.security and self.security <= {"open", "owe"}:
                key_management = "owe"
            elif self.security == {"wpa3"}:
                key_management = "sae"
            else:
                key_management = "wpa-psk"

            wireless_security: dict[str, Any] = {"key-mgmt": key_management}
            if self.password is not None:
                wireless_security["psk"] = self.password
            settings["802-11-wireless-security"] = wireless_security

        return settings


def frame(payload: bytes) -> bytes:
    if not payload or len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtocolError("invalid frame length")
    return struct.pack(">I", len(payload)) + payload
