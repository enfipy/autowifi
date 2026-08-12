"""Encrypted Autowifi GATT application exposed through BlueZ D-Bus."""

from __future__ import annotations

from collections.abc import Callable

import dbus
import dbus.exceptions
import dbus.service
from gi.repository import GLib

from autowifi_protocol import FrameDecoder, ProtocolError, frame, transport_reply
from generated_constants import CREDENTIAL_RX_UUID, SERVICE_UUID, STATUS_TX_UUID

DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"
DBUS_OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
GATT_MANAGER = "org.bluez.GattManager1"
GATT_SERVICE = "org.bluez.GattService1"
GATT_CHARACTERISTIC = "org.bluez.GattCharacteristic1"
ROOT_PATH = "/com/enfipy/autowifi"
FORGET_DELAY_MILLISECONDS = 750


class InvalidArguments(dbus.exceptions.DBusException):
    _dbus_error_name = "org.freedesktop.DBus.Error.InvalidArgs"


class NotSupported(dbus.exceptions.DBusException):
    _dbus_error_name = "org.bluez.Error.NotSupported"


class InvalidValueLength(dbus.exceptions.DBusException):
    _dbus_error_name = "org.bluez.Error.InvalidValueLength"


class Rejected(dbus.exceptions.DBusException):
    _dbus_error_name = "org.bluez.Error.Rejected"


class DBusObject(dbus.service.Object):
    interface_name: str

    @dbus.service.method(DBUS_PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface_name: str) -> dict:
        if interface_name != self.interface_name:
            raise InvalidArguments(f"unknown interface: {interface_name}")
        return self.properties()

    def properties(self) -> dict:
        raise NotImplementedError


class Service(DBusObject):
    interface_name = GATT_SERVICE

    def __init__(self, bus: dbus.SystemBus) -> None:
        self.path = f"{ROOT_PATH}/service0"
        self.characteristics: list[Characteristic] = []
        super().__init__(bus, self.path)

    def properties(self) -> dict:
        return {
            "UUID": dbus.String(SERVICE_UUID),
            "Primary": dbus.Boolean(True),
            "Includes": dbus.Array([], signature="o"),
        }


class Characteristic(DBusObject):
    interface_name = GATT_CHARACTERISTIC

    def __init__(
        self,
        bus: dbus.SystemBus,
        path: str,
        uuid: str,
        service: Service,
        flags: list[str],
    ) -> None:
        self.path = path
        self.uuid = uuid
        self.service = service
        self.flags = flags
        super().__init__(bus, path)

    def properties(self) -> dict:
        return {
            "Service": dbus.ObjectPath(self.service.path),
            "UUID": dbus.String(self.uuid),
            "Flags": dbus.Array(self.flags, signature="s"),
        }

    @dbus.service.method(GATT_CHARACTERISTIC, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, _options: dict) -> dbus.Array:
        raise NotSupported("read is not supported")

    @dbus.service.method(GATT_CHARACTERISTIC, in_signature="aya{sv}")
    def WriteValue(self, _value: dbus.Array, _options: dict) -> None:
        raise NotSupported("write is not supported")

    @dbus.service.method(GATT_CHARACTERISTIC)
    def StartNotify(self) -> None:
        raise NotSupported("notify is not supported")

    @dbus.service.method(GATT_CHARACTERISTIC)
    def StopNotify(self) -> None:
        raise NotSupported("notify is not supported")

    @dbus.service.signal(DBUS_PROPERTIES, signature="sa{sv}as")
    def PropertiesChanged(self, _interface: str, _changed: dict, _invalidated: list[str]) -> None:
        pass


class StatusCharacteristic(Characteristic):
    def __init__(self, bus: dbus.SystemBus, service: Service) -> None:
        super().__init__(
            bus,
            f"{service.path}/char1",
            STATUS_TX_UUID,
            service,
            ["notify", "encrypt-read"],
        )
        self.notifying = False
        self.value = b""

    def properties(self) -> dict:
        result = super().properties()
        result.update(
            {
                "Notifying": dbus.Boolean(self.notifying),
                "Value": dbus.Array(self.value, signature="y"),
            }
        )
        return result

    @dbus.service.method(GATT_CHARACTERISTIC)
    def StartNotify(self) -> None:
        self.notifying = True

    @dbus.service.method(GATT_CHARACTERISTIC)
    def StopNotify(self) -> None:
        self.notifying = False

    def send(self, payload: bytes) -> None:
        self.value = frame(payload)
        if self.notifying:
            self.PropertiesChanged(
                GATT_CHARACTERISTIC,
                {"Value": dbus.Array(self.value, signature="y")},
                [],
            )


class CredentialCharacteristic(Characteristic):
    def __init__(
        self,
        bus: dbus.SystemBus,
        service: Service,
        send_status: Callable[[bytes], None],
        forget_peer: Callable[[str], None],
    ) -> None:
        super().__init__(
            bus,
            f"{service.path}/char0",
            CREDENTIAL_RX_UUID,
            service,
            ["write", "encrypt-write"],
        )
        self.send_status = send_status
        self.forget_peer = forget_peer
        self.decoders: dict[str, FrameDecoder] = {}

    @dbus.service.method(GATT_CHARACTERISTIC, in_signature="aya{sv}")
    def WriteValue(self, value: dbus.Array, options: dict) -> None:
        peer = str(options.get("device", "unknown"))
        decoder = self.decoders.setdefault(peer, FrameDecoder())
        try:
            for payload in decoder.feed(bytes(value)):
                reply = transport_reply(payload)
                self.send_status(reply.payload)
                if reply.forget_peer:
                    # BlueZ supplies the encrypted link's exact peer path. Delay removal
                    # long enough for the acknowledgement notification to reach iOS.
                    GLib.timeout_add(
                        FORGET_DELAY_MILLISECONDS,
                        self._forget_peer,
                        peer,
                    )
                print("Autowifi secure transport request completed", flush=True)
        except ProtocolError as error:
            self.decoders.pop(peer, None)
            raise InvalidValueLength("invalid framed transport message") from error

    def _forget_peer(self, peer: str) -> bool:
        self.decoders.pop(peer, None)
        self.forget_peer(peer)
        return GLib.SOURCE_REMOVE


class Application(dbus.service.Object):
    def __init__(self, bus: dbus.SystemBus, forget_peer: Callable[[str], None]) -> None:
        self.path = ROOT_PATH
        self.service = Service(bus)
        self.status = StatusCharacteristic(bus, self.service)
        self.credential = CredentialCharacteristic(
            bus,
            self.service,
            self.status.send,
            forget_peer,
        )
        self.service.characteristics = [self.credential, self.status]
        super().__init__(bus, self.path)

    @dbus.service.method(DBUS_OBJECT_MANAGER, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self) -> dict:
        objects = {
            dbus.ObjectPath(self.service.path): {GATT_SERVICE: self.service.properties()},
        }
        for characteristic in self.service.characteristics:
            objects[dbus.ObjectPath(characteristic.path)] = {
                GATT_CHARACTERISTIC: characteristic.properties()
            }
        return objects
