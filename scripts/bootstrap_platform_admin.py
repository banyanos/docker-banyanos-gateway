#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bootstrap the first platform admin of a fresh Banyan deployment.

A new database has no admin, and the API refuses to assign the preset
``platform:super_admin`` role unless the caller already holds it. Permission
resources (menus / pages / buttons) are also only registered by the
``registerResources`` mutation, so a fresh deployment shows "no access"
pages until it runs. This script closes both gaps, idempotently:

1. the user must already exist (register through the UI or the
   ``registerUser`` mutation first);
2. activate the user (``status=ACTIVE``, ``email_verified=true``);
3. assign the preset ``platform:super_admin`` role (created by perm_engine at
   startup) — directly in PostgreSQL, the only way for the first admin;
4. log in as that user through the gateway and call ``registerResources``.

Usage::

    BANYAN_ADMIN_PASSWORD=... python scripts/bootstrap_platform_admin.py \\
        --email admin@example.com \\
        --database-url postgresql+psycopg://USER:PASS@localhost:5432/DB \\
        --gateway-url http://127.0.0.1:8000/beta/core/banyan --part-id <tenant>

The DSN can also come from ``SE_CONFIGDATA_DATABASE_URL``. The password is
read from ``BANYAN_ADMIN_PASSWORD`` only (never a CLI argument) and is never
printed.
"""

from __future__ import annotations

import argparse
import os
import sys
import uuid

import httpx
from sqlalchemy import create_engine, text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--email", required=True)
    parser.add_argument("--database-url", default=os.getenv("SE_CONFIGDATA_DATABASE_URL"))
    parser.add_argument("--gateway-url", default="http://127.0.0.1:8000/beta/core/banyan")
    parser.add_argument("--part-id", required=True, help="Part-Id header for the login call")
    parser.add_argument("--skip-resources", action="store_true", help="only activate + assign the role")
    args = parser.parse_args()

    password = os.getenv("BANYAN_ADMIN_PASSWORD")
    if not args.database_url:
        print("error: --database-url or SE_CONFIGDATA_DATABASE_URL is required", file=sys.stderr)
        return 2
    if not args.skip_resources and not password:
        print("error: set BANYAN_ADMIN_PASSWORD (or pass --skip-resources)", file=sys.stderr)
        return 2

    engine = create_engine(args.database_url, pool_pre_ping=True)
    with engine.begin() as conn:
        user_id = conn.execute(
            text("SELECT id FROM tenant_user WHERE email = :e AND deleted_at IS NULL"),
            {"e": args.email},
        ).scalar()
        if not user_id:
            print(f"error: no user with email {args.email}; register it first", file=sys.stderr)
            return 1
        role_id = conn.execute(
            text(
                "SELECT id FROM tenant_perm_role WHERE code = 'platform:super_admin' "
                "AND tenant_id IS NULL AND deleted_at IS NULL"
            )
        ).scalar()
        if not role_id:
            print(
                "error: preset role platform:super_admin not found — start the "
                "gateway once so perm_engine creates its preset roles",
                file=sys.stderr,
            )
            return 1
        conn.execute(
            text(
                "UPDATE tenant_user SET status = 'ACTIVE', email_verified = true, "
                "updated_at = now() WHERE id = :u"
            ),
            {"u": user_id},
        )
        conn.execute(
            text(
                "INSERT INTO tenant_perm_user_role (user_id, role_id) "
                "SELECT :u, :r WHERE NOT EXISTS (SELECT 1 FROM tenant_perm_user_role "
                "WHERE user_id = :u AND role_id = :r)"
            ),
            {"u": user_id, "r": role_id},
        )
    engine.dispose()
    print(f"user activated and assigned platform:super_admin (user_id={user_id})")

    if args.skip_resources:
        return 0

    headers = {"Content-Type": "application/json", "Part-Id": args.part_id}
    with httpx.Client(timeout=600) as client:
        r = client.post(
            f"{args.gateway_url}/user_engine_graphql",
            headers=headers,
            json={
                "query": "mutation($i:LoginInput!,$k:ID!){ login(input:$i, idempotencyKey:$k){ authToken } }",
                "variables": {"i": {"email": args.email, "password": password}, "k": uuid.uuid4().hex},
            },
        )
        token = (((r.json() or {}).get("data") or {}).get("login") or {}).get("authToken")
        if not token:
            print(f"error: login failed (HTTP {r.status_code})", file=sys.stderr)
            return 1
        r = client.post(
            f"{args.gateway_url}/perm_engine_graphql",
            headers={**headers, "Authorization": f"Bearer {token}"},
            json={
                "query": "mutation($k:ID!){ registerResources(idempotencyKey:$k){ __typename } }",
                "variables": {"k": uuid.uuid4().hex},
            },
        )
        body = r.json() if r.content else {}
        if r.status_code != 200 or body.get("errors"):
            print(f"error: registerResources failed (HTTP {r.status_code}): {body.get('errors')}", file=sys.stderr)
            return 1
    print("permission resources registered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
