# Azure CLI commands for a customer gateway setup

**Status:** commands checked against Azure CLI 2.86.0 help and the Bicep templates; not yet run end to end. The scripts remain the tested setup path. This guide is the plain Azure CLI equivalent for a reviewed customer deployment.

Run the commands in **Azure Cloud Shell bash** from the repository root. Cloud Shell has `az`, `jq`, `git` and `node`. Windows users run the bash blocks in Cloud Shell, WSL or Git Bash. In Windows PowerShell, `az` arguments containing `( ) | & < > ^` are re-parsed by `cmd.exe` through the `az.cmd` shim; `--query` expressions and Graph URLs are common examples. Keep variables in the block below and substitute environment-specific values there, not inline.

```bash
export SUBSCRIPTION_ID="<subscription-id>"
export TENANT_ID="<tenant-id>"
export LOCATION="<azure-region>"
export GATEWAY_RG="<gateway-resource-group>"
export FOUNDRY_RG="<foundry-resource-group>"
export FOUNDRY_ACCOUNT="<foundry-account-name>"
export NAME_PREFIX="<globally-unique-prefix>"
export APIM_NAME="apim-${NAME_PREFIX}"
export PUBLISHER_EMAIL="<operator-email>"
export PUBLISHER_NAME="AI Platform Team"
export STANDARD_GROUP="claude-code-standard"
export PREMIUM_GROUP="claude-code-premium"
export SONNET_DEPLOYMENT="claude-sonnet-5"
export OPUS_DEPLOYMENT="claude-opus-5"
export HAIKU_DEPLOYMENT="claude-sonnet-5"
export TPM_STANDARD="20000"
export QUOTA_STANDARD="500000"
export TPM_PREMIUM="80000"
export QUOTA_PREMIUM="5000000"
export QUOTA_ORG="100000000"
export CALLS_PER_MINUTE="120"
export MODELS_STANDARD=",${SONNET_DEPLOYMENT},"
export MODELS_PREMIUM=",${SONNET_DEPLOYMENT},${OPUS_DEPLOYMENT},"
export ENTITLEMENT_CACHE_SECONDS="3600"
export DESKTOP_EXTRA_AUDIENCE="urn:disabled:claude-extra-audience"
```

References use repository paths and line numbers from the source scripts that this guide mirrors.

## Out of scope

FinOps beyond the gateway's named values (AUM, Turnstile, chargeback reports, USD reconciler, Grafana), business units and teams, workstation setup scripts, the network WAF edge, backup/restore/update, and analytics and data deletion.

- `bu-registry` — not covered: business units and teams are out of scope for this guide.
- `bu-members` — not covered: business units and teams are out of scope for this guide.
- `bu-parents` — not covered: business units and teams are out of scope for this guide.
- `bu-modes` — not covered: business-unit budget modes are out of scope for this guide.
- `bu-unassigned` — not covered: business-unit assignment behavior is out of scope for this guide.
- `usd-budgets` — not covered: USD reconciler and FinOps budget projection are out of scope.
- `usd-budget-state` — not covered: USD reconciler state is out of scope.

## 1. Variables, prerequisites and discovery

Set the subscription and confirm the signed-in tenant.

```bash
az account show --query "{subscription:id,tenant:tenantId,user:user.name}" -o json
az account list --query "[].{name:name,id:id,tenant:tenantId,state:state,isDefault:isDefault}" -o table
```

Expected result: the intended subscription and tenant appear. This mirrors `Install-ClaudeGateway.ps1:307`, `Install-ClaudeGateway.ps1:326` and `deploy.ps1:67`.

Register the resource providers the setup uses.

```bash
az provider register --namespace Microsoft.ApiManagement
az provider register --namespace Microsoft.CognitiveServices
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.OperationalInsights
az provider show --namespace Microsoft.ApiManagement --query registrationState -o tsv
az provider show --namespace Microsoft.CognitiveServices --query registrationState -o tsv
```

Expected result: each provider reaches `Registered`. This mirrors the prerequisite phase in `scripts/Test-Prerequisites.ps1` and the resource provider checks named in `docs/SETUP.md` section 2.

Discover the Foundry account and Claude deployments.

```bash
az cognitiveservices account list --query "[?kind=='AIServices'].{name:name,rg:resourceGroup,location:location,sku:sku.name}" -o table
az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query "{id:id,kind:kind,endpoint:properties.endpoints.\"AI Foundry API\"}" -o json
az cognitiveservices account deployment list -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query "[].{name:name,model:properties.model.name,format:properties.model.format,version:properties.model.version,sku:sku.name,capacity:sku.capacity,state:properties.provisioningState}" -o table
```

Expected result: the account kind is `AIServices`, the Foundry endpoint is present, and Claude deployments are listed. This mirrors `Get-FoundryValues.ps1`, `deploy.ps1:80-106`, and `scripts/ClaudeModelDeployment.ps1:1-120`.

List deployable Claude models when no deployment exists.

```bash
az cognitiveservices account list-models -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query "[?contains(tolower(kind),'anthropic') || contains(tolower(name),'claude')].{name:name,version:version,format:format,source:source}" -o table
```

Expected result: available Claude offers are visible, or an empty table states that the account cannot deploy Claude in that region. This mirrors `Install-ClaudeGateway.ps1:418` and `scripts/ClaudeModelDeployment.ps1:160-205`.

Check the operator roles without changing them.

```bash
export FOUNDRY_ID="$(az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query id -o tsv)"
az role assignment list --scope "$FOUNDRY_ID" --include-inherited --query "[].{principal:principalName,role:roleDefinitionName,scope:scope}" -o table
az role assignment list --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${GATEWAY_RG}" --include-inherited --query "[].{principal:principalName,role:roleDefinitionName,scope:scope}" -o table
```

Expected result: the operator has enough rights to deploy the gateway resource group and to inspect or assign the Foundry data-plane role. This mirrors `Install-ClaudeGateway.ps1:1526-1537` and `docs/SETUP.md` section 2.

