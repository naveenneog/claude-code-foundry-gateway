"""Validate an owned test-only group before any portal ownership screenshot."""

import argparse
import json
from pathlib import Path

from claude_finops.config import load_config
from claude_finops.groups import EntraGroups, object_id


def group_context(config_path, group_id):
    graph = EntraGroups(config=load_config(Path(config_path)))
    try:
        me = graph.me()
        group_id = object_id(group_id)
        group = graph.request("GET", f"/v1.0/groups/{group_id}",
                              {"$select": "id,displayName,securityEnabled,mailEnabled"})
        if not group["displayName"].startswith("aum-e2e-") or not group["securityEnabled"] or group["mailEnabled"]:
            raise RuntimeError("Portal group capture accepts only AUM test security groups.")
        if set(graph.owners(group_id)) != {me["id"]}:
            raise RuntimeError("The group has another owner; no unredacted owner identities will be captured.")
        members = graph.request("GET", f"/v1.0/groups/{group_id}/members", {"$select": "id", "$top": "100"})
        if members.get("@odata.nextLink") or any(row["id"] != me["id"] for row in members["value"]):
            raise RuntimeError("The group contains another member; capture is limited to the signed-in test identity.")
        return {"group_name": group["displayName"], "owner_name": me["displayName"], "verified_test_only": True}
    finally:
        graph.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--group-id", required=True)
    args = parser.parse_args()
    print(json.dumps(group_context(args.config, args.group_id)))
