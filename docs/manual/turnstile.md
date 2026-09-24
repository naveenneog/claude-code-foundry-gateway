# Turnstile operations: manual, portal and CLI paths

This is the manual companion to the capture tools, not a second deployment procedure.
Use only the subscriptions, resources and app/group assignments you already own.
Do not request tenant-wide consent, new directory roles or new users to follow it.

**Live portal evidence is blocked.** On 2026-09-24 at **18:21:32.985Z**, the dedicated
profile was copied to this worktree and reached a sign-in page. Capture stopped, without
entering credentials or attempting sign-in. No new Azure portal blade is represented as
live-verified here. The existing Turnstile application images and Graph command images
remain live evidence of those surfaces, not substitutes for Azure portal screenshots.
The numbered portal procedures below are **DOCUMENTED** from Microsoft Learn; their new
portal screenshots remain pending a usable signed-in capture profile.

## 1. Select an existing deployment

### Azure portal GUI

1. Open **Subscriptions** from the portal search bar. Select a subscription you can access
   and note its **Subscription ID**. Do not copy another environment's identifier from a guide.
2. Open **Resource groups**. Use the subscription filter and select the group containing the
   gateway. Check its **Overview** resource list.
3. Open **API Management services**, choose the existing gateway and open **Overview**.
   Record its resource group, **Gateway URL**, location and pricing tier.
4. Open the existing Foundry/Cognitive Services account from **All resources**. Use its
   **Overview** and **Keys and Endpoint** information for its endpoint; do not reveal or
   copy a key for an Entra-authenticated flow.
5. Open **Application Insights** for the gateway's component, then follow its workspace
   reference to **Log Analytics workspace**. Verify the selected resource IDs instead of
   deriving a name such as `appi-<prefix>`.
6. If the operation needs networking, open **Virtual networks** and the selected network's
   **Subnets**; choose an existing subnet. If it needs secrets/DNS, select the relevant
   **Key vaults** or **Private DNS zones** resource. A capture does not create these resources.

### Azure CLI and the discovery picker

```powershell
az account list --output table
az account show --output json
az group list --subscription $subscriptionId --output table
az apim list --subscription $subscriptionId --resource-group $resourceGroup --output table
az resource list --subscription $subscriptionId --resource-type Microsoft.CognitiveServices/accounts --output table
az resource list --subscription $subscriptionId --resource-type Microsoft.Insights/components --output table
az resource list --subscription $subscriptionId --resource-type Microsoft.OperationalInsights/workspaces --output table
az network vnet list --subscription $subscriptionId --output table
az network vnet subnet list --subscription $subscriptionId --resource-group $vnetResourceGroup --vnet-name $vnetName --output table
az keyvault list --subscription $subscriptionId --output table
az network private-dns zone list --subscription $subscriptionId --output table
```

The capture picker reuses `scripts/Get-ClaudeGatewayTarget.ps1` for recorded/environment
defaults. In an interactive terminal, ambiguous choices are numbered, with a visible
default. In unattended use, supply the same real choices explicitly:

```powershell
node guide/discover-targets.mjs --resources apim,foundry,appInsights,workspace `
  --subscription $subscriptionId --resource-group $resourceGroup `
  --apim-name $apimName --foundry $foundryName `
  --app-insights $componentName --workspace $workspaceName `
  --non-interactive --output .finops-evidence/targets.json
```

It performs reads and does not run `az account set`, so another terminal's subscription
selection is not changed. For new infrastructure and regional SKU selection, use the
installer's existing discovery/what-if flow; this capture picker selects deployed resources
and does not pretend that an existing instance's SKU proves regional provisioning capacity.

## 2. Check the existing Entra application

### Azure portal GUI

1. Open **Microsoft Entra ID** > **App registrations** > **Owned applications**.
2. Select the application by the client ID recorded in Turnstile's configuration. On
   **Overview**, verify **Application (client) ID**, **Directory (tenant) ID** and
   **Supported account types**. The reference configuration is single tenant.
3. Open **Expose an API**. Verify the **Application ID URI**, the enabled
   **Turnstile.Manage** scope and **Authorized client applications**. The Azure CLI
   pre-authorization is the working consent-free path; do not add permissions merely
   to make a screenshot.
4. Open **App roles**. Read the existing `Turnstile.Admin`, `Turnstile.Viewer` and
   `Turnstile.Manager` values and allowed member types. Do not create duplicates.