## 2. Gateway

Create the resource group.

```bash
az group create -n "$GATEWAY_RG" -l "$LOCATION" -o none
az group show -n "$GATEWAY_RG" --query "{name:name,location:location}" -o json
```

Expected result: the group exists in the chosen region. This mirrors `deploy.ps1:134`.

Validate the gateway template before deployment.

```bash
az bicep build --file infra/main.bicep
az deployment group what-if -g "$GATEWAY_RG" --template-file infra/main.bicep --parameters namePrefix="$NAME_PREFIX" location="$LOCATION" foundryAccountName="$FOUNDRY_ACCOUNT" foundryResourceGroup="$FOUNDRY_RG" publisherEmail="$PUBLISHER_EMAIL" publisherName="$PUBLISHER_NAME" apimSku=BasicV2 apimCapacity=1 sonnetDeployment="$SONNET_DEPLOYMENT" opusDeployment="$OPUS_DEPLOYMENT" haikuDeployment="$HAIKU_DEPLOYMENT" tpmStandard="$TPM_STANDARD" quotaStandard="$QUOTA_STANDARD" tpmPremium="$TPM_PREMIUM" quotaPremium="$QUOTA_PREMIUM" quotaOrg="$QUOTA_ORG" modelsStandard="$MODELS_STANDARD" modelsPremium="$MODELS_PREMIUM" callsPerMinute="$CALLS_PER_MINUTE" entitlementSource=named-value entitlementCacheSeconds="$ENTITLEMENT_CACHE_SECONDS" desktopExtraAudience="$DESKTOP_EXTRA_AUDIENCE"
```

Expected result: Bicep builds and what-if shows APIM, API, policy, logger, named values, diagnostics, workspace and role-assignment changes. This mirrors `deploy.ps1:157-170`, `Install-ClaudeGateway.ps1:1543-1585` and `infra/main.bicep:8-179`.

Deploy Basic v2.

```bash
az deployment group create -g "$GATEWAY_RG" -n "claude-gateway-basicv2" --template-file infra/main.bicep --parameters namePrefix="$NAME_PREFIX" location="$LOCATION" foundryAccountName="$FOUNDRY_ACCOUNT" foundryResourceGroup="$FOUNDRY_RG" publisherEmail="$PUBLISHER_EMAIL" publisherName="$PUBLISHER_NAME" apimSku=BasicV2 apimCapacity=1 sonnetDeployment="$SONNET_DEPLOYMENT" opusDeployment="$OPUS_DEPLOYMENT" haikuDeployment="$HAIKU_DEPLOYMENT" tpmStandard="$TPM_STANDARD" quotaStandard="$QUOTA_STANDARD" tpmPremium="$TPM_PREMIUM" quotaPremium="$QUOTA_PREMIUM" quotaOrg="$QUOTA_ORG" modelsStandard="$MODELS_STANDARD" modelsPremium="$MODELS_PREMIUM" callsPerMinute="$CALLS_PER_MINUTE" entitlementSource=named-value entitlementCacheSeconds="$ENTITLEMENT_CACHE_SECONDS" desktopExtraAudience="$DESKTOP_EXTRA_AUDIENCE" -o json
az deployment group show -g "$GATEWAY_RG" -n "claude-gateway-basicv2" --query "properties.outputs.{apim:apimName.value,url:gatewayUrl.value,principal:apimPrincipalId.value}" -o json
```

Expected result: outputs include the APIM name, gateway URL and APIM principal id. Basic v2 has no outbound VNet integration. This mirrors `infra/main.bicep:31-35`, `infra/main.bicep:443-460` and `Install-ClaudeGateway.ps1:1585`.

Deploy Standard v2 when outbound VNet integration is required.

```bash
export APIM_SUBNET_ID="<standard-v2-outbound-subnet-resource-id>"
az deployment group create -g "$GATEWAY_RG" -n "claude-gateway-standardv2" --template-file infra/main.bicep --parameters namePrefix="$NAME_PREFIX" location="$LOCATION" foundryAccountName="$FOUNDRY_ACCOUNT" foundryResourceGroup="$FOUNDRY_RG" publisherEmail="$PUBLISHER_EMAIL" publisherName="$PUBLISHER_NAME" apimSku=StandardV2 apimCapacity=1 apimVirtualNetworkType=External apimSubnetId="$APIM_SUBNET_ID" apimPublicNetworkAccess=Enabled sonnetDeployment="$SONNET_DEPLOYMENT" opusDeployment="$OPUS_DEPLOYMENT" haikuDeployment="$HAIKU_DEPLOYMENT" tpmStandard="$TPM_STANDARD" quotaStandard="$QUOTA_STANDARD" tpmPremium="$TPM_PREMIUM" quotaPremium="$QUOTA_PREMIUM" quotaOrg="$QUOTA_ORG" modelsStandard="$MODELS_STANDARD" modelsPremium="$MODELS_PREMIUM" callsPerMinute="$CALLS_PER_MINUTE" entitlementSource=named-value entitlementCacheSeconds="$ENTITLEMENT_CACHE_SECONDS" desktopExtraAudience="$DESKTOP_EXTRA_AUDIENCE" -o json
az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query "{sku:sku.name,vnet:virtualNetworkType,subnet:virtualNetworkConfiguration.subnetResourceId}" -o json
```

Expected result: SKU is `StandardV2`, `virtualNetworkType` is `External`, and the subnet id is retained. This mirrors `infra/main.bicep:53-80` and the preservation comments in `infra/main.bicep:36-52`.

Deploy Premium v2 when the gateway itself must be injected privately.

