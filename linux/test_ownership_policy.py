import unittest

from ownership_policy import OwnershipAction, ownership_action


class OwnershipPolicyTests(unittest.TestCase):
    def test_ownerless_spark_opens_onboarding(self):
        self.assertEqual(
            ownership_action(bonded_devices=0, onboarding_open=False),
            OwnershipAction.OPEN_ONBOARDING,
        )

    def test_first_owner_closes_onboarding(self):
        self.assertEqual(
            ownership_action(bonded_devices=1, onboarding_open=True),
            OwnershipAction.CLOSE_ONBOARDING,
        )

    def test_reconciled_states_are_stable(self):
        self.assertEqual(
            ownership_action(bonded_devices=0, onboarding_open=True),
            OwnershipAction.KEEP_STATE,
        )
        self.assertEqual(
            ownership_action(bonded_devices=1, onboarding_open=False),
            OwnershipAction.KEEP_STATE,
        )

    def test_negative_count_is_rejected(self):
        with self.assertRaises(ValueError):
            ownership_action(bonded_devices=-1, onboarding_open=False)


if __name__ == "__main__":
    unittest.main()
