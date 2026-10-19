import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.json_settings import load_json_settings


class JsonSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "settings.json"
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def load(self, value):
        self.path.write_text(json.dumps(value), encoding="utf-8-sig")
        return load_json_settings(self.path)

    def test_preserves_nested_settings_and_windows_bom(self):
        nested = {"host": "postgres", "port": 5432, "enabled": True}
        self.assertEqual(self.load({"pool": nested})["pool"], nested)

    def test_explicit_backend_overrides_json(self):
        os.environ["db_backend"] = "dynamodb"
        self.assertEqual(self.load({"db_backend": "postgresql"})["db_backend"], "dynamodb")

    def test_json_backend_used_without_environment_override(self):
        self.assertEqual(self.load({"db_backend": "dynamodb"})["db_backend"], "dynamodb")

    def test_default_backend_is_postgresql(self):
        self.assertEqual(self.load({"enabled": True})["db_backend"], "postgresql")

    def test_invalid_configurations_fail(self):
        for value in ({}, [], None, {"_comment": "template"},
                      {"nested": [{"password": "<SECRET>"}]},
                      {"db_backend": "unknown"}, {"db_backend": None}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.load(value)

    def test_comment_metadata_is_removed(self):
        self.assertNotIn("_comment", self.load({"_comment": "metadata", "enabled": True}))

    def test_missing_and_malformed_files_fail(self):
        with self.assertRaises(ValueError):
            load_json_settings(self.path)
        self.path.write_text('{"broken":', encoding="utf-8")
        with self.assertRaises(ValueError):
            load_json_settings(self.path)

    def test_log_contains_no_configuration_values(self):
        with self.assertLogs("scripts.json_settings", level="INFO") as logs:
            self.load({"jwt_secret": "private-test-secret"})
        self.assertNotIn("private-test-secret", " ".join(logs.output))


if __name__ == "__main__":
    unittest.main()