```bash
export APIM_SUBNET_ID="<premium-v2-apim-subnet-resource-id>"
az deployment group create -g "$GATEWAY_RG" -n "claude-gateway-premiumv2" --template-file infra/main.bicep --parameters namePrefix="$NAME_PREFIX" location="$LOCATION" foundryAccountName="$FOUNDRY_ACCOUNT" foundryResourceGroup="$FOUNDRY_RG" publisherEmail="$PUBLISHER_EMAIL" publisherName="$PUBLISHER_NAME" apimSku=PremiumV2 apimCapacity=1 apimVirtualNetworkType=Internal apimSubnetId="$APIM_SUBNET_ID" apimPublicNetworkAccess=Disabled sonnetDeployment="$SONNET_DEPLOYMENT" opusDeployment="$OPUS_DEPLOYMENT" haikuDeployment="$HAIKU_DEPLOYMENT" tpmStandard="$TPM_STANDARD" quotaStandard="$QUOTA_STANDARD" tpmPremium="$TPM_PREMIUM" quotaPremium="$QUOTA_PREMIUM" quotaOrg="$QUOTA_ORG" modelsStandard="$MODELS_STANDARD" modelsPremium="$MODELS_PREMIUM" callsPerMinute="$CALLS_PER_MINUTE" entitlementSource=named-value entitlementCacheSeconds="$ENTITLEMENT_CACHE_SECONDS" desktopExtraAudience="$DESKTOP_EXTRA_AUDIENCE" -o json
az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query "{sku:sku.name,vnet:virtualNetworkType,publicNetworkAccess:publicNetworkAccess}" -o json
```

Expected result: SKU is `PremiumV2`, VNet type is `Internal`, and public network access is disabled. This mirrors the v2 SKU and network parameters in `infra/main.bicep:31-68`.

Read policy deployment state.

```bash
az apim api show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --api-id claude-foundry --query "{path:path,subscriptionRequired:subscriptionRequired,serviceUrl:serviceUrl}" -o json
az apim api operation list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --api-id claude-foundry --query "[].{name:name,method:method,url:urlTemplate}" -o table
```

Expected result: the API path is `claude`, subscription keys are disabled, and operations include `/v1/messages` and `/v1/messages/count_tokens`. This mirrors `infra/main.bicep:303-342` and `scripts/Set-GatewayPolicy.ps1`.

Write and read back one named value the same way the helper does.

```bash
VALUE_LENGTH="$(printf '%s' "$MODELS_STANDARD" | wc -c | tr -d ' ')"
test "$VALUE_LENGTH" -le 4096
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-standard --query value -o tsv
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-standard --value "$MODELS_STANDARD" -o none
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-standard --query value -o tsv
```

Expected result: the value length is at most 4,096, and the final read returns the exact value written. This mirrors `scripts/ApimNamedValue.ps1:35-73` and `scripts/ApimNamedValue.ps1:125-191`.

## 3. Gateway managed identity and Foundry role

Read the gateway identity and Foundry scope.

```bash
export APIM_PRINCIPAL_ID="$(az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query identity.principalId -o tsv)"
export FOUNDRY_ID="$(az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query id -o tsv)"
az role assignment list --scope "$FOUNDRY_ID" --assignee "$APIM_PRINCIPAL_ID" --include-inherited --query "[?roleDefinitionName=='Cognitive Services User'].{role:roleDefinitionName,scope:scope}" -o table
```

Expected result: an existing assignment is listed, or the table is empty before the grant. This mirrors `Install-ClaudeGateway.ps1:1524-1537`.

Grant `Cognitive Services User` to the APIM managed identity when the list above is empty.

```bash
az role assignment create --assignee-object-id "$APIM_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --role "Cognitive Services User" --scope "$FOUNDRY_ID" -o json
az role assignment list --scope "$FOUNDRY_ID" --assignee "$APIM_PRINCIPAL_ID" --include-inherited --query "[?roleDefinitionName=='Cognitive Services User'].{role:roleDefinitionName,scope:scope}" -o table
```

Expected result: one assignment exists. This mirrors `infra/foundry-role.bicep` and `infra/main.bicep:430-442`.

## 4. Named values the policy needs

Set tier limits, organisation ceiling, per-minute calls and model allow lists.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id tpm-standard --value "$TPM_STANDARD" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-standard --value "$QUOTA_STANDARD" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id tpm-premium --value "$TPM_PREMIUM" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-premium --value "$QUOTA_PREMIUM" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-org --value "$QUOTA_ORG" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id calls-per-minute --value "$CALLS_PER_MINUTE" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-standard --value "$MODELS_STANDARD" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-premium --value "$MODELS_PREMIUM" -o none
az apim nv list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --query "[?starts_with(name,'tpm-') || starts_with(name,'quota-') || starts_with(name,'models-') || name=='calls-per-minute'].{name:name,value:value}" -o table
```

Expected result: values match the variables. Model lists use sentinel commas: `,claude-sonnet-5,` means only that deployment; `,,` means no model restriction. This mirrors `infra/main.bicep:350-377`, `scripts/Set-ClaudeTier.ps1:75-181` and `scripts/Add-ClaudeModel.ps1:245-253`.

Set entitlement source and resolver placeholders for the named-value path.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id tenant-id --value "$TENANT_ID" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-source --value "named-value" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-resolver-url --value "https://resolver-not-deployed.invalid" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-resolver-audience --value "https://resolver-not-deployed.invalid" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-cache-seconds --value "$ENTITLEMENT_CACHE_SECONDS" -o none
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id tenant-id --query value -o tsv
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-source --query value -o tsv
```

Expected result: `tenant-id` matches the deployment tenant and `entitlement-source` is `named-value`. This mirrors `infra/main.bicep:350`, `infra/main.bicep:144-160`, `infra/main.bicep:372-376` and `docs/SCALE.md:639-675`.

