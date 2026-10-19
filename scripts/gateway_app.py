"""Banyanos JSON app factory for the pinned, unmodified SilvaEngine gateway.

Keep the gateway's environment manifest, loopback and emergency-override rules.
Resolve JSON before initializing GatewayConfig or deriving routes/MCP settings.
The setting-builder helpers used here are covered by the gateway commit pin.
"""

import json
import logging
import os
import sys

from .json_settings import load_json_settings


def build_setting():
    from silvaengine_gateway import setting_builder as builder

    if os.getenv("SETTING_SOURCE", "json").strip() != "json":
        raise ValueError("Banyanos requires SETTING_SOURCE=json")
    record = load_json_settings(os.environ["SETTING_JSON_FILE"])
    setting = {
        key: builder._resolve_setting(key, entry or {})
        for key, entry in builder._load_setting_spec().items()
    }
    builder._rewrite_httpx_base_urls(record)
    setting.update(record)
    setting = builder._apply_env_overrides(setting)

    builder.GatewayConfig.initialize(logging.getLogger("silvaengine_gateway"), setting)
    setting["internal_mcp"] = builder._build_internal_mcp_config()
    functs = {}
    for module in builder.load_route_manifest(builder.GatewayConfig):
        if not module.config_class:
            continue
        target = {
            "module_name": module.package,
            "class_name": builder._module_invoker_class_name(module),
        }
        for route in module.routes:
            if route.handler_type == "graphql" and route.dispatch:
                functs[route.path.rstrip("/").rsplit("/", 1)[-1]] = dict(target)
            if route.handler_type == "websocket":
                for name in ("send_data_to_stream", "async_insert_update_tool_call"):
                    functs.setdefault(name, dict(target))
    functs.update(json.loads(os.getenv("FUNCTS_ON_LOCAL_OVERRIDES", "{}")))
    setting["functs_on_local"] = functs
    return setting


def create_app_from_env():
    from dotenv import load_dotenv
    from silvaengine_gateway.app import create_app

    load_dotenv()
    logging.basicConfig(
        stream=sys.stdout,
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
    return create_app(build_setting())
