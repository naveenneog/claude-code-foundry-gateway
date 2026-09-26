# ADR-0029: AUM developer membership uses delegated Graph and gateway publication

- **Status:** Accepted
- **Date:** 2026-09-26
- **Packet:** P64
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

Administrators asked whether AUM or Turnstile could add and remove developers by
typing an email address. Before this packet, neither did. The PowerShell
`Set-ClaudeDeveloper.ps1` script already resolved a single directory user by
object id, `mail`, `userPrincipalName` and guest `#EXT#` UPN stem, but its default
tier group names were fixed strings. AUM could search observed gateway people,
not the whole directory, and its delegated group member command accepted only an
object id for groups the caller owned. Turnstile intentionally does not read or
write Entra membership.

## Decision

AUM adds `aum developer find|add|remove`. It uses the signed-in administrator's
Azure CLI Microsoft Graph delegated token. It does not request consent, create an
application permission, grant a directory role, or make Turnstile a membership
writer.

Directory search is a bounded Graph `/users` query with `ConsistencyLevel:
eventual`, `$count=true`, paging and selected fields only. It returns display
name, UPN/mail, member/guest type, and current gateway entitlement/unit from the
gateway's published data. Exact writes resolve one account with the same order as
`Set-ClaudeDeveloper.ps1`: object id, `mail`, `userPrincipalName`,
`otherMails`, then guest `#EXT#` UPN stem. Ambiguity is refused and the operator
must pass the object id.

Tier groups are discovered from the gateway record or selected authority data;
they are not hardcoded into AUM. Add preview lists the direct group writes:
add the chosen tier, remove the other tier, and optionally add one catalog
unit/team group. Remove preview lists removal from both tier groups and every
catalog unit/team group. Apply performs each Graph `$ref` write once, verifies it
with bounded propagation reads, then publishes the gateway through the selected
authority path. Direct runs the existing access sync; Turnstile-backed operation
uses the delegated publish-as-admin path.

AUM no longer pre-blocks tier/unit writes with `require_owner`. Group ownership
is sufficient, but administrators can also hold a supported directory role.
Microsoft Graph is the authorization decision point; an HTTP 403 is reported
with the supported rights. The older owner check remains for the standalone
`aum group member` helper because that command intentionally manages only groups
the operator owns.

`Set-ClaudeDeveloper.ps1` now reads `standardGroup` and `premiumGroup` from the
installer's `onboarding/claude-gateway.json` record by default, keeping explicit
parameters for automation. If the record is absent, it uses the repository's
choice helper over discovered candidate groups instead of silently falling back
to fixed group names.

## Consequences

+ Administrators can find a developer by typing an email, UPN or display name in
  AUM and can add/remove access without visiting the portal.
+ The durable source of entitlement remains Entra group membership; the gateway
  still enforces APIM named values after publication.
+ Turnstile remains a web FinOps authority and observer, not a directory
  membership writer.
+ An issued Entra access token is not revoked by removing group membership; the
  gateway publication stops new requests whose token no longer maps to the
  refreshed allow lists, while existing access tokens live until expiry.
− AUM Direct developer writes require an Azure administrator context and Graph
  group-management rights. Scoped managers still need the AUM service or
  Turnstile for server-enforced budget scope, not directory membership.

## References

- Microsoft Graph `$search` on directory objects and advanced queries:
  <https://learn.microsoft.com/graph/search-query-parameter> and
  <https://learn.microsoft.com/graph/aad-advanced-queries>, retrieved
  2026-09-26.
- Microsoft Graph add group members permissions:
  <https://learn.microsoft.com/graph/api/group-post-members>, retrieved
  2026-09-26.
- Microsoft identity platform access token lifetime:
  <https://learn.microsoft.com/entra/identity-platform/access-tokens>, retrieved
  2026-09-26.