Initialize authorization and budget override lists.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id allow-standard --value "," -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id allow-premium --value "," -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-overrides --value ",," -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id external-idp-extra-audience --value "$DESKTOP_EXTRA_AUDIENCE" -o none
az apim nv list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --query "[?name=='allow-standard' || name=='allow-premium' || name=='quota-overrides' || name=='external-idp-extra-audience'].{name:name,value:value}" -o table
```

Expected result: `allow-*` values are comma-sentinel lists, `quota-overrides` is `,,`, and the Desktop audience is the disabled sentinel until external sign-in is configured. This mirrors `infra/main.bicep:215-224`, `infra/main.bicep:367-370`, `scripts/Sync-ClaudeAccess.ps1:122-129`, `scripts/ClaudeBudgetOverride.ps1:1-29` and `scripts/ApimNamedValue.ps1:150-154`.

## 5. Entra groups and entitlement publishing

Create or discover the two tier groups.

```bash
az ad group show --group "$STANDARD_GROUP" --query "{id:id,displayName:displayName}" -o json
az ad group show --group "$PREMIUM_GROUP" --query "{id:id,displayName:displayName}" -o json
az ad group create --display-name "$STANDARD_GROUP" --mail-nickname "$STANDARD_GROUP" --query "{id:id,displayName:displayName}" -o json
az ad group create --display-name "$PREMIUM_GROUP" --mail-nickname "$PREMIUM_GROUP" --query "{id:id,displayName:displayName}" -o json
```

Expected result: each group has an object id; run the create commands only when the show command confirms absence. This mirrors `deploy.ps1:182-187` and `Install-ClaudeGateway.ps1:1597-1600`.

Read transitive members from Microsoft Graph as users and service principals.

```bash
export GRAPH_TOKEN="$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)"
export STANDARD_GROUP_ID="$(az ad group show --group "$STANDARD_GROUP" --query id -o tsv)"
export PREMIUM_GROUP_ID="$(az ad group show --group "$PREMIUM_GROUP" --query id -o tsv)"
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/${PREMIUM_GROUP_ID}/transitiveMembers/microsoft.graph.user?\$select=id,displayName,userPrincipalName&\$top=999&\$count=true" --headers "ConsistencyLevel=eventual" --resource https://graph.microsoft.com -o json
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/${PREMIUM_GROUP_ID}/transitiveMembers/microsoft.graph.servicePrincipal?\$select=id,displayName&\$top=999&\$count=true" --headers "ConsistencyLevel=eventual" --resource https://graph.microsoft.com -o json
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/${STANDARD_GROUP_ID}/transitiveMembers/microsoft.graph.user?\$select=id,displayName,userPrincipalName&\$top=999&\$count=true" --headers "ConsistencyLevel=eventual" --resource https://graph.microsoft.com -o json
az rest --method get --url "https://graph.microsoft.com/v1.0/groups/${STANDARD_GROUP_ID}/transitiveMembers/microsoft.graph.servicePrincipal?\$select=id,displayName&\$top=999&\$count=true" --headers "ConsistencyLevel=eventual" --resource https://graph.microsoft.com -o json
```

Expected result: each successful response contains a JSON `value` array. A Graph error is an error, not an empty group; only a successful empty `value` array is empty. This mirrors `scripts/ClaudeGraphMembership.ps1:31-151`. The script uses direct REST in PowerShell because `az.cmd` on Windows re-parses `&`; in Cloud Shell bash, `az rest` is safe when the URL is quoted.

Publish premium first, then standard without duplicates.

```bash
PREMIUM_OIDS="$(jq -r '.value[].id' premium-users.json premium-service-principals.json 2>/dev/null | awk 'NF' | sort -u | paste -sd, -)"
STANDARD_OIDS="$(jq -r '.value[].id' standard-users.json standard-service-principals.json 2>/dev/null | awk 'NF' | sort -u | grep -iv -f <(printf '%s\n' "$PREMIUM_OIDS" | tr ',' '\n') | paste -sd, -)"
PREMIUM_VALUE="$(test -n "$PREMIUM_OIDS" && printf ',%s,' "$PREMIUM_OIDS" || printf ',')"
STANDARD_VALUE="$(test -n "$STANDARD_OIDS" && printf ',%s,' "$STANDARD_OIDS" || printf ',')"
test "$(printf '%s' "$PREMIUM_VALUE" | wc -c | tr -d ' ')" -le 4096
test "$(printf '%s' "$STANDARD_VALUE" | wc -c | tr -d ' ')" -le 4096
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id allow-premium --value "$PREMIUM_VALUE" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id allow-standard --value "$STANDARD_VALUE" -o none
az apim nv list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --query "[?name=='allow-premium' || name=='allow-standard'].{name:name,value:value}" -o table
```

Expected result: each allow list has the `,oid,` form. A person in both groups appears only in `allow-premium`; premium precedence is deliberate. The 4,096-character tests fail before writing rather than truncating. This mirrors `scripts/Sync-ClaudeAccess.ps1:77-130` and `scripts/ApimNamedValue.ps1:35-73`.

Add one developer to a tier and publish.

```bash
export DEVELOPER_UPN="<developer-upn-or-mail>"
export DEVELOPER_ID="$(az ad user show --id "$DEVELOPER_UPN" --query id -o tsv)"
az ad group member add --group "$STANDARD_GROUP" --member-id "$DEVELOPER_ID"
az ad group member remove --group "$PREMIUM_GROUP" --member-id "$DEVELOPER_ID"
az ad group member list --group "$STANDARD_GROUP" --query "[?id=='${DEVELOPER_ID}'].id" -o tsv
```

Expected result: the developer id appears in the standard group and not in premium. This mirrors `scripts/Set-ClaudeDeveloper.ps1:175-260`.

Remove one developer from both tiers and publish.

```bash
az ad group member remove --group "$STANDARD_GROUP" --member-id "$DEVELOPER_ID"
az ad group member remove --group "$PREMIUM_GROUP" --member-id "$DEVELOPER_ID"
az ad group member list --group "$STANDARD_GROUP" --query "[?id=='${DEVELOPER_ID}'].id" -o tsv
az ad group member list --group "$PREMIUM_GROUP" --query "[?id=='${DEVELOPER_ID}'].id" -o tsv
```

Expected result: both verification commands return no rows. This mirrors `scripts/Set-ClaudeDeveloper.ps1:175-260`.

## 6. Day-two tier operations

List the two tiers.

```bash
az apim nv list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --query "[?name=='tpm-standard' || name=='quota-standard' || name=='models-standard' || name=='tpm-premium' || name=='quota-premium' || name=='models-premium'].{name:name,value:value}" -o table
```

Expected result: only `standard` and `premium` tier values are listed. A third tier is a policy change, not a named-value operation, because the policy names the two tiers directly (`docs/ONBOARDING.md:408-412`, `docs/ONBOARDING.md:472-476`). This mirrors `scripts/Set-ClaudeTier.ps1:1-34`.

Change one tier's model list and limits.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id tpm-standard --value "30000" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-standard --value "750000" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-standard --value ",${SONNET_DEPLOYMENT}," -o none
az apim nv list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --query "[?name=='tpm-standard' || name=='quota-standard' || name=='models-standard'].{name:name,value:value}" -o table
```

