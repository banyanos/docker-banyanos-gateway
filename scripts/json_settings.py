"""Load Banyanos configuration directly from a mounted JSON file."""

import json
import logging
import os
import re
from pathlib import Path


def load_json_settings(path):
    try:
        with Path(path).open(encoding="utf-8-sig") as source:
            record = json.load(source)
    except (OSError, ValueError) as exc:
        # Avoid including input contents or credentials in startup errors.
        raise ValueError(f"Cannot load configuration JSON: {path}") from exc
    if not isinstance(record, dict):
        raise ValueError("Configuration JSON must contain an object")
    record.pop("_comment", None)
    if not record:
        raise ValueError("Configuration JSON must not be empty")

    def check(value):
        if isinstance(value, str) and re.search(r"<[A-Z][A-Z0-9_]*>", value):
            raise ValueError("Configuration JSON contains unresolved placeholders")
        if isinstance(value, dict):
            for item in value.values():
                check(item)
        elif isinstance(value, list):
            for item in value:
                check(item)

    check(record)
    # Database selection is independent of where configuration is loaded from.
    backend = os.getenv("db_backend") or record.get("db_backend", "postgresql")
    if not isinstance(backend, str):
        raise ValueError("db_backend must be postgresql or dynamodb")
    backend = backend.strip().lower()
    if backend not in ("postgresql", "dynamodb"):
        raise ValueError("db_backend must be postgresql or dynamodb")
    record["db_backend"] = backend
    logging.getLogger(__name__).info(
        "JSON setting loaded: file=%s variables=%d db_backend=%s",
        path, len(record), backend,
    )
    return record
