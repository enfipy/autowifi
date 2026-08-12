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
        self.assertEqual(advertised_name("nvidia"), "Autowifi NVIDIA")


if __name__ == "__main__":
    unittest.main()