Expected result: the new values appear and take effect on the next request. This mirrors `scripts/Set-ClaudeTier.ps1:112-181`.

Set one person's daily token budget.

```bash
export BUDGET_OID="$(az ad user show --id "$DEVELOPER_UPN" --query id -o tsv | tr '[:upper:]' '[:lower:]')"
export CURRENT_OVERRIDES="$(az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-overrides --query value -o tsv)"
export NEW_OVERRIDES=",${BUDGET_OID}=2000000,"
test "$(printf '%s' "$NEW_OVERRIDES" | wc -c | tr -d ' ')" -le 4096
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-overrides --value "$NEW_OVERRIDES" -o none
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-overrides --query value -o tsv
```

Expected result: `quota-overrides` contains `,<oid>=2000000,`. Preserve existing entries when more than one person has an override; the script reads the full map before changing it. This mirrors `scripts/Set-ClaudeBudget.ps1:1-41`, `scripts/Set-ClaudeBudget.ps1:137-220` and `scripts/ClaudeBudgetOverride.ps1:1-29`.

Clear that person's daily token budget.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-overrides --value ",," -o none
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id quota-overrides --query value -o tsv
```

Expected result: `,,` means no personal overrides. This mirrors `scripts/ClaudeBudgetOverride.ps1:24-29`.

Review Foundry deployments before adding a model.

```bash
az cognitiveservices account deployment list -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query "[].{name:name,model:properties.model.name,format:properties.model.format,version:properties.model.version,sku:sku.name,capacity:sku.capacity}" -o table
az apim nv list -g "$GATEWAY_RG" --service-name "$APIM_NAME" --query "[?name=='models-standard' || name=='models-premium'].{name:name,value:value}" -o table
```

Expected result: the deployment exists before it is added to a tier. This mirrors `scripts/Sync-ClaudeModels.ps1:1-91` and `scripts/Add-ClaudeModel.ps1:109-153`.

Deploy a new Claude model through ARM when Azure requires Anthropic provider data.

```bash
cat > deployment-body.json <<JSON
{"sku":{"name":"GlobalStandard","capacity":50},"properties":{"model":{"format":"Anthropic","name":"<model-name>","version":"<version>"},"modelProviderData":{"organizationName":"<organization-name>","industry":"<industry>","countryCode":"<country-code>"}}}
JSON
az rest --method put --headers "Content-Type=application/json" --body @deployment-body.json --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${FOUNDRY_RG}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_ACCOUNT}/deployments/<deployment-name>?api-version=2025-12-01" -o json
az cognitiveservices account deployment show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --deployment-name "<deployment-name>" --query "{name:name,state:properties.provisioningState,model:properties.model.name}" -o json
```

Expected result: provisioning reaches `Succeeded`. This mirrors `scripts/ClaudeModelDeployment.ps1:319-395`; it uses ARM because `az cognitiveservices account deployment create` cannot send `modelProviderData` for Anthropic deployments.

Add the deployed model to tiers and record prices.

```bash
export NEW_MODEL="<deployment-name>"
export MODELS_PREMIUM_NOW="$(az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-premium --query value -o tsv)"
export MODELS_PREMIUM_NEXT="$(printf '%s' "$MODELS_PREMIUM_NOW" | sed 's/,$//'),${NEW_MODEL},"
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-premium --value "$MODELS_PREMIUM_NEXT" -o none
jq --arg model "$NEW_MODEL" --argjson input 5 --argjson output 25 '.date=(now|strftime("%Y-%m-%d")) | .source="list price, https://platform.claude.com/docs/en/about-claude/pricing" | .models[$model]={inputPerM:$input,outputPerM:$output}' config/price-book.json > config/price-book.next.json
mv config/price-book.next.json config/price-book.json
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-premium --query value -o tsv
```

Expected result: the premium model list contains the new deployment with sentinel commas, and `config/price-book.json` has a dated price entry. This mirrors `scripts/Add-ClaudeModel.ps1:208-253`.

## 7. Developer sign-in mode and Claude Desktop sign-in

Create or discover the Desktop public-client app.

```bash
export DESKTOP_APP_NAME="Claude Desktop gateway"
az ad app list --display-name "$DESKTOP_APP_NAME" --query "[].{appId:appId,displayName:displayName}" -o table
az ad app create --display-name "$DESKTOP_APP_NAME" --sign-in-audience AzureADMyOrg --query "{appId:appId,displayName:displayName}" -o json
```

Expected result: one application id is available. Run create only when list confirms absence. This mirrors `scripts/New-ClaudeDesktopEntraApp.ps1:29-39`.

Set public-client redirect URIs, including broker redirects when the Desktop profile uses broker flow.

```bash
export DESKTOP_CLIENT_ID="<desktop-public-client-app-id>"
az ad app update --id "$DESKTOP_CLIENT_ID" --is-fallback-public-client true --public-client-redirect-uris "http://127.0.0.1/callback" "ms-appx-web://Microsoft.AAD.BrokerPlugin/${DESKTOP_CLIENT_ID}" "msauth.com.anthropic.claudefordesktop://auth" -o none
az ad app show --id "$DESKTOP_CLIENT_ID" --query "{appId:appId,publicClient:publicClient.redirectUris,isFallbackPublicClient:isFallbackPublicClient}" -o json
```

Expected result: the redirect URI list contains the loopback URI and broker URIs when broker is enabled. This mirrors `scripts/New-ClaudeDesktopEntraApp.ps1:43-64`.

Publish the Desktop gateway audience into APIM.

```bash
export DESKTOP_GATEWAY_AUDIENCE="$DESKTOP_CLIENT_ID"
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id external-idp-extra-audience --value "$DESKTOP_GATEWAY_AUDIENCE" -o none
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id external-idp-extra-audience --query value -o tsv
```

Expected result: the app id is stored as `external-idp-extra-audience` for id-token mode. For access-token mode, store the gateway API audience instead. Consent is not granted by these commands; a tenant admin grants user/admin consent for scopes that require it. This mirrors `Install-ClaudeGateway.ps1:1141-1238`, `Install-ClaudeGateway.ps1:1573` and `scripts/ClaudeDesktopSignIn.ps1:92-101`.

## 8. Developer handover file

Generate `onboarding/claude-gateway.json` with the same schema the installer writes.

```bash
mkdir -p onboarding
GATEWAY_URL="$(az deployment group show -g "$GATEWAY_RG" -n "claude-gateway-basicv2" --query properties.outputs.gatewayUrl.value -o tsv)"
jq -n --arg gatewayUrl "$GATEWAY_URL" --arg tenantId "$TENANT_ID" --arg apimName "$APIM_NAME" --arg resourceGroup "$GATEWAY_RG" --arg standardGroup "$STANDARD_GROUP" --arg premiumGroup "$PREMIUM_GROUP" --arg sonnet "$SONNET_DEPLOYMENT" --arg opus "$OPUS_DEPLOYMENT" --arg haiku "$HAIKU_DEPLOYMENT" --argjson tpmStandard "$TPM_STANDARD" --argjson quotaStandard "$QUOTA_STANDARD" --argjson tpmPremium "$TPM_PREMIUM" --argjson quotaPremium "$QUOTA_PREMIUM" --argjson quotaOrg "$QUOTA_ORG" --arg desktopClientId "$DESKTOP_CLIENT_ID" --arg issuer "https://login.microsoftonline.com/${TENANT_ID}/v2.0" '{mode:"gateway",gatewayUrl:$gatewayUrl,tenantId:$tenantId,apimName:$apimName,resourceGroup:$resourceGroup,standardGroup:$standardGroup,premiumGroup:$premiumGroup,authMode:"interactive",desktopSignIn:{kind:"external-idp",flow:"browser",bearerTokenType:"id_token",clientId:$desktopClientId,issuer:$issuer},deployments:[{name:$sonnet,model:$sonnet},{name:$opus,model:$opus},{name:$haiku,model:$haiku}],models:[$sonnet,$opus,$haiku],tiers:{standard:{tokensPerMinute:$tpmStandard,tokensPerDay:$quotaStandard},premium:{tokensPerMinute:$tpmPremium,tokensPerDay:$quotaPremium}},organisation:{tokensPerMonth:$quotaOrg,shared:true,softCap:true},generated:(now|strftime("%Y-%m-%d %H:%M"))}' > onboarding/claude-gateway.json
jq -e '.mode=="gateway" and (.gatewayUrl|test("^https://")) and (.desktopSignIn.kind=="external-idp" or .desktopSignIn.kind=="helper-script")' onboarding/claude-gateway.json
```

Expected result: `jq -e` exits 0, and the file contains no secrets. This mirrors `Install-ClaudeGateway.ps1:1712-1729` and `onboarding/README.md:13-41`.

## 9. Optional company address

Review the current gateway hostnames before binding a company address.

```bash
az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query "{sku:sku.name,hosts:hostnameConfigurations[].{type:type,hostName:hostName,certificateSource:certificateSource,certificateStatus:certificateStatus}}" -o json
```

Expected result: built-in Azure hostname remains, and any existing custom Proxy hostname is visible before replacement. This mirrors `scripts/ClaudeGatewayAddress.ps1:12-18`, `scripts/ClaudeGatewayAddress.ps1:88-91` and `scripts/Set-ClaudeGatewayAddress.ps1`.

Validate a Key Vault certificate and grant APIM access.

```bash
export HOSTNAME="<gateway.company.example>"
export KEYVAULT_NAME="<key-vault-name>"
export CERT_NAME="<certificate-name>"
export CERT_SECRET_ID="$(az keyvault certificate show --vault-name "$KEYVAULT_NAME" --name "$CERT_NAME" --query sid -o tsv)"
az keyvault certificate show --vault-name "$KEYVAULT_NAME" --name "$CERT_NAME" --query "{enabled:attributes.enabled,subject:policy.x509CertificateProperties.subject,secretContentType:policy.secretProperties.contentType}" -o json
az role assignment create --assignee-object-id "$APIM_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope "$(az keyvault show -n "$KEYVAULT_NAME" --query id -o tsv)" -o json
```

Expected result: the certificate is enabled, backed by a PFX secret, and the gateway identity can read it. This mirrors `scripts/ClaudeGatewayCertificate.ps1:80-103` and `scripts/ClaudeGatewayAddress.ps1:107-115`.

Patch APIM hostname configurations and prove TLS before publishing the handover URL.

```bash
APIM_ID="$(az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query id -o tsv)"
az rest --method patch --headers "Content-Type=application/json" --body "{\"properties\":{\"hostnameConfigurations\":[{\"type\":\"Proxy\",\"hostName\":\"${HOSTNAME}\",\"certificateSource\":\"KeyVault\",\"keyVaultId\":\"${CERT_SECRET_ID}\",\"identityClientId\":null}]}}" --url "https://management.azure.com${APIM_ID}?api-version=2024-05-01" -o json
az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query "hostnameConfigurations[?hostName=='${HOSTNAME}'].{hostName:hostName,status:certificateStatus}" -o json
curl -sS -o /dev/null -w "%{http_code}\n" "https://${HOSTNAME}/claude/v1/messages"
```

Expected result: the hostname binding exists and an unauthenticated request returns `401`, proving DNS, SNI and certificate before clients use the address. This mirrors `scripts/ClaudeGatewayAddress.ps1:248-351`.

## 10. Optional Cosmos projection

Run read-only preflight checks before any projection write.

```bash
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-source --query value -o tsv
az apim show -g "$GATEWAY_RG" -n "$APIM_NAME" --query "{sku:sku.name,principal:identity.principalId,location:location}" -o json
az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query "{id:id,kind:kind}" -o json
az deployment group what-if -g "$GATEWAY_RG" --template-file infra/projection-network.bicep --parameters namePrefix="$NAME_PREFIX" cosmosAccountName="cosmos-${NAME_PREFIX}" -o json
az deployment group what-if -g "$GATEWAY_RG" --template-file infra/projection.bicep --parameters namePrefix="$NAME_PREFIX" networkAccess=private-only redundancy=single throughput=400 -o json
```

Expected result: current entitlement source is visible, APIM has an identity, and what-if is reviewed. This mirrors `scripts/Deploy-ClaudeProjection.ps1`, `scripts/ClaudeProjectionChecks.ps1` and `docs/SCALE.md:515-527`.

Create the resolver app registration as a tenant-admin step.

```bash
export RESOLVER_APP_NAME="Claude entitlement resolver"
az ad app create --display-name "$RESOLVER_APP_NAME" --sign-in-audience AzureADMyOrg --query "{appId:appId,id:id,displayName:displayName}" -o json
az ad app show --id "<resolver-app-id>" --query "{appId:appId,identifierUris:identifierUris,appRoles:appRoles}" -o json
```

Expected result: a tenant admin owns the app-registration step and later grants any required Graph permissions. This mirrors the resolver boundary in `infra/resolver.bicep:41-51` and P84's tenant-admin separation.

Deploy private projection storage and networking.

```bash
az deployment group create -g "$GATEWAY_RG" -n "claude-projection-network" --template-file infra/projection-network.bicep --parameters namePrefix="$NAME_PREFIX" cosmosAccountName="cosmos-${NAME_PREFIX}" runnerEnabled=true -o json
az deployment group create -g "$GATEWAY_RG" -n "claude-projection-store" --template-file infra/projection.bicep --parameters namePrefix="$NAME_PREFIX" networkAccess=private-only redundancy=single throughput=400 -o json
az deployment group show -g "$GATEWAY_RG" -n "claude-projection-store" --query properties.outputs -o json
```

Expected result: Cosmos DB is private and outputs provide account/database/container names. This mirrors `infra/projection-network.bicep:26-49`, `infra/projection.bicep:11-68` and `scripts/Deploy-ClaudeProjection.ps1`.

Deploy the resolver with Standard v2 outbound VNet integration and upload code.

```bash
export INTEGRATION_SUBNET_ID="<resolver-integration-subnet-id>"
export RESOLVER_APP_ID="<resolver-app-id>"
az deployment group create -g "$GATEWAY_RG" -n "claude-resolver" --template-file infra/resolver.bicep --parameters namePrefix="$NAME_PREFIX" cosmosAccountName="cosmos-${NAME_PREFIX}" integrationSubnetId="$INTEGRATION_SUBNET_ID" resolverAppId="$RESOLVER_APP_ID" allowedCallerAppIds="$RESOLVER_APP_ID" -o json
cd resolver && zip -r ../resolver.zip . && cd ..
az functionapp deployment source config-zip -g "$GATEWAY_RG" -n "func-${NAME_PREFIX}-resolver" --src resolver.zip -o json
az functionapp show -g "$GATEWAY_RG" -n "func-${NAME_PREFIX}-resolver" --query "{name:name,state:state,host:defaultHostName}" -o json
```

Expected result: the Function app is running with VNet integration and resolver code uploaded. This mirrors `infra/resolver.bicep:27-108`, `scripts/Deploy-ClaudeProjection.ps1` and `scripts/ClaudeRunner.ps1`.

Set resolver named values without switching entitlement.

```bash
export RESOLVER_URL="https://func-${NAME_PREFIX}-resolver.azurewebsites.net/api"
export RESOLVER_AUDIENCE="api://${RESOLVER_APP_ID}"
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-resolver-url --value "$RESOLVER_URL" -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-resolver-audience --value "$RESOLVER_AUDIENCE" -o none
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-source --query value -o tsv
```

Expected result: resolver URL and audience are set, while `entitlement-source` remains `named-value`. This mirrors `docs/SCALE.md:670-675`.

Populate and compare the projection through an in-VNet runner container.

```bash
az container create -g "$GATEWAY_RG" -n "aci-${NAME_PREFIX}-runner" --image mcr.microsoft.com/devcontainers/javascript-node:22 --restart-policy Never --command-line "sleep 3600" -o json
az container exec -g "$GATEWAY_RG" -n "aci-${NAME_PREFIX}-runner" --exec-command "/bin/bash -lc 'node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-${NAME_PREFIX}.documents.azure.com:443/ --tenant ${TENANT_ID} --snapshot /work/snapshot.json'"
az container exec -g "$GATEWAY_RG" -n "aci-${NAME_PREFIX}-runner" --exec-command "/bin/bash -lc 'node /work/sync/src/apply-projection.mjs --cosmos https://cosmos-${NAME_PREFIX}.documents.azure.com:443/ --tenant ${TENANT_ID} --compare /work/gateway-decisions.json'"
```

Expected result: population and comparison run from inside the VNet. Cosmos is private, and Azure CLI has no supported data-plane write path for this projection, so the runner performs the writes and comparison. This mirrors `scripts/Sync-ClaudeProjection.ps1`, `scripts/ClaudeRunner.ps1`, `docs/SCALE.md:681-726` and `infra/projection-network.bicep:46-49`.

Projection switch status.

```bash
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id entitlement-source --query value -o tsv
```

Expected result: the value stays `named-value`. P84 refuses automated switching. `docs/SCALE.md:744-760` states the reason: records lease for at most two hours, and without renewal every developer receives 503 after expiry. The legacy manual command can change `entitlement-source` to `projection`, but it is not P84-protected admission, creates no reconciler, and can cause that outage. P86, in progress on another branch, will add supported renewal and switch; this guide does not include P86's content.

## 11. Verification

Send a real request with the signed-in user's Foundry token through the gateway.

```bash
export GATEWAY_URL="$(az deployment group show -g "$GATEWAY_RG" -n "claude-gateway-basicv2" --query properties.outputs.gatewayUrl.value -o tsv)"
export FOUNDRY_TOKEN="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"
curl -sS -o response.json -w "%{http_code}\n" -H "Authorization: Bearer ${FOUNDRY_TOKEN}" -H "Content-Type: application/json" -d "{\"model\":\"${SONNET_DEPLOYMENT}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Return the word ok.\"}]}" "${GATEWAY_URL}/v1/messages"
jq -r '.content[0].text // .error.message' response.json
```

Expected result: an entitled caller receives HTTP `200` and a model response. This mirrors `scripts/Test-ClaudeHealth.ps1`.

Verify a non-entitled caller is refused.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id allow-standard --value "," -o none
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id allow-premium --value "," -o none
curl -sS -o response-forbidden.json -w "%{http_code}\n" -H "Authorization: Bearer ${FOUNDRY_TOKEN}" -H "Content-Type: application/json" -d "{\"model\":\"${SONNET_DEPLOYMENT}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Return the word ok.\"}]}" "${GATEWAY_URL}/v1/messages"
jq -r '.error.message' response-forbidden.json
```

