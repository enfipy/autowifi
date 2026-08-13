"""NetworkManager activation backend and its production D-Bus port."""

from __future__ import annotations

from collections.abc import Callable
from typing import Protocol


WIFI_DEVICE = 2
DEVICE_DISCONNECTED = 30
DEVICE_ACTIVATED = 100
ACTIVE_ACTIVATED = 2
ACTIVE_DEACTIVATING = 3
ACTIVE_DEACTIVATED = 4
POLL_MILLISECONDS = 500
ACTIVATION_POLLS = 90
NM_SERVICE = "org.freedesktop.NetworkManager"
NM_PATH = "/org/freedesktop/NetworkManager"
NM_INTERFACE = NM_SERVICE
NM_DEVICE_INTERFACE = f"{NM_SERVICE}.Device"
NM_ACTIVE_INTERFACE = f"{NM_SERVICE}.Connection.Active"
NM_SETTINGS_CONNECTION_INTERFACE = f"{NM_SERVICE}.Settings.Connection"
DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"


class NetworkManagerPort(Protocol):
    def is_wireless_enabled(self) -> bool: ...

    def wifi_devices(self) -> list[tuple[str, int]]: ...

    def add_and_activate(
        self,
        settings: dict,
        device: str,
        succeeded: Callable[[str, str], None],
        failed: Callable[[], None],
    ) -> None: ...

    def activation_state(self, active_connection: str) -> tuple[int, bool]: ...

    def delete_connection(self, connection: str) -> None: ...


class DBusActivationBackend:
    """Safely activate one in-memory Wi-Fi profile through NetworkManager."""

    def __init__(self, port: NetworkManagerPort, schedule: Callable) -> None:
        self.port = port
        self.schedule = schedule

    def activate(self, settings: dict, finished: Callable[[str | None], None]) -> None:
        try:
            wireless_enabled = self.port.is_wireless_enabled()
            devices = self.port.wifi_devices()
        except Exception:
            finished("network-manager-unavailable")
            return

        if not wireless_enabled:
            finished("wifi-disabled")
            return

        if any(state == DEVICE_ACTIVATED for _path, state in devices):
            finished("wifi-already-connected")
            return

        device = next(
            (path for path, state in devices if state == DEVICE_DISCONNECTED),
            None,
        )
        if device is None:
            finished("wifi-unavailable")
            return

        def activation_created(connection: str, active_connection: str) -> None:
            remaining = ACTIVATION_POLLS

            def poll() -> bool:
                nonlocal remaining
                try:
                    state, route_ready = self.port.activation_state(active_connection)
                except Exception:
                    self._fail(connection, "network-activation-failed", finished)
                    return False
                if state == ACTIVE_ACTIVATED and route_ready:
                    finished(None)
                    return False
                if state in {ACTIVE_DEACTIVATING, ACTIVE_DEACTIVATED}:
                    self._fail(connection, "network-activation-failed", finished)
                    return False
                remaining -= 1
                if remaining <= 0:
                    self._fail(connection, "network-activation-timeout", finished)
                    return False
                return True

            self.schedule(POLL_MILLISECONDS, poll)

        try:
            self.port.add_and_activate(
                settings,
                device,
                activation_created,
                lambda: finished("network-activation-failed"),
            )
        except Exception:
            finished("network-manager-unavailable")

    def _fail(
        self,
        connection: str,
        error: str,
        finished: Callable[[str | None], None],
    ) -> None:
        try:
            self.port.delete_connection(connection)
        except Exception:
            pass
        finished(error)


class DBusNetworkManagerPort:
    """Translate the narrow activation port into NetworkManager D-Bus calls."""

    def __init__(self, bus) -> None:
        import dbus

        self.dbus = dbus
        self.bus = bus
        manager_object = bus.get_object(NM_SERVICE, NM_PATH)
        self.manager = dbus.Interface(manager_object, NM_INTERFACE)
        self.manager_properties = dbus.Interface(manager_object, DBUS_PROPERTIES)

    def is_wireless_enabled(self) -> bool:
        return bool(self.manager_properties.Get(NM_INTERFACE, "WirelessEnabled"))

    def wifi_devices(self) -> list[tuple[str, int]]:
        devices = []
        for path in self.manager.GetDevices():
            properties = self.dbus.Interface(
                self.bus.get_object(NM_SERVICE, path),
                DBUS_PROPERTIES,
            )
            if int(properties.Get(NM_DEVICE_INTERFACE, "DeviceType")) == WIFI_DEVICE:
                devices.append(
                    (str(path), int(properties.Get(NM_DEVICE_INTERFACE, "State")))
                )
        return devices

    def add_and_activate(
        self,
        settings: dict,
        device: str,
        succeeded: Callable[[str, str], None],
        failed: Callable[[], None],
    ) -> None:
        options = self.dbus.Dictionary(
            {
                "persist": self.dbus.String("memory", variant_level=1),
            },
            signature="sv",
        )
        self.manager.AddAndActivateConnection2(
            self._settings(settings),
            self.dbus.ObjectPath(device),
            self.dbus.ObjectPath("/"),
            options,
            reply_handler=lambda connection, active, _result: succeeded(
                str(connection),
                str(active),
            ),
            error_handler=lambda _error: failed(),
        )

    def activation_state(self, active_connection: str) -> tuple[int, bool]:
        properties = self.dbus.Interface(
            self.bus.get_object(NM_SERVICE, active_connection),
            DBUS_PROPERTIES,
        )
        values = properties.GetAll(NM_ACTIVE_INTERFACE)
        has_ip_configuration = any(
            str(values.get(name, "/")) != "/"
            for name in ("Ip4Config", "Ip6Config")
        )
        has_default_route = bool(values.get("Default", False)) or bool(
            values.get("Default6", False)
        )
        return int(values["State"]), has_ip_configuration and has_default_route

    def delete_connection(self, connection: str) -> None:
        self.dbus.Interface(
            self.bus.get_object(NM_SERVICE, connection),
            NM_SETTINGS_CONNECTION_INTERFACE,
        ).Delete()

    def _settings(self, settings: dict):
        return self.dbus.Dictionary(
            {
                section: self.dbus.Dictionary(
                    {
                        key: self._variant(value)
                        for key, value in values.items()
                    },
                    signature="sv",
                )
                for section, values in settings.items()
            },
            signature="sa{sv}",
        )

    def _variant(self, value):
        if isinstance(value, bool):
            return self.dbus.Boolean(value, variant_level=1)
        if isinstance(value, bytes):
            return self.dbus.ByteArray(value, variant_level=1)
        if isinstance(value, str):
            return self.dbus.String(value, variant_level=1)
        raise TypeError(f"unsupported NetworkManager setting type: {type(value).__name__}")
