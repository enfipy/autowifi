#!/usr/bin/env python3
"""BlueZ GATT peripheral for the Autowifi secure transport.

An ownerless Spark stays pairable until its first owner bond; an owned Spark is
not pairable. All GATT writes require encryption. Wi-Fi state is never changed
by the pairing lifecycle.
"""

from __future__ import annotations

import argparse
import signal
import sys

import dbus
import dbus.exceptions
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

from bluez_gatt import (
    DBUS_OBJECT_MANAGER,
    DBUS_PROPERTIES,
    GATT_MANAGER,
    ROOT_PATH,
    Application,
    DBusObject,
    Rejected,
)
from generated_constants import SERVICE_UUID
from product_identity import PRODUCTS, advertised_name, detect_product
from ownership_policy import OwnershipAction, ownership_action


BLUEZ_SERVICE = "org.bluez"
ADVERTISING_MANAGER = "org.bluez.LEAdvertisingManager1"
ADVERTISEMENT = "org.bluez.LEAdvertisement1"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
AGENT = "org.bluez.Agent1"
AGENT_MANAGER = "org.bluez.AgentManager1"
AGENT_PATH = f"{ROOT_PATH}/agent"


class Advertisement(DBusObject):
    interface_name = ADVERTISEMENT

    def __init__(self, bus: dbus.SystemBus, product: str) -> None:
        self.path = f"{ROOT_PATH}/advertisement0"
        self.product = product
        super().__init__(bus, self.path)

    def properties(self) -> dict:
        return {
            "Type": dbus.String("peripheral"),
            "ServiceUUIDs": dbus.Array([SERVICE_UUID], signature="s"),
            "LocalName": dbus.String(advertised_name(self.product)),
            "Includes": dbus.Array(["tx-power"], signature="s"),
        }

    @dbus.service.method(ADVERTISEMENT)
    def Release(self) -> None:
        print("Autowifi advertisement released", flush=True)


class PairingAgent(dbus.service.Object):
    """Headless Just Works agent, active only while owner onboarding is open."""

    def __init__(self, bus: dbus.SystemBus) -> None:
        super().__init__(bus, AGENT_PATH)

    @dbus.service.method(AGENT)
    def Release(self) -> None:
        print("Autowifi pairing agent released", flush=True)

    @dbus.service.method(AGENT, in_signature="o", out_signature="s")
    def RequestPinCode(self, _device: dbus.ObjectPath) -> str:
        raise Rejected("PIN pairing is not supported")

    @dbus.service.method(AGENT, in_signature="o", out_signature="u")
    def RequestPasskey(self, _device: dbus.ObjectPath) -> dbus.UInt32:
        raise Rejected("passkey pairing is not supported")

    @dbus.service.method(AGENT, in_signature="os")
    def DisplayPinCode(self, _device: dbus.ObjectPath, _pin: str) -> None:
        pass

    @dbus.service.method(AGENT, in_signature="ouq")
    def DisplayPasskey(
        self,
        _device: dbus.ObjectPath,
        _passkey: dbus.UInt32,
        _entered: dbus.UInt16,
    ) -> None:
        pass

    @dbus.service.method(AGENT, in_signature="ou")
    def RequestConfirmation(
        self,
        _device: dbus.ObjectPath,
        _passkey: dbus.UInt32,
    ) -> None:
        # With NoInputNoOutput, BlueZ uses this only for Just Works consent.
        pass

    @dbus.service.method(AGENT, in_signature="o")
    def RequestAuthorization(self, _device: dbus.ObjectPath) -> None:
        pass

    @dbus.service.method(AGENT, in_signature="os")
    def AuthorizeService(self, _device: dbus.ObjectPath, uuid: str) -> None:
        if uuid.lower() != SERVICE_UUID.lower():
            raise Rejected("service is not authorized")

    @dbus.service.method(AGENT)
    def Cancel(self) -> None:
        pass


class OnboardingController:
    """Own the BlueZ agent and adapter pairing state for the first owner.

    The LE advertisement supplies BLE discovery throughout the daemon lifetime.
    Adapter1.Discoverable is a separate adapter mode and is deliberately left
    unchanged; this Spark controller returns Busy when it is toggled while an
    LE advertisement is registered.
    """

    def __init__(
        self,
        bus: dbus.SystemBus,
        adapter_path: str,
    ) -> None:
        self.agent = PairingAgent(bus)
        self.agent_manager = dbus.Interface(
            bus.get_object(BLUEZ_SERVICE, "/org/bluez"),
            AGENT_MANAGER,
        )
        self.adapter_properties = dbus.Interface(
            bus.get_object(BLUEZ_SERVICE, adapter_path),
            DBUS_PROPERTIES,
        )
        self.previous_pairable = bool(self.adapter_properties.Get(ADAPTER, "Pairable"))
        self.registered = False
        self.opened = False

    def open(self) -> None:
        if not self.registered:
            self.agent_manager.RegisterAgent(dbus.ObjectPath(AGENT_PATH), "NoInputNoOutput")
            self.registered = True
            self.agent_manager.RequestDefaultAgent(dbus.ObjectPath(AGENT_PATH))
        self.adapter_properties.Set(ADAPTER, "Pairable", dbus.Boolean(True))
        self.opened = True
        print("Autowifi onboarding open until first owner bond", flush=True)

    def close(self, *, restore: bool) -> None:
        if self.opened:
            pairable = self.previous_pairable if restore else False
            try:
                self.adapter_properties.Set(
                    ADAPTER,
                    "Pairable",
                    dbus.Boolean(pairable),
                )
            except dbus.exceptions.DBusException as error:
                print(
                    f"could not restore adapter Pairable: {error.get_dbus_name()}",
                    file=sys.stderr,
                    flush=True,
                )
            self.opened = False
        if self.registered:
            # A synchronous unregister can deadlock: BlueZ calls Release back
            # into this same GLib loop before replying to UnregisterAgent.
            self.agent_manager.UnregisterAgent(
                dbus.ObjectPath(AGENT_PATH),
                reply_handler=lambda: None,
                error_handler=lambda _error: None,
            )
            self.registered = False