Expected result: HTTP `403` with an entitlement refusal. Restore allow lists from the group sync after this check. This mirrors `scripts/Test-ClaudeHealth.ps1` and `scripts/Sync-ClaudeAccess.ps1`.

Verify a model outside the tier is refused.

```bash
az apim nv update -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id models-standard --value ",${SONNET_DEPLOYMENT}," -o none
curl -sS -o response-model.json -w "%{http_code}\n" -H "Authorization: Bearer ${FOUNDRY_TOKEN}" -H "Content-Type: application/json" -d "{\"model\":\"${OPUS_DEPLOYMENT}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Return the word ok.\"}]}" "${GATEWAY_URL}/v1/messages"
jq -r '.error.message' response-model.json
```

Expected result: HTTP `403` or gateway refusal naming the model outside the tier. This mirrors `scripts/Test-ClaudeHealth.ps1` and `scripts/Measure-ClaudeCeiling.ps1`.

Check for direct Foundry bypass.

```bash
az role assignment list --scope "$FOUNDRY_ID" --include-inherited --query "[?roleDefinitionName=='Cognitive Services User'].{principal:principalName,principalType:principalType,scope:scope}" -o table
az role assignment list --scope "$FOUNDRY_ID" --include-inherited --query "[?roleDefinitionName=='Cognitive Services User' && principalId!='${APIM_PRINCIPAL_ID}'].{principal:principalName,principalId:principalId}" -o table
```

