# ADR-0006: Workstation interactive gateway sign-in

- Status: Accepted
- Packet: P17 follow-up
- Decision authority: user's 2026-09-07 request to configure the Desktop interactive sign-in fields in both workstation scripts

## Decision

Extend the workstation setup slice of P17 to load an optional interactive gateway
authentication configuration from the onboarding JSON. Preserve helper-script mode
when absent. Retrieve tenant-specific OIDC metadata where required, validate inputs
before workstation mutations, and write only verified Desktop configuration keys.
Do not infer an OAuth client ID from a gateway URL or use Azure CLI's client ID.
Do not create applications, grant permissions, change APIM token audiences, or
modify the user's live workstation as part of tests.

## Verification

Use isolated configuration fixtures for both Bash and PowerShell. Test malformed
authentication settings and profile output. Real Desktop sign-in still requires
an approved public-client registration, matching redirect settings and consent;
offline tests cannot establish end-to-end authentication.