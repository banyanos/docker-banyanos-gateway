#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Load a se-configdata record into PostgreSQL (SE_CONFIGDATA_BACKEND=postgresql).

PostgreSQL counterpart of ``seed_seconfig.py`` / ``ddb_init.py``: the gateway
reads the record from the deployment's own PostgreSQL instead of DynamoDB
(silvaengine_gateway ``setting_builder._read_configdata_record_pg``).

Table (created if missing)::

    se_configdata(setting_id TEXT, variable TEXT, value JSONB,
                  PRIMARY KEY (setting_id, variable))

One row per top-level JSON variable, upserted (overwrite semantics, like
DynamoDB ``put_item``). Idempotent — safe to re-run on every deploy.

Usage::

    python scripts/seed_seconfig_pg.py --file env/se-configdata.local.json \\
        --database-url postgresql+psycopg://USER:PASS@localhost:5432/DB \\
        [--setting-id beta_core_banyan] [--table se_configdata]

The DSN can also come from ``SE_CONFIGDATA_DATABASE_URL``. Credentials are
never printed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

from sqlalchemy import create_engine, text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file", required=True, help="se-configdata JSON record")
    parser.add_argument("--database-url", default=os.getenv("SE_CONFIGDATA_DATABASE_URL"))
    parser.add_argument("--setting-id", default="beta_core_banyan")
    parser.add_argument("--table", default="se_configdata")
    args = parser.parse_args()

    if not args.database_url:
        print("error: --database-url or SE_CONFIGDATA_DATABASE_URL is required", file=sys.stderr)
        return 2
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", args.table):
        print(f"error: invalid table name {args.table!r}", file=sys.stderr)
        return 2
    try:
        record = json.load(open(args.file, encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"error: cannot read {args.file}: {exc}", file=sys.stderr)
        return 2
    record.pop("_comment", None)

    engine = create_engine(args.database_url, pool_pre_ping=True)
    with engine.begin() as conn:
        conn.execute(
            text(
                f"CREATE TABLE IF NOT EXISTS {args.table} ("
                "setting_id TEXT NOT NULL, variable TEXT NOT NULL, value JSONB, "
                "PRIMARY KEY (setting_id, variable))"
            )
        )
        for variable, value in record.items():
            conn.execute(
                text(
                    f"INSERT INTO {args.table} (setting_id, variable, value) "
                    "VALUES (:sid, :var, CAST(:val AS JSONB)) "
                    "ON CONFLICT (setting_id, variable) DO UPDATE SET value = EXCLUDED.value"
                ),
                {"sid": args.setting_id, "var": variable, "val": json.dumps(value)},
            )
        count = conn.execute(
            text(f"SELECT count(*) FROM {args.table} WHERE setting_id = :sid"),
            {"sid": args.setting_id},
        ).scalar()
    engine.dispose()

    if count != len(record):
        print(f"error: expected {len(record)} rows, found {count}", file=sys.stderr)
        return 1
    print(f"se-configdata ({args.table}) seeded: setting_id={args.setting_id} rows={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
