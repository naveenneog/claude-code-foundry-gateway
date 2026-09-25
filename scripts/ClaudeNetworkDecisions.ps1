function New-ClaudeNetworkImplications {
    param([string]$Security,[string]$Capability,[string]$Availability,[string]$Operations,[string]$Breaks,[string]$Rollback,[string]$Dependencies)
    foreach($value in @($Security,$Capability,$Availability,$Operations,$Breaks,$Rollback,$Dependencies)){
        if([string]::IsNullOrWhiteSpace($value)){throw 'Every option needs security, capability, availability, operations, disruption, rollback and dependency implications.'}
    }
    return [pscustomobject]@{Security=$Security;Capability=$Capability;Availability=$Availability;Operations=$Operations;Breaks=$Breaks;Rollback=$Rollback;Dependencies=$Dependencies}
}

function New-ClaudeNetworkDecisionOption {
    param([string]$Id,[string]$Label,[object[]]$Costs,$Implications,[object]$Value,[bool]$Available=$true,[string]$UnavailableReason)
    if(-not $Id -or -not $Label -or -not $Implications){throw 'A decision option requires an ID, label and complete implications.'}
    return [pscustomobject]@{id=$Id;label=$Label;Costs=$Costs;Implications=$Implications;value=$Value;Available=$Available;UnavailableReason=$UnavailableReason}
}

