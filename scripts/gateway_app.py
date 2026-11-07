"""Banyanos JSON app factory for the unmodified SilvaEngine gateway.

Keep the gateway's environment manifest, loopback and emergency-override rules.
Resolve JSON before initializing GatewayConfig or deriving routes/MCP settings.
The gateway main branch must provide these setting-builder helpers.
"""

import json
import logging
import os
import sys
from pathlib import Path

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
    git_key_file = os.getenv("MCP_GIT_SSH_KEY_FILE")
    if git_key_file:
        # Runtime-only Docker secret; never write private material to JSON/env.
        key = Path(git_key_file).read_text(encoding="utf-8").strip()
        if not key or "PRIVATE KEY-----" not in key:
            raise ValueError("MCP Git SSH secret is not a private key")
        setting["git_ssh_key"] = key + "\n"
    # Deployment-controlled allowlist for capability_engine's per-call MCP JWT.
    # Provider rows cannot opt arbitrary remote hosts into local signing.
    mcp_base_url = os.getenv("CAPABILITY_MCP_GATEWAY_BASE_URL")
    if mcp_base_url:
        setting.setdefault("capability_mcp_gateway_base_url", mcp_base_url)

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
