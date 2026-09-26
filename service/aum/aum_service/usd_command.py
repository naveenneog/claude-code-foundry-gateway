import argparse
import json

from azure.identity import AzureCliCredential, ManagedIdentityCredential

from .azure import AzureHttp, LogAnalytics, NamedValues
from .usd_reconcile import reconcile_direct


def main():
    parser = argparse.ArgumentParser(description="Reconcile dated USD budgets against observed ledger categories")
    parser.add_argument("--gateway-id", required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--managed-identity", action="store_true")
    args = parser.parse_args()
    credential = ManagedIdentityCredential() if args.managed_identity else AzureCliCredential()
    arm = NamedValues(args.gateway_id, AzureHttp(credential, "https://management.azure.com/.default"))
    logs = LogAnalytics(args.workspace_id, AzureHttp(credential, "https://api.loganalytics.io/.default"))
    print(json.dumps(reconcile_direct(arm, logs), separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
