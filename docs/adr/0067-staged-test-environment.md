# ADR-0067: Staged test environment with a smoke test

**Status:** Proposed
**Date:** 2026-10-21
**Packet:** P121

## Context

A disposable environment is needed to check a gateway with the Cosmos
projection end to end: a Claude request, a tier change and a business-unit
change applied by the scheduled sync job without an operator, and the P120
chargeback membership. `Install-ClaudeGateway.ps1` and
`scripts/Test-ClaudeLiveProjection.ps1` (P98) deploy through the installer,
with Foundry in the same tenant and the 30-minute minimum interval of
ADR-0058.

The test tenant (Contoso, `d2885cb9-...`) holds the Entra groups and the
gateway. Claude runs in a Foundry account in another tenant (FDPO,
`16b3c013-...`), reached with client credentials (P117,
`infra/foundry-auth-client-credentials.xml`). Bicep cannot create Entra
applications, groups or Microsoft Graph app-role assignments without the
preview Microsoft Graph extension.

## Decision

1. `infra/test-environment/resources.bicep` deploys the resources, composing
   the existing modules: `main.bicep` (Basic v2, client-credentials Foundry),
   `projection.bicep`, `projection-network.bicep` (managed VNet, no runner)
   and `projection-registry.bicep`.
2. `infra/test-environment/configuration.bicep` configures them: the
   resolver (`resolver.bicep`, public inbound with Easy Auth, storage behind
   private endpoints), the gateway named values that point at it and name the
   business units, and the sync job (`projection-renewal.bicep`) on a test
   cron. The resolver is here, not in stage 1, because its only allowed caller
   is the gateway identity's application id, which Bicep cannot read; the
   script reads it from Microsoft Graph between the stages.
3. `main.bicep` gains `@secure() param foundryClientSecret`. When it is set in
   client-credentials mode, the deployment writes the secret named value the
   policy references. Empty keeps today's behaviour, where the installer
   writes it before the deployment.
4. `scripts/Deploy-ClaudeTestEnvironment.ps1` runs the stages in order:
   `Identity` (groups and the resolver app, through Graph),
   `Resources`, `Publish` (resolver code and sync image), `Configure`,
   `Grant` (Graph `GroupMember.Read.All` for the job identity), `Populate`
   (one job run), `Smoke`, and `Teardown`. Each stage reads the outputs of
   the previous ones from the resource group's deployments, so a stage can be
   rerun alone.
5. The test cron runs every `-SyncMinutes` (5 to 30, default 5). It is passed
   to `projection-renewal.bicep` directly; the production interval table and
   its 30-minute minimum are unchanged.
6. The Foundry secret is read from a named value on an existing gateway
   (`-FoundrySecretSourceApim`), or added to the Foundry app for 7 days
   through Microsoft Graph (`-CreateFoundrySecret`), into memory and passed
   to the deployment as a secure parameter. It is never written to disk or
   printed.
8. Resource-group tags hold the run's state. Every tag value is checked for
   form before use, and Teardown deletes a group, app or Foundry key only when
   its name is the one this run gave it.
7. The smoke stage, as the signed-in user: a request with a standard model
   returns 200 and a premium-only model returns 403; the user is moved to the
   premium group and to another business unit; after the next scheduled run
   the premium model returns 200, and the newest membership lines in the
   workspace place the user in the new unit.

## Consequences

- Production deployment paths do not change; the only product change is the
  optional secure parameter in `main.bicep`.
- The test APIM holds a second copy of the FDPO credential until teardown.
- The Graph grant needs a Privileged Role Administrator or Global
  Administrator in the test tenant (U17, U202). Without it the grant stage
  stops with the command an administrator runs, and the scheduled runs fail
  at the Graph stage.
- The nested deployments are named `test-*`, not `projection-renewal-<prefix>`,
  so `Set-ClaudeProjectionSyncSchedule.ps1` and the installer do not manage
  this job; only the `Configure` stage does.
- A job manually started and a scheduled run can overlap at 5 minutes; the
  apply lock makes the later one wait or stop (U165).
