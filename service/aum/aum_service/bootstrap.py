from functools import lru_cache
import os

from azure.identity import ManagedIdentityCredential

from .api import Api
from .auth import TokenVerifier
from .azure import AzureHttp, LogAnalytics, NamedValues
from .service import AumService
from .storage import AzureStore


@lru_cache
def application():
    required = ("AUM_TENANT_ID", "AUM_CLIENT_ID", "AUM_APIM_RESOURCE_ID",
                "AUM_WORKSPACE_ID", "AUM_STORAGE_ACCOUNT")
    settings = {name: os.environ[name] for name in required}
    credential = ManagedIdentityCredential()
    arm = NamedValues(settings["AUM_APIM_RESOURCE_ID"],
                      AzureHttp(credential, "https://management.azure.com/.default"))
    logs = LogAnalytics(settings["AUM_WORKSPACE_ID"],
                        AzureHttp(credential, "https://api.loganalytics.io/.default"))
    store = AzureStore(settings["AUM_STORAGE_ACCOUNT"], credential)
    return Api(AumService(arm, store, logs),
               TokenVerifier(settings["AUM_TENANT_ID"], settings["AUM_CLIENT_ID"]))