Expected result: the gateway identity has the role; developers do not hold direct `Cognitive Services User` unless there is an explicitly approved bypass. This mirrors `scripts/Get-ClaudeBypass.ps1`.

Measure the per-minute call ceiling.

```bash
az apim nv show -g "$GATEWAY_RG" --service-name "$APIM_NAME" --named-value-id calls-per-minute --query value -o tsv
for i in $(seq 1 5); do curl -sS -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer ${FOUNDRY_TOKEN}" -H "Content-Type: application/json" -d "{\"model\":\"${SONNET_DEPLOYMENT}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" "${GATEWAY_URL}/v1/messages"; done
```

Expected result: normal traffic returns `200`; a deliberate high-rate test eventually returns the gateway's rate-limit status. This mirrors `scripts/Measure-ClaudeCeiling.ps1`.

## 12. Teardown

Read resources before deletion.

```bash
az resource list -g "$GATEWAY_RG" --query "[].{type:type,name:name}" -o table
az role assignment list --scope "$FOUNDRY_ID" --assignee "$APIM_PRINCIPAL_ID" --query "[].{id:id,role:roleDefinitionName}" -o table
```

Expected result: the operator sees the exact resources and role assignments that will be removed. This mirrors the installer's explicit review style before writes.

Delete the gateway resource group when the deployment was isolated to it.

```bash
az group delete -n "$GATEWAY_RG" --yes --no-wait
az group exists -n "$GATEWAY_RG"
```

Expected result: the group deletion starts; `az group exists` eventually returns `false`. Do not use this command if the group contains shared resources. This mirrors the resource-group boundary created by `deploy.ps1:134`.

Remove the Foundry role assignment if the gateway identity remains after partial teardown.

```bash
ROLE_ASSIGNMENT_ID="$(az role assignment list --scope "$FOUNDRY_ID" --assignee "$APIM_PRINCIPAL_ID" --query "[?roleDefinitionName=='Cognitive Services User']|[0].id" -o tsv)"
az role assignment delete --ids "$ROLE_ASSIGNMENT_ID"
az role assignment list --scope "$FOUNDRY_ID" --assignee "$APIM_PRINCIPAL_ID" --query "[?roleDefinitionName=='Cognitive Services User'].id" -o tsv
```

Expected result: no assignment remains for that gateway identity. This mirrors the Foundry role assignment in `infra/foundry-role.bicep`.
