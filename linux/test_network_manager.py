import unittest

from autowifi_protocol import NetworkCredential
from network_manager import NetworkManagerAdapter
from network_manager_dbus import DBusActivationBackend


class FakeActivationBackend:
    def __init__(self):
        self.settings = None
        self.finished = None
        self.calls = 0

    def activate(self, settings, finished):
        self.calls += 1
        self.settings = settings
        self.finished = finished


class FakeNetworkManagerPort:
    def __init__(self, *, wireless_enabled=True, devices=(), active_states=()):
        self.wireless_enabled = wireless_enabled
        self.devices = list(devices)
        self.active_states = list(active_states)
        self.add_calls = []
        self.deleted = []

    def is_wireless_enabled(self):
        return self.wireless_enabled

    def wifi_devices(self):
        return self.devices

    def add_and_activate(self, settings, device, succeeded, failed):
        self.add_calls.append((settings, device))
        succeeded("/settings/1", "/active/1")

    def activation_state(self, _active_connection):
        return self.active_states.pop(0)

    def delete_connection(self, connection):
        self.deleted.append(connection)


class FakeScheduler:
    def __init__(self):
        self.callback = None

    def __call__(self, _delay, callback):
        self.callback = callback

    def run_once(self):
        callback = self.callback
        self.callback = None
        if callback():
            self.callback = callback


class NetworkManagerAdapterTests(unittest.TestCase):
    def test_credential_activation_reports_connecting_then_connected(self):
        backend = FakeActivationBackend()
        adapter = NetworkManagerAdapter(backend)
        updates = []
        credential = NetworkCredential(
            request_id="fe39d9c7-fab9-4a51-9d48-6c26684d38fe",
            ssid=b"HotelWiFi",
            hidden=False,
            security=frozenset({"wpa2", "wpa3"}),
            password="not-logged",
        )

        adapter.activate(credential, updates.append)

        self.assertEqual([status.state for status in updates], ["connecting"])
        self.assertEqual(backend.settings, credential.networkmanager_settings())

        backend.finished(None)

        self.assertEqual(
            [status.state for status in updates],
            ["connecting", "connected"],
        )

    def test_activation_failure_is_returned_as_a_generic_status(self):
        backend = FakeActivationBackend()
        adapter = NetworkManagerAdapter(backend)
        updates = []
        credential = NetworkCredential(
            request_id="fe39d9c7-fab9-4a51-9d48-6c26684d38fe",
            ssid=b"HotelWiFi",
            hidden=False,
            security=frozenset({"wpa2"}),
            password="not-logged",
        )

        adapter.activate(credential, updates.append)
        backend.finished("network-activation-failed")

        self.assertEqual(updates[-1].state, "failed")
        self.assertEqual(updates[-1].error, "network-activation-failed")

    def test_replayed_request_does_not_start_a_second_activation(self):
        backend = FakeActivationBackend()
        adapter = NetworkManagerAdapter(backend)
        first_updates = []
        replay_updates = []
        credential = NetworkCredential(
            request_id="fe39d9c7-fab9-4a51-9d48-6c26684d38fe",
            ssid=b"HotelWiFi",
            hidden=False,
            security=frozenset({"wpa2"}),
            password="not-logged",
        )

        adapter.activate(credential, first_updates.append)
        adapter.activate(credential, replay_updates.append)
        backend.finished(None)
        adapter.activate(credential, replay_updates.append)

        self.assertEqual(backend.calls, 1)
        self.assertEqual(first_updates[-1].state, "connected")
        self.assertEqual(
            [status.state for status in replay_updates],
            ["connecting", "connected", "connected"],
        )


class DBusActivationBackendTests(unittest.TestCase):
    def test_existing_wifi_connection_is_never_replaced(self):
        port = FakeNetworkManagerPort(devices=[("/wifi0", 100)])
        backend = DBusActivationBackend(port, schedule=lambda _delay, _call: None)
        results = []

        backend.activate({"connection": {}}, results.append)

        self.assertEqual(results, ["wifi-already-connected"])
        self.assertEqual(port.add_calls, [])

    def test_network_manager_outage_is_a_generic_failure(self):
        class UnavailablePort(FakeNetworkManagerPort):
            def is_wireless_enabled(self):
                raise RuntimeError("secret implementation detail")

        results = []
        backend = DBusActivationBackend(
            UnavailablePort(),
            schedule=lambda _delay, _call: None,
        )

        backend.activate({"connection": {}}, results.append)

        self.assertEqual(results, ["network-manager-unavailable"])

    def test_disconnected_wifi_uses_memory_profile_and_waits_for_activation(self):
        port = FakeNetworkManagerPort(
            devices=[("/wifi0", 30)],
            active_states=[(1, False), (2, False), (2, True)],
        )
        scheduler = FakeScheduler()
        backend = DBusActivationBackend(port, schedule=scheduler)
        settings = {"connection": {"id": "autowifi-request"}}
        results = []

        backend.activate(settings, results.append)
        scheduler.run_once()
        self.assertEqual(results, [])
        scheduler.run_once()
        self.assertEqual(results, [])
        scheduler.run_once()

        self.assertEqual(port.add_calls, [(settings, "/wifi0")])
        self.assertEqual(results, [None])


if __name__ == "__main__":
    unittest.main()
