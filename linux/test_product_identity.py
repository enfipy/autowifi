import unittest

from product_identity import advertised_name, select_product


class ProductIdentityTests(unittest.TestCase):
    def test_detects_current_gigabyte_hardware(self):
        self.assertEqual(select_product("GIGABYTE", "AI TOP ATOM"), "gigabyte")

    def test_detects_nvidia_hardware(self):
        self.assertEqual(select_product("NVIDIA", "DGX Spark"), "nvidia")

    def test_unknown_hardware_is_generic(self):
        self.assertEqual(select_product("Acme", "Compute Box"), "generic")

    def test_explicit_override_is_stable(self):
        self.assertEqual(select_product("GIGABYTE", "AI TOP ATOM", "nvidia"), "nvidia")

    def test_picker_subtitle_is_only_the_sanitized_hostname(self):
        self.assertEqual(
            advertised_name("enfis1"),
            "enfis1",
        )
        self.assertEqual(
            advertised_name("enfis2"),
            "enfis2",
        )
        self.assertEqual(advertised_name("enfis 1"), "enfis-1")


if __name__ == "__main__":
    unittest.main()
