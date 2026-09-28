# ADR-0033: A company address is priced, configured and proven before it is published

- **Status:** Accepted for P69; council review belongs to the lead
- **Date:** 2026-09-28
- **Packet:** P69

## Context

The installer asks whether developers should use the Azure address or a company address. The
company choice currently creates nothing and ends with manual certificate, DNS and hostname
instructions. It still publishes the Azure address to developers. A later address change means
redistributing workstation settings and managed profiles.

Research in [U30](../UNKNOWNS.md#u30--the-company-address--closed-2026-09-28) closes the tier
question. Every v2 tier accepts an uploaded PFX or Key Vault certificate. None supports a free
managed certificate. Basic v2 and Standard v2 allow one custom gateway hostname; Premium v2 allows
multiple. Standard v2 and Premium v2 require publicly resolvable custom gateway names.

## Options considered

1. Keep the manual instructions. This does not implement the selected choice.
2. Issue a free APIM managed certificate. This is unavailable on the accelerator's v2 tiers.
3. Configure an administrator-supplied certificate, the gateway hostname and DNS, then prove TLS
   and a gateway response before publishing the new address. Existing scripts and the guided-flow
   contract remain the implementation boundaries.

## Decision

Option 3. `scripts/Set-ClaudeGatewayAddress.ps1` is the shared plan/apply entry point, with
certificate/TLS helpers separated only where that responsibility needs its own tests. Importing
it performs no writes. Its plan is an ADR-0030 `New-ClaudeFlowPlan`; standalone apply also requires
the reviewed fingerprint. The installer uses its own summary confirmation, per ADR-0032.

**Inputs and ownership.** The subscription, gateway group/name, company hostname, certificate
source and optional Azure DNS zone resource ID are explicit. Only HTTPS DNS hostnames are
accepted, not URLs, wildcards or IP literals. Azure resource names and IDs are validated before
native CLI use. A supplied Azure DNS zone must be in the selected subscription and contain the
hostname below its apex. P69 adds a record to an existing zone; it does not buy a domain, create
an unrequested zone or alter a registrar's delegation.

An existing installer record is resolved and checked against the selected gateway before
approval or resource creation. A different gateway, resource group or recorded subscription is
a conflict, not an absent default. The installer refuses it, names both targets and the record
path, and describes using the selected gateway's checkout/record or preserving the old record
elsewhere before rerunning. It does not deploy first and then discover that address publication
cannot use the old record.

**Certificates.** The two choices are `KeyVault` and `Pfx`, on all three tiers. A Key Vault
certificate or secret URL is normalized to the certificate's backing secret reference after
reading certificate metadata. The certificate must be enabled, current, exportable as a PFX and
cover the hostname. The gateway's system-assigned identity is used; enabling it preserves any
user-assigned identities. The grant is Key Vault Secrets User for an RBAC vault, or an additive
get/list secret access policy for an access-policy vault. P69 does not change the permission
model, firewall, private endpoints or public network access. A blocked Key Vault route fails
explicitly.

An uploaded PFX is validated for private key, validity and hostname; its file hash binds it to
the review. A password is a `SecureString` supplied to the entry point/installer or through the
flow's transient password parameter, never an answers-file field. Certificate bytes and password
are not in the plan, record, history, transcript or error messages. Temporary ARM bodies are
removed in `finally`. Production HTTPS verifies the normal trust chain and the configured
certificate thumbprint.

**Service update.** The live service is read immediately before applying. Only
`properties.hostnameConfigurations` is patched, with all unrelated entries retained. Other
service properties are not included in a replacement `PUT`. A different existing custom Proxy
hostname on Basic v2 or Standard v2 is not silently removed: replacement requires an explicit
`ReplaceHostname` named in the review. Premium v2 can retain other custom gateway names. An
updating/failed service, changed hostname collection or changed certificate invalidates the plan.
The installer's preservation parameters also retain hostname configurations when its template
owns the existing instance.

**DNS and waits.** The exact record is `<hostname> CNAME <apim>.azure-api.net`, TTL 300 seconds
for a new record. No `apimuid` TXT is created: that record belongs to the unsupported managed
certificate path. An Azure DNS write preserves existing record metadata and uses conditional
creation/update rather than overwriting an intervening edit. An existing record pointing
elsewhere is a visible plan change, not an invisible overwrite. With another DNS provider, the
review prints the complete record and apply waits for it to resolve. Every wait states the
resource/condition, an estimate, a timeout, progress and the elapsed time on success or failure.
The APIM update timeout is 45 minutes; DNS propagation is bounded separately.

**Live correction, 2026-09-28.** The first isolated Basic v2 binding attempt, 20:44 UTC on
2026-09-27, returned `CustomHostnameOwnershipCheckFailed`: Azure could not find a CNAME from the
reserved `.test` hostname to the gateway. This is the same public-ownership requirement the
domain article explicitly describes for Standard v2 and Premium v2, now measured on Basic v2 too.
The DNS record and its resolution wait therefore precede the hostname PATCH, not follow it.
The initial sequence was wrong even for a delegated customer zone. A direct authoritative
nameserver query does not satisfy Azure's public validation. There is no documented bypass, and
P69 does not try one. The requested positive isolated SNI proof is blocked without a delegated
domain; the authoritative DNS proof and the refusal remain measurable.

**Prices.** The existing `AzureRetailPrice.ps1` helper supplies Public Zone and Public Queries
at their first tiers and Key Vault Operations and Certificate Renewal Request in the gateway
region. Empty-region global meters are valid inputs. The review distinguishes an already-billed
DNS zone from a new charge, usage rates from monthly totals, and certificate-provider charges
from Azure charges. Missing data is unknown, never zero. There is no additional APIM custom-domain
meter; the gateway's normal tier charge continues. The installer displays these components at
the address choice and includes the address in its summary before any resource is created.

**Proof and publication.** After binding and DNS readiness, a request to
`https://<hostname>/claude/v1/messages` uses the hostname for SNI and Host. A pinned, trusted TLS
certificate and the gateway's unauthenticated 401 prove that the new address reaches the gateway;
this is not a model-inference or entitlement test. Only then is `gatewayUrl` changed in the
decision record. Unknown record fields survive. Existing generated handover/profile artifacts
are updated without replacing unrelated settings; files outside the onboarding package are not
edited. Already-deployed devices still need the redistributed settings.

**Installer and flow.** The installer asks the hostname, DNS hosting and certificate source with
the other choices, validates/plans before its summary, and applies after deploying. Choosing
Azure remains unchanged. A later `-Action Change -Change address` uses `scripts/flow/Address.ps1`,
a Change-only module with questions, a read-only costed plan, fingerprinted inputs, apply and a
live check. Free-text questions are needed for a hostname and certificate/zone reference, rather
than a fabricated discovery option. Secret input is transient and excluded from the fingerprint.
Discovery recognizes a recorded URL only when its exact HTTPS hostname is a live Proxy hostname;
adding a company address does not itself create drift, and a removed binding still does.

**Isolated live proof.** No public domain is owned in the proof subscription. An explicit
`IsolatedProof` mode is restricted to Basic v2 and a reserved `.test` hostname, with an explicit
nameserver and connect IP. It permits a self-signed chain only with an exact certificate pin,
never a hostname mismatch. It does not publish a production decision record. The transcript
states that authoritative DNS and SNI were measured, not public delegation or public trust.
Resources live in an isolated proof resource group, tagged `purpose=p69-proof`, stay below USD 5, and are deleted;
the soft-deleted API Management instance is purged. No shared Foundry role or Entra group is
needed for an unauthenticated gateway response.

### Accepted scope deferral, 2026-09-28

The lead accepted deferral of the positive company-address TLS proof to P74. This environment
has no owned, publicly delegated domain, and purchasing or borrowing one is outside the approved
proof scope. Two Basic v2 uploaded-PFX attempts returned `CustomHostnameOwnershipCheckFailed`,
including the attempt after its Azure DNS CNAME answered authoritatively (15.1 seconds to readiness,
0.576 seconds for a separate direct query). The company SNI request failed its handshake, exit 35.
The default Azure endpoint returned the governed 401; the pinned HTTPS transport also ran
read-only on PowerShell 7 and 5.1. All created Azure resources were deleted and APIM purged.

This proves the authoritative CNAME, the ownership refusal, cleanup and default-host transport.
It does not prove a successful custom-hostname binding, trusted company-hostname TLS, public DNS
delegation, certificate renewal or developer publication through that live company address.
The positive criterion stays deferred, not done. P74 requires an owned delegated domain and
trusted certificate, the real priced/fingerprinted flow, and publication only after proof.

### Council round 1 contract corrections

An unattended Foundation resolves the effective address from the applied record and explicit
overrides before pricing. It passes the entire resolved selection, including an explicit Azure
choice, so the installer cannot inherit a different unreviewed address from another local record.

Proposed decisions and applied decisions are separate. Questions and plans use the proposed
record; durable `decisions` and each history entry's `from` come from the applied snapshot before
questions. A successful step returns every decision it changed, including cross-decision work
such as profile regeneration. An explicit `DecisionChanges` map commits those keys;
`RecordChanges` commits top-level values, an explicit `decisions` snapshot replaces the applied
decision snapshot, and `RemovedProperties` lists top-level removals. Legacy owning-decision return values remain supported. No decision is
inferred from an arbitrary mutation of the step's working copy. Failure does not commit its
returned changes, and unselected proposals remain unapplied.

Status, Guide, drift and discovery read applied state. Only the selected planning/apply steps
receive proposed answers. Each apply receives a private working record based on applied
decisions plus its selected proposal; other decisions remain applied until a successful result
explicitly changes them. This rule applies to every step, including DesktopSignIn and Models.
Models stages its record until profile generation succeeds, then returns both the generated
profile decision and model/deployment/tier record values. Recursive copies preserve single-item
arrays and nested values on both PowerShell hosts.

An address apply can persist an explicitly unverified recovery receipt separately from applied
decisions before it changes Azure. Recovery is limited to that receipt's gateway, previous URL,
desired certificate/hostname and expected live hostname collection. It permits only a new
address review and fingerprint; it never marks the new URL verified or permits unrelated drift.
Returning to the Azure URL clears company metadata and updates the generated handover.
The installer passes its onboarding record path to the address apply, so a failure after
replacement still leaves an unverified receipt. Recovery uses the shared subscription resolver,
including a legacy subscription stored under the Foundation decision.

Each wait has a remaining deadline. Its check runs in a cancellable process, with arguments
transferred over standard input rather than native command-line interpolation. The process tree,
including native Azure reads, is stopped at timeout; a result arriving late is not success.
The PFX is read once per planning/apply validation: that buffer is validated and hashed, and the
apply uploads the same buffer after DNS waits, without reopening the path.

## Consequences

The company choice configures what it promises, and the record changes only after the address
works. Existing domain bindings, network settings and record fields are retained. The review
states external certificate and DNS costs rather than guessing them.

A customer still supplies a domain and certificate. External DNS waits on the customer's DNS
operator. A successful ARM update can precede a DNS/TLS failure; that failure leaves the old
recorded address in place and a rerun can finish. There is no automatic rollback that deletes
resources or reverses another administrator's change. Explicit replacement of Basic/Standard's
single custom hostname is disruptive for callers of the old custom name and is described in the
review.

## Evidence and detectors

Offline tests stub Azure/ARM, DNS and TLS; run on PowerShell 7 and Windows PowerShell 5.1. They
cover no-write planning, missing prices, unsupported managed certificates, exact hostname/zone
boundaries, certificate mismatch/expiry, additive grants and patches, conditional DNS writes,
drift, bounded waits, proof before publication, installer ordering and guided-flow fingerprints.
Mutations remove each new detector and must fail with the complete assertion count. Live proof
and gate results are recorded in [STATUS](../STATUS.md).

## Sources

Retrieved 2026-09-28 locally:

- [Custom domains, certificates, DNS, SNI and update duration](https://learn.microsoft.com/azure/api-management/configure-custom-domain)
- [v2 capabilities and unavailable managed certificates](https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview)
- [Tier comparison](https://learn.microsoft.com/azure/api-management/api-management-features)
- [APIM service PATCH and hostname schema](https://learn.microsoft.com/rest/api/apimanagement/api-management-service/update?view=rest-apimanagement-2024-05-01)
- [Import a Key Vault certificate](https://learn.microsoft.com/azure/key-vault/certificates/tutorial-import-certificate)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