function Select-ClaudeNetworkDecision {
    param([string]$Key,[string]$Title,[object[]]$Options,[string]$SelectedId,[string]$RecommendedId,[string]$Region,[switch]$NonInteractive)
    Write-Host "`n$Title" -ForegroundColor Cyan
    $n=0
    foreach($option in $Options){
        $n++
        Write-Host ("  {0}. {1}{2}{3}" -f $n,$option.label,$(if($option.id -eq $RecommendedId){' [recommended]'}else{''}),$(if(-not $option.Available){' [unavailable]'}else{''}))
        Show-ClaudeNetworkOptionCost -Items $option.Costs -Region $Region
        foreach($field in @('Security','Capability','Availability','Operations','Breaks','Rollback','Dependencies')){
            Write-Host ("     {0}: {1}" -f $field,$option.Implications.$field)
        }
        if(-not $option.Available){Write-Host "     Not selectable: $($option.UnavailableReason)" -ForegroundColor Yellow}
    }
    if($SelectedId){
        $chosen=@($Options|Where-Object id -eq $SelectedId)
        if($chosen.Count -ne 1){throw "Decision '$Key' was not one of the discovered options."}
        if(-not $chosen[0].Available){throw "Decision '$Key' is unavailable: $($chosen[0].UnavailableReason)"}
        return [pscustomobject]@{Key=$Key;Title=$Title;Selected=$chosen[0]}
    }
    if($NonInteractive){throw "Select '$Key' explicitly for a non-interactive run; a recommendation is not approval."}
    while($true){
        $answer=Read-Host "Choose a number for $Key (no silent selection)"
        $number=0
        if([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $Options.Count -and $Options[$number-1].Available){
            return [pscustomobject]@{Key=$Key;Title=$Title;Selected=$Options[$number-1]}
        }
        Write-Warning 'Choose an available displayed option.'
    }
}

function Get-ClaudeNetworkActionChoices {
    param([string]$Kind,$Book,[string]$Current='none',[int]$CapacityUnits=20,[int]$CurrentCapacityUnits=0,[bool]$PrivateSupported=$true,[switch]$RetireCurrentEdge,[switch]$ReuseCurrentEdge)
    $options=@()
    $config=New-ClaudeNetworkCostItem -Key ("configuration/"+$Kind) -Label 'Configuration only; dependent resources priced separately' -Quote $Book.Rates.configuration -CurrentQuantity 1 -DesiredQuantity 1
    switch($Kind){
        'topology' {
            $definitions=@(
                @('private','Internal only','No internet listener; private origins required.','Clients must have a real routed corporate path.','Availability depends on VPN/ExpressRoute, private DNS and the chosen gateway capacity.','Operate routing, DNS and private administrator access.','Internet-only clients and administrators without a route lose access.','Re-enable the previous public listener/access only through a reviewed rollback.','Approved corporate connectivity, DNS forwarding, correct APIM SKU and private backend paths.'),
                @('public','Internet-facing governed entry','Public HTTPS is retained; Entra and budgets still enforce access.','Remote developers do not need a corporate tunnel.','Regional or global availability follows the selected edge, not this label.','Operate public DNS, certificates and the selected edge/WAF.','Changing the hostname still requires client rollout; direct-origin callers can be cut off.','Restore previous endpoint and policy after checking traffic and DNS.','TLS, origin restriction if an edge is used, and reviewed internet exposure.'),
                @('hybrid','Hybrid public and private paths','Two ingress paths must apply the same authentication and WAF controls.','Corporate clients use split DNS; remote clients use public ingress.','Both paths need separate verification and consistent capacity.','Operate split DNS, two listeners and two client tests.','Wrong DNS or routing can strand corporate clients while internet access still works.','Restore the previous DNS/listener mapping and verify both origins.','Application Gateway for the automated dual-listener path; corporate routing and private DNS.')
            )
            foreach($d in $definitions){$i=New-ClaudeNetworkImplications $d[2] $d[3] $d[4] $d[5] $d[6] $d[7] $d[8];$options+=New-ClaudeNetworkDecisionOption $d[0] $d[1] @($config) $i $d[0]}
        }
        'edge' {
            foreach($id in @('application-gateway','front-door','none')){
                $costs=@()
                $keepAppGw=$Current -eq 'application-gateway' -and -not $RetireCurrentEdge
                $keepFrontDoor=$Current -eq 'front-door' -and -not $RetireCurrentEdge
                $appQuantity=[int]$keepAppGw+[int]($id -eq 'application-gateway')
                $fdQuantity=[int]$keepFrontDoor+[int]($id -eq 'front-door')
                $cu=($(if($keepAppGw){$CurrentCapacityUnits}else{0}))+($(if($id -eq 'application-gateway'){$CapacityUnits}else{0}))
                if($ReuseCurrentEdge -and $Current -eq $id){if($id -eq 'application-gateway'){$appQuantity=1;$cu=$CapacityUnits}else{$fdQuantity=1}}
                $costs+=New-ClaudeNetworkCostItem -Key 'edge/appgw-fixed' -Label 'Application Gateway WAF v2 (retained plus selected)' -Quote $Book.Rates['appgw.fixed'] -CurrentQuantity $(if($Current -eq 'application-gateway'){1}else{0}) -DesiredQuantity $appQuantity
                $costs+=New-ClaudeNetworkCostItem -Key 'edge/appgw-cu' -Label 'Configured WAF capacity allowance' -Quote $Book.Rates['appgw.cu'] -CurrentQuantity $CurrentCapacityUnits -DesiredQuantity $cu
                $costs+=New-ClaudeNetworkCostItem -Key 'edge/frontdoor-base' -Label 'Front Door Premium base (retained plus selected)' -Quote $Book.Rates['frontdoor.base'] -CurrentQuantity $(if($Current -eq 'front-door'){1}else{0}) -DesiredQuantity $fdQuantity
                $i=switch($id){
                    'application-gateway'{New-ClaudeNetworkImplications 'Regional L7 WAF; origin must still reject bypass.' 'Private, public or dual HTTPS listeners; measured SSE settings.' 'Choose minimum capacity/zones; one region is not disaster recovery.' 'Dedicated subnet, certificate lifecycle, WAF tuning, DNS and logs.' 'Clients must trust the issuer and use the selected hostname; false positives block code.' 'Restore the previous route/policy; drain existing sessions before removing the owned edge.' 'VNet/subnet, Key Vault certificate identity, supported SKU and backend DNS.'}
                    'front-door'{New-ClaudeNetworkImplications 'Global WAF and managed Private Link origin; validate the exact trusted origin connection.' 'Global public ingress, managed default-domain TLS; not a private frontend.' 'A global edge does not make single-region APIM/Foundry resilient.' 'Priced manual workflow in this packet: operate origin approvals, Front Door WAF, DNS and timeout/cache settings; the regional executor will not partially apply it.' 'No internal-only frontend; existing direct clients need the new URL; validate SSE/body limits separately.' 'Restore previous origin/client DNS before deleting an owned profile; another edge may overlap during cutover.' 'Premium SKU, supported Private Link location, supported APIM tier, and approved origin connection.'}
                    'none'{New-ClaudeNetworkImplications 'No edge WAF; APIM identity, entitlement and budgets remain mandatory.' 'Direct gateway endpoint, optionally private to corporate clients.' 'No additional proxy dependency or edge-level failover.' 'Maintain APIM and its own DNS/TLS; do not confuse this with a WAF-protected design.' 'Edge-only clients must change URL; removing an existing edge or source restriction requires a separate owned removal action.' 'Reintroduce a reviewed edge and migrate clients; no resource is silently deleted by choosing none.' 'APIM access choice and a verified direct client path.'}
                }
                $available=$id -ne 'front-door' -or $PrivateSupported
                $options+=New-ClaudeNetworkDecisionOption $id $(switch($id){'application-gateway'{'Application Gateway WAF_v2'}'front-door'{'Front Door Premium + WAF (priced manual workflow)'}default{'No edge'}}) $costs $i $id $available 'The selected APIM does not support a private Front Door origin.'
            }
        }
        'access' {
            foreach($id in @('preserve','private','public')){
                $i=switch($id){
                    'preserve'{New-ClaudeNetworkImplications 'Retain the current network exposure and authentication requirements.' 'No new network capability.' 'No planned access interruption from this decision.' 'Continue current operation; current charges remain allocated.' 'Existing limitations and exposure remain.' 'No change to undo.' 'The discovered current state remains unchanged at apply time.'}
                    'private'{New-ClaudeNetworkImplications 'Close public data-plane access only after an approved private path works.' 'Private endpoint/integration access; management and Entra endpoints may remain public.' 'DNS, routing and private-path availability become dependencies.' 'Operate endpoints, DNS, private administrators and workload egress.' 'Clients outside the approved path, direct consumers and unprepared jobs can stop working.' 'Re-enable the recorded public state only after review; retain private endpoints unless explicitly removed.' 'Supported SKU, complete private dependencies, read-only impact report and explicit acknowledgement.'}
                    'public'{New-ClaudeNetworkImplications 'Enable a public data-plane surface; Entra/RBAC remain required; no keys or broad firewall allow are added.' 'Remote access may work without a tunnel, subject to service ACLs and policy.' 'Removes a private-route dependency but increases exposure.' 'Review public filtering, monitoring and policy; existing endpoints are kept unless separately selected for removal.' 'Azure Policy may reject/revert it; delegated private database modes may require migration instead of a toggle.' 'Restore the previous publicNetworkAccess/ACL state and verify existing private clients.' 'Explicit administrator choice, effective policy permission and an access model that supports public endpoints.'}
                }
                $options+=New-ClaudeNetworkDecisionOption $id $(switch($id){'preserve'{"Keep current access ($Current)"}'private'{'Private data-plane access'}default{'Public data-plane access'}}) @($config) $i $id ($id -ne 'private' -or $PrivateSupported) 'Private access needs a supported SKU or a separately planned migration.'
            }
        }
        'network' {
            $options+=New-ClaudeNetworkDecisionOption 'reuse' 'Reuse a discovered VNet and dedicated subnets' @($config) (New-ClaudeNetworkImplications 'Retain network-team boundaries and existing controls.' 'Uses an already routed address space.' 'Inherits existing hub/DNS availability.' 'Coordinate ownership; shared subnet configuration is not replaced.' 'An unsuitable delegation or missing route prevents deployment.' 'Remove only new owned links/endpoints; existing network remains.' 'Explicit VNet/subnet IDs, sufficient capacity and network-owner approval.') 'reuse'
            $options+=New-ClaudeNetworkDecisionOption 'create' 'Create a new isolated spoke and chosen subnet layout' @($config) (New-ClaudeNetworkImplications 'Separate address/ownership boundary; it is not automatically a corporate route.' 'Dedicated edge, integration, endpoint and verifier subnets.' 'A new spoke needs connectivity and DNS before private clients work.' 'IPAM review, peerings, routes, NSGs and lifecycle ownership.' 'Overlapping addresses or absent hub transit isolate workloads.' 'Delete owned resources after restoring consumers; no shared VNet is deleted.' 'Unused discovered address space plus explicit IPAM and connectivity approval.') 'create'
        }
        'dns' {
            $reuse=New-ClaudeNetworkCostItem 'dns/selected' 'Selected shared DNS zone' $Book.Rates['dns-zone'] 1 1 -Shared
            $new=New-ClaudeNetworkCostItem 'dns/selected' 'New private DNS zone' $Book.Rates['dns-zone'] 0 1
            $options+=New-ClaudeNetworkDecisionOption 'reuse' 'Reuse a discovered private DNS zone' @($reuse) (New-ClaudeNetworkImplications 'Preserves one enterprise namespace if all links can route to its addresses.' 'Cross-subscription zones are supported with explicit access.' 'Uses existing resolver/link availability.' 'Coordinate records and links; duplicate unreachable endpoint records can break other clients.' 'An endpoint in an isolated VNet can overwrite a shared answer with an unreachable IP.' 'Remove only the owned link/group; do not delete a shared zone.' 'Zone ownership, existing records, route reachability and no duplicate namespace links.') 'reuse'
            $options+=New-ClaudeNetworkDecisionOption 'create' 'Create a new isolated private DNS zone' @($new) (New-ClaudeNetworkImplications 'Isolates the DNS answer to the selected linked network.' 'Private service names or exact-hostname split DNS.' 'Depends on the chosen VNet resolver/forwarding path.' 'Operate zone/link lifecycle and corporate conditional forwarding.' 'Linking duplicate namespaces or shadowing an entire public suffix breaks resolution.' 'Remove the owned zone/link only after consumers return to their prior DNS path.' 'Approved namespace; exact listener-name zone; no conflicting VNet link.') 'create'
        }
        'firewall' {
            foreach($id in @('none','reuse','new-standard','new-premium')){
                $costs=@($config)
                if($id -ne 'none'){
                    $tier=if($id -eq 'new-premium'){'Premium'}else{'Standard'}
                    $q=if($id -eq 'reuse'){1}else{0}
                    $costs=@(New-ClaudeNetworkCostItem 'egress/firewall' "Azure Firewall $tier" $Book.Rates["firewall.$tier"] $q 1 -Shared:($id -eq 'reuse'))
                    if($id -ne 'reuse'){$costs+=New-ClaudeNetworkCostItem 'egress/firewall-ip' 'Firewall public IP' $Book.Rates['public-ip'] 0 1}
                }
                $i=if($id -eq 'none'){New-ClaudeNetworkImplications 'No new centralized egress inspection; existing shared firewalls are not deleted.' 'System or existing routes remain as explicitly selected.' 'No additional new firewall dependency.' 'Maintain service-specific egress controls.' 'Removing an existing forced route can bypass central inspection; no route is silently removed.' 'Re-associate the reviewed route table after reachability tests.' 'Explicit route choice and approval of the current egress exposure.'}else{
                    New-ClaudeNetworkImplications 'Centralized egress filtering; TLS inspection is not automatically enabled.' 'Explicit UDR next hop and approved rule policy; Premium adds separately selected capabilities.' 'Firewall and symmetric routes become dependencies; do not force-tunnel legacy Application Gateway.' 'Network-owner/manual workflow: manage policy, DNS, SNAT, logs and updates; shared allocation is not free and the regional executor does not create an unreviewed firewall.' 'Missing Entra, Key Vault, telemetry or image-source rules can stop every request/job.' 'Restore recorded route associations before removing owned firewall resources; preserve shared firewalls.' 'Network isolation feature, correctly sized firewall subnet(s), approved policy, next hop and return routes.'
                }
                $options+=New-ClaudeNetworkDecisionOption $id $id $costs $i $id
            }
        }
        'certificate' {
            foreach($id in @('key-vault','import','evaluation-ca','front-door-managed')){
                $costs=@($config)
                if($id -eq 'evaluation-ca'){
                    $costs+=New-ClaudeNetworkCostItem 'certificate/verifier-cpu' 'Temporary verifier CPU' $Book.Rates['verifier.cpu'] 0 1
                    $costs+=New-ClaudeNetworkCostItem 'certificate/verifier-memory' 'Temporary verifier memory (2 GiB)' $Book.Rates['verifier.memory'] 0 2
                    $costs+=New-ClaudeNetworkCostItem 'certificate/private-endpoint' 'Private evaluation vault endpoint' $Book.Rates['private-endpoint'] 0 1
                    $costs+=New-ClaudeNetworkCostItem 'certificate/private-dns' 'Vault DNS zone when new' $Book.Rates['dns-zone'] 0 1
                }
                $i=switch($id){
                    'key-vault'{New-ClaudeNetworkImplications 'Versionless certificate reference; private key stays server-side.' 'Use an enabled exportable PFX from the selected vault.' 'Renewal and vault access must stay healthy.' 'Maintain CA renewal and managed-identity secret-read permission.' 'Expired/mismatched certificates or private-vault DNS errors break clients.' 'Restore the previous certificate URI/version and client trust through a reviewed rotation.' 'Routed administrator where private, correct SAN, supported PFX and Key Vault access.'}
                    'import'{New-ClaudeNetworkImplications 'Import only an approved CA-issued certificate into the selected vault; no key in source.' 'Supports an enterprise/public CA not already in Key Vault.' 'Issuance and renewal are external dependencies/costs.' 'Use the vault portal/import process from a trusted routed machine before applying the listener.' 'An unavailable private key, password, issuer or SAN blocks the change.' 'Retain the old version until new TLS is verified; rollback its reference.' 'Approved PFX already imported; external CA fee is not an Azure retail tariff.'}
                    'evaluation-ca'{New-ClaudeNetworkImplications 'Private test-only CA/server chain; no TLS bypass; working keys erased.' 'Two-day isolated evaluation, not production PKI.' 'Expires quickly; no production renewal SLA.' 'Run a temporary private verifier and distribute its public CA to test processes only.' 'Native clients fail without NODE_EXTRA_CA_CERTS; deletion/expiry ends this trust path.' 'Remove the owned evaluation vault/identity/verifier; use a production issuer before rollout.' 'Private vault endpoint/DNS, verifier subnet, certificate-officer role, and explicit evaluation-only approval.'}
                    'front-door-managed'{New-ClaudeNetworkImplications 'Front Door manages TLS for its supported default/custom domain.' 'No Application Gateway vault certificate is used.' 'Managed renewal depends on domain validation.' 'Maintain required DNS validation/route configuration.' 'Not a certificate source for Application Gateway; custom-domain validation can delay enablement.' 'Restore the previous managed domain/route before removing the endpoint.' 'Front Door Premium edge; approved hostname/domain validation.'}
                }
                $options+=New-ClaudeNetworkDecisionOption $id $id $costs $i $id
            }
        }
        'waf-mode' {
            $options+=New-ClaudeNetworkDecisionOption 'Detection' 'Detection - inspect/log, do not claim blocking' @($config) (New-ClaudeNetworkImplications 'No WAF prevention guarantee; Entra and APIM controls still apply.' 'Collect scrubbed matches for real-code tuning.' 'Fewer WAF false-positive outages during evaluation.' 'Review logs and promote deliberately after positive/negative tests.' 'Real web-attack patterns are not blocked by Detection.' 'Return to the recorded mode; do not delete policies or exclusions.' 'Scrubbed diagnostics, real client corpus and planned promotion window.') 'Detection'
            $options+=New-ClaudeNetworkDecisionOption 'Prevention' 'Prevention - enforce the chosen rule set' @($config) (New-ClaudeNetworkImplications 'Blocks matching web attacks; not a prompt-injection safety system.' 'Enforced managed/custom rules and body limits.' 'False positives can interrupt coding sessions.' 'Maintain measured field/rule exclusions and replay after updates.' 'Code, tool schemas and oversized requests can be refused.' 'Revert the recorded policy mode under incident/change approval; preserve other controls.' 'Successful real-client replay, attack/body negative tests, log scrubbing and impact approval.') 'Prevention'
        }
        default { throw "Unknown decision kind '$Kind'." }
    }
    return ,$options
}
