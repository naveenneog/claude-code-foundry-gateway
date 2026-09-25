import base64
import gzip
import json
import re
from urllib.parse import quote

from .errors import FinOpsError
from .rules import identifier, month_window


def ledger_url(workspace_resource_id, tenant_id, request_id, month):
    if not re.fullmatch(r"/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+",
                        workspace_resource_id or "", re.I):
        raise FinOpsError("Discover a Log Analytics workspace resource id with aum configure before opening the ledger.")
    if not re.fullmatch(r"[0-9a-f-]{36}", tenant_id or "", re.I):
        raise FinOpsError("Discover the workspace tenant with aum configure before opening the ledger.")
    start, end = month_window(month)
    key = identifier(request_id)
    query = f'ClaudeChargeback(datetime({start}), datetime({end}))\n| where request_id == {json.dumps(key)}'
    encoded = base64.b64encode(gzip.compress(query.encode(), mtime=0)).decode()
    return (f"https://portal.azure.com/#@{tenant_id}/blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/"
            f"resourceId/{quote(workspace_resource_id, safe='')}/source/LogsBlade.AnalyticsShareLinkToQuery/"
            f"q/{quote(quote(encoded, safe=''), safe='')}/timespan/P30D")
