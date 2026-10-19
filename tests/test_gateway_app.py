import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch

from scripts.gateway_app import build_setting, create_app_from_env


class GatewayAppTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "settings.json"
        self.path.write_text(json.dumps({"jwt_secret": "json-secret", "custom": [1]}))
        env = patch.dict(os.environ, {"SETTING_JSON_FILE": str(self.path)}, clear=True)
        env.start()
        self.addCleanup(env.stop)

        self.config = SimpleNamespace(initialize=Mock())
        self.builder = SimpleNamespace(
            _load_setting_spec=lambda: {"jwt_secret": {}, "auth_provider": {}},
            _resolve_setting=lambda key, spec: "environment-value",
            _rewrite_httpx_base_urls=Mock(),
            _apply_env_overrides=lambda setting: setting,
            GatewayConfig=self.config,
            _build_internal_mcp_config=self.mcp_config,
            load_route_manifest=lambda config: [SimpleNamespace(
                package="example_engine", config_class="Config", routes=[
                    SimpleNamespace(handler_type="graphql", dispatch="dispatch", path="/banyan/query"),
                    SimpleNamespace(handler_type="websocket", dispatch=None, path="/ws"),
                ])],
            _module_invoker_class_name=lambda module: "ExampleEngine",
        )
        gateway = ModuleType("silvaengine_gateway")
        gateway.setting_builder = self.builder
        self.app = ModuleType("silvaengine_gateway.app")
        self.app.create_app = Mock(return_value="app")
        dotenv = ModuleType("dotenv")
        dotenv.load_dotenv = Mock()
        modules = patch.dict(sys.modules, {
            "silvaengine_gateway": gateway,
            "silvaengine_gateway.app": self.app,
            "dotenv": dotenv,
        })
        modules.start()
        self.addCleanup(modules.stop)

    def mcp_config(self):
        # Derived configuration must see JSON on the first initialization.
        self.assertEqual(self.config.initialize.call_args.args[1]["jwt_secret"], "json-secret")
        return {"derived": True}

    def test_json_merged_before_initialization_and_derived_settings(self):
        setting = build_setting()
        self.assertEqual(setting["jwt_secret"], "json-secret")
        self.assertEqual(setting["auth_provider"], "environment-value")
        self.assertEqual(setting["custom"], [1])
        self.assertTrue(setting["internal_mcp"]["derived"])
        for name in ("query", "send_data_to_stream", "async_insert_update_tool_call"):
            self.assertEqual(setting["functs_on_local"][name]["class_name"], "ExampleEngine")
        self.builder._rewrite_httpx_base_urls.assert_called_once()

    def test_emergency_overrides_and_local_dispatch_override(self):
        self.builder._apply_env_overrides = lambda setting: {**setting, "custom": "override"}
        os.environ["FUNCTS_ON_LOCAL_OVERRIDES"] = '{"query": {"module_name": "override"}}'
        setting = build_setting()
        self.assertEqual(setting["custom"], "override")
        self.assertEqual(setting["functs_on_local"]["query"]["module_name"], "override")

    def test_database_config_source_rejected_without_initialization(self):
        os.environ["SETTING_SOURCE"] = "se-configdata"
        with self.assertRaisesRegex(ValueError, "SETTING_SOURCE=json"):
            build_setting()
        self.config.initialize.assert_not_called()

    def test_invalid_json_rejected_without_initialization(self):
        self.path.write_text('{"jwt_secret": "<SECRET>"}')
        with self.assertRaises(ValueError):
            build_setting()
        self.config.initialize.assert_not_called()

    def test_factory_passes_settings_to_gateway(self):
        self.assertEqual(create_app_from_env(), "app")
        self.assertEqual(self.app.create_app.call_args.args[0]["jwt_secret"], "json-secret")
