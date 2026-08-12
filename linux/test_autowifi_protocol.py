import base64
import json
import unittest

from autowifi_protocol import FrameDecoder, NetworkCredential, ProtocolError, frame


def payload(**changes):
    value = {
        "version": 1,
        "type": "wifi-credential",
        "requestID": "fe39d9c7-fab9-4a51-9d48-6c26684d38fe",
        "ssid": base64.b64encode(b"HotelWiFi").decode("ascii"),
        "hidden": False,
        "security": ["wpa2", "wpa3"],
        "credential": {"kind": "password", "password": "not-logged"},
    }
    value.update(changes)
    return json.dumps(value, separators=(",", ":")).encode()


class FrameDecoderTests(unittest.TestCase):
    def test_decodes_fragmented_and_coalesced_frames(self):
        first = frame(b"one")
        second = frame(b"two")
        decoder = FrameDecoder()

        self.assertEqual(decoder.feed(first[:2]), [])
        self.assertEqual(decoder.feed(first[2:] + second), [b"one", b"two"])

    def test_rejects_oversize_length_before_buffering_body(self):
        decoder = FrameDecoder(maximum_payload_bytes=8)
        with self.assertRaisesRegex(ProtocolError, "frame length"):
            decoder.feed(b"\x00\x00\x00\x09")


class CredentialTests(unittest.TestCase):
    def test_maps_wpa2_wpa3_personal(self):
        credential = NetworkCredential.from_payload(payload())
        settings = credential.networkmanager_settings()

        self.assertEqual(settings["802-11-wireless"]["ssid"], b"HotelWiFi")
        self.assertEqual(
            settings["802-11-wireless-security"],
            {"key-mgmt": "wpa-psk", "psk": "not-logged"},
        )

    def test_maps_open_without_security_block(self):
        credential = NetworkCredential.from_payload(
            payload(
                security=["open"],
                credential={"kind": "none", "password": None},
            )
        )
        self.assertNotIn(
            "802-11-wireless-security", credential.networkmanager_settings()
        )

    def test_preserves_binary_ssid(self):
        raw_ssid = b"binary\x00ssid\xff"
        credential = NetworkCredential.from_payload(
            payload(ssid=base64.b64encode(raw_ssid).decode("ascii"))
        )
        self.assertEqual(credential.ssid, raw_ssid)

    def test_maps_owe_transition_network(self):
        credential = NetworkCredential.from_payload(
            payload(
                security=["open", "owe"],
                credential={"kind": "none", "password": None},
            )
        )
        self.assertEqual(
            credential.networkmanager_settings()["802-11-wireless-security"],
            {"key-mgmt": "owe"},
        )

    def test_rejects_legacy_or_unknown_security(self):
        for security in (["wep"], ["wpa"], ["future"]):
            with self.subTest(security=security):
                with self.assertRaisesRegex(ProtocolError, "security"):
                    NetworkCredential.from_payload(payload(security=security))

    def test_rejects_password_on_open_network(self):
        with self.assertRaisesRegex(ProtocolError, "open/OWE networks"):
            NetworkCredential.from_payload(payload(security=["open"]))

    def test_rejects_mixed_open_and_personal_security(self):
        with self.assertRaisesRegex(ProtocolError, "incompatible"):
            NetworkCredential.from_payload(payload(security=["open", "wpa2"]))

    def test_rejects_invalid_ssid_length(self):
        with self.assertRaisesRegex(ProtocolError, "SSID"):
            NetworkCredential.from_payload(payload(ssid=""))

    def test_rejects_non_uuid_request_id(self):
        with self.assertRaisesRegex(ProtocolError, "UUID"):
            NetworkCredential.from_payload(payload(requestID="request-1"))


if __name__ == "__main__":
    unittest.main()