5. Open **Authentication** and inspect the existing **Single-page application** redirect URI.
6. Open **Microsoft Entra ID** > **Enterprise applications**, choose the corresponding
   application, then **Properties**. Verify **Assignment required?** is **Yes**.
7. Open **Users and groups**. Inspect the existing assignments. A screenshot is a read:
   do not press **Add user/group** or alter the owner's assignment during Phase 1.

### Azure CLI

```powershell
az ad app show --id $clientId --output json
az ad app show --id $clientId --query api --output json
az ad app show --id $clientId --query appRoles --output json
az ad sp show --id $clientId --output json
$spId = az ad sp show --id $clientId --query id --output tsv
az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo"
```

**Verification:** the CLI records and portal fields describe the same application and
enterprise application. Existing live Graph captures are in
[the Turnstile guide](../TURNSTILE.md#in-the-portal-instead).

## 3. Sign in without obtaining new consent

1. In the Azure portal, locate Turnstile's **App Service** > **Overview** and use its
   **Default domain** / **Browse** action to find the real console URL.
2. There is **no Azure portal GUI button that issues Turnstile's custom one-use login
   code**. Do not describe **Browse** or **Test this application** as if it bypassed
   the reference tenant's unresolved Microsoft-button consent requirement.
3. In an already signed-in Azure CLI terminal, obtain the code using the existing script:

   ```powershell
   ./scripts/Open-ClaudeTurnstile.ps1 -NoBrowser -TurnstileUrl $turnstileUrl `
     -Scope "api://$clientId/Turnstile.Manage"
   ```

4. To perform its two server calls by hand, without that wrapper:

   ```powershell
   $token = az account get-access-token --scope "api://$clientId/Turnstile.Manage" --query accessToken -o tsv
   $grant = Invoke-RestMethod -Method Post -Uri "$turnstileUrl/api/v1/auth/cli" `
     -Headers @{ Authorization = "Bearer $token" }
   Start-Process "$turnstileUrl/?login_code=$([uri]::EscapeDataString($grant.code))"
   ```

5. Open the link within 60 seconds. Verify the code disappears from the address. In the
   same browser, open `/api/v1/auth/me`: the role and method are the server's response.
   Never publish the token, code or unredacted profile.

This is an explicitly documented **CLI + application-browser** path, not a claimed
click-only Azure portal path. Phase 1 measured it live with no extra grants; see
[the live sign-in/profile captures](../TURNSTILE.md#live-evidence-and-sign-in-without-additional-grants).

## 4. Inspect governance and perform a reversible change

### Application GUI and Azure portal verification

1. Open the deployed console from App Service **Overview** > **Browse**, using the
   authenticated session above. Open **Gateway governance**.
2. Before editing, record the Standard tier's **Tokens per minute** and the current
   catalog/budget definitions. Use **Edit Standard**, increase only **Tokens per minute**
   by 1, then **Save and apply**. Do not lower a real team budget to force a refusal.
3. In Azure portal, open the existing **API Management service** > **APIs** >
   **Named values**. Select `tpm-standard` and read **Value**.
4. Refresh until it shows the temporary value. Do not edit the named value directly when
   governance is authored in Turnstile: that would create two writers.
5. In Turnstile, use **Edit Standard** to restore the original value and **Save and apply**.
   Re-read **Named values** > `tpm-standard` > **Value** to verify restoration.
6. In Azure portal, open the existing **Container Apps job**, then **Execution history**.
   Verify the corresponding run completed successfully. Do not start a new job
   merely to photograph it.
7. For manager/enforcement fields, open the unit/team's editor and inspect **Manager group
   object id**, **Budget enforcement**, and conditional **Allowance percent**. Cancel if
   only capturing the fields. The Azure portal has no native editor for this custom
   catalog; the live Turnstile GUI is the manual editor.
8. In **Budget Management**, inspect the selected department's **People budgets & models**
   panel without changing allocations. Compare catalog, tiers and budget definitions
   with the original baseline after the exercise.

### Equivalent read-only CLI verification

```powershell
az apim nv show --subscription $subscriptionId --resource-group $resourceGroup `
  --service-name $apimName --named-value-id tpm-standard --query value --output tsv
az containerapp job execution list --subscription $subscriptionId `
  --resource-group $resourceGroup --name $applyJobName --output table
```

Direct custom API read/write equivalents are the requests made by the documented
`capture-turnstile-live.mjs` and `verify-turnstile-live.mjs` tools. They preserve complete
tier objects and always restore in `finally`; do not replace them with a partial catalog
PUT that discards fields.

## 5. Phase 2 membership transition — only after explicit go

1. Verify the exclusive account window first. In **Microsoft Entra ID** > **Groups** >
   **All groups**, open each existing Admin/unit-manager/team-manager group.
2. Use **Owners** to verify the CLI account owns the groups. Use **Members** to verify it
   is currently in the Admin group and the two test groups are empty. Group ownership
   is not a directory administrator role.
3. Export the authored catalog. In Turnstile, add the two existing test groups' object IDs
   to the chosen unit/team **Manager group object id** fields and save.
4. **Only during the authorized Phase 2 window:** in the unit-manager group's **Members**,
   select **Add members**, select the existing CLI account and confirm. Then, in the
   Admin group's **Members**, select that same account and **Remove**. Never remove its
   **Owners** entry or another person.
5. Obtain a fresh alternate-scope token and verify it has Manager, not Admin/Viewer.
   A cached Admin token is not manager evidence. The prepared script enforces this check.
6. Test the scoped console and refused admin routes.
7. Restore in reverse: re-add the account to Admin **Members**, remove it from the test
   group's **Members**, restore the exact authored catalog, then verify Owner access.

CLI membership equivalents, to be used only in that authorized window:

```powershell
$me = az ad signed-in-user show --query id --output tsv
az ad group owner list --group $adminGroupId --output table
az ad group member list --group $adminGroupId --output table
az ad group member add --group $unitManagerGroupId --member-id $me
az ad group member remove --group $adminGroupId --member-id $me
# Always restore:
az ad group member add --group $adminGroupId --member-id $me
az ad group member remove --group $unitManagerGroupId --member-id $me
```

`guide/capture-turnstile-manager.mjs --dry-run` performs only reads. The actual guarded
sequence requires `--execute --lead-go`, the private recovery artifact and the lead's
explicit authorization. It has not been executed in this packet.

## 6. Capture/render tools and the local inspector

- `guide/capture.mjs` discovers real Azure targets; pass environment/CLI selections for
  unattended use. The manual equivalent is navigating the selected blades above and
  taking a redacted screenshot. If the copied capture profile shows sign-in, stop.
- `guide/capture-entra.mjs` takes a private `ENTRA_GROUPS_FILE` containing discovered
  group IDs/names and the desired Members/Owners blade. It no longer embeds anyone's groups.
- `guide/render-terminal.mjs` accepts `GUIDE_TRANSCRIPTS` with a dated live-command manifest
  and `REDACTIONS_FILE`; `guide/render-turnstile.mjs` accepts private transcript/redaction
  files. Rendering a PNG is a local operation, not an Azure portal feature. Manually,
  run the listed commands, retain their real output and date, redact, then take the image.
- `scripts/Capture-Transcripts.ps1` accepts discovered target parameters and a private
  replacement map. `-Flow Wizard` limits it to the installer's `-WhatIf` journey. Do not
  run the workstation-changing flow merely for documentation on an unapproved machine.
- `scripts/inspect-proxy.mjs` discovers selectable Foundry endpoints or accepts
  `--upstream`, `--port`, `--subscription`, `--resource-group`, `--foundry` and
  `--non-interactive`. `--describe` is a no-listener configuration check. The listener
  binds loopback only. There is no equivalent Azure portal control for this local proxy;
  the portal's account endpoint information supplies its destination. It creates no
  role assignment and must not be used to bypass the gateway's enforcement.

## Microsoft Learn references

Reviewed 2026-09-24:

- [Default permissions and object ownership](https://learn.microsoft.com/entra/fundamentals/users-default-permissions#object-ownership)
- [Manage groups and membership](https://learn.microsoft.com/entra/fundamentals/how-to-manage-groups)
- [Expose an API](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-expose-web-apis)
- [Assign users and groups to an application](https://learn.microsoft.com/entra/identity/enterprise-apps/assign-user-or-group-access-portal)
- [Add or edit an API Management named value](https://learn.microsoft.com/azure/api-management/api-management-howto-properties#add-or-edit-a-named-value)

Do not turn a documented portal path into a claim of live verification. New portal
screenshots are still blocked by the observed sign-in redirect.