def find_adapter(bus: dbus.SystemBus) -> str:
    root = bus.get_object(BLUEZ_SERVICE, "/")
    objects = dbus.Interface(root, DBUS_OBJECT_MANAGER).GetManagedObjects()
    for path, interfaces in objects.items():
        if GATT_MANAGER in interfaces and ADVERTISING_MANAGER in interfaces:
            return str(path)
    raise RuntimeError("no BlueZ adapter exposes GATT and advertising managers")


def bonded_device_count(bus: dbus.SystemBus, adapter_path: str) -> int:
    root = bus.get_object(BLUEZ_SERVICE, "/")
    objects = dbus.Interface(root, DBUS_OBJECT_MANAGER).GetManagedObjects()
    prefix = f"{adapter_path}/dev_"
    return sum(
        1
        for path, interfaces in objects.items()
        if str(path).startswith(prefix)
        and DEVICE in interfaces
        and bool(interfaces[DEVICE].get("Bonded", interfaces[DEVICE].get("Paired", False)))
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--product",
        choices=["auto", *PRODUCTS],
        default="auto",
        help="stable picker product identity (default: infer from DMI)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    product = detect_product(args.product)
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    adapter_path = find_adapter(bus)
    adapter = bus.get_object(BLUEZ_SERVICE, adapter_path)
    gatt_manager = dbus.Interface(adapter, GATT_MANAGER)
    advertising_manager = dbus.Interface(adapter, ADVERTISING_MANAGER)
    advertisement = Advertisement(bus, product)
    onboarding = OnboardingController(bus, adapter_path)
    loop = GLib.MainLoop()
    failed = False

    def reconcile_pairing() -> bool:
        """Enforce single-owner onboarding independently of app timing or reinstall state."""

        try:
            action = ownership_action(
                bonded_devices=bonded_device_count(bus, adapter_path),
                onboarding_open=onboarding.opened,
            )
            if action is OwnershipAction.CLOSE_ONBOARDING:
                onboarding.close(restore=False)
                print("Autowifi owner bond detected; onboarding closed", flush=True)
            elif action is OwnershipAction.OPEN_ONBOARDING:
                onboarding.open()
        except dbus.exceptions.DBusException as error:
            print(
                f"could not reconcile pairing ownership: {error.get_dbus_name()}",
                file=sys.stderr,
                flush=True,
            )
        return GLib.SOURCE_CONTINUE

    def forget_peer(peer: str) -> None:
        expected_prefix = f"{adapter_path}/dev_"
        if not peer.startswith(expected_prefix):
            print("Autowifi rejected invalid peer reset request", file=sys.stderr, flush=True)
            return

        def reopen_pairing(*, error: Exception | None = None) -> None:
            if error is not None:
                error_name = getattr(error, "get_dbus_name", lambda: type(error).__name__)()
                print(f"Autowifi peer bond reset reported {error_name}", file=sys.stderr, flush=True)
            try:
                reconcile_pairing()
                print("Autowifi peer bond reset; owner onboarding enabled", flush=True)
            except dbus.exceptions.DBusException as pairing_error:
                print(
                    f"could not reopen pairing: {pairing_error.get_dbus_name()}",
                    file=sys.stderr,
                    flush=True,
                )

        dbus.Interface(adapter, ADAPTER).RemoveDevice(
            dbus.ObjectPath(peer),
            reply_handler=lambda: reopen_pairing(),
            error_handler=lambda error: reopen_pairing(error=error),
        )

    application = Application(bus, forget_peer)

    def fail(prefix: str, error: Exception) -> None:
        nonlocal failed
        failed = True
        print(f"{prefix}: {error}", file=sys.stderr, flush=True)
        loop.quit()

    def advertisement_registered() -> None:
        try:
            reconcile_pairing()
            GLib.timeout_add_seconds(1, reconcile_pairing)
        except dbus.exceptions.DBusException as error:
            fail("pairing setup failed", error)
            return
        print(
            f"Autowifi BLE ready on {adapter_path}; service={SERVICE_UUID}; product={product}",
            flush=True,
        )

    def application_registered() -> None:
        advertising_manager.RegisterAdvertisement(
            dbus.ObjectPath(advertisement.path),
            {},
            reply_handler=advertisement_registered,
            error_handler=lambda error: fail("advertisement registration failed", error),
        )

    gatt_manager.RegisterApplication(
        dbus.ObjectPath(application.path),
        {},
        reply_handler=application_registered,
        error_handler=lambda error: fail("GATT registration failed", error),
    )

    def stop(_signal_number: int, _frame: object) -> None:
        loop.quit()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    loop.run()

    onboarding.close(restore=True)
    try:
        advertising_manager.UnregisterAdvertisement(dbus.ObjectPath(advertisement.path))
    except dbus.exceptions.DBusException:
        pass
    try:
        gatt_manager.UnregisterApplication(dbus.ObjectPath(application.path))
    except dbus.exceptions.DBusException:
        pass
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
