# ADR-0049: The projection renewal job deploys in three phases from one sync package

- **Status:** Proposed for P94
- **Date:** 2026-10-04
- **Packet:** P94 (P95 for the switch sections)
- **Refines:** [ADR-0045](0045-scheduled-projection-renewal.md)

## Context

ADR-0045 defines the scheduled renewal job and the evidence that admits a switch to the
projection. The merged P86 code cannot be deployed as written. Read on `main` `13611a1` on
2026-10-04 ([P94 status](../status/P94.md#p94-the-p86-renewal-job-deploys-and-renews-2026-10-04)):

- `sync/src/plan.mjs:12` imports `../../resolver/src/entitlement.mjs`, but the image context is
  `sync/` (`docs/SECURE-PROJECTION.md:91`) and the runner archive holds `sync/package.json` and
  `sync/src` (`scripts/Deploy-ClaudeProjection.ps1:204`). Outside the repository layout the job,
  the runner apply and compare, and admission stop with a missing module.
- `infra/projection-renewal.bicep` creates its registry and needs the digest of an image in it.
- `infra/projection-network.bicep` has no subnet for a Container Apps environment.
- The job has no `AZURE_CLIENT_ID` (U112), fixed tier group names and no business units.
- The environment's logs and the three alerts cannot work as written (U107-U110).
- A switch rerun of the deployer applies a new snapshot just before admission, so admission
  refuses with "older generation" every time (`scripts/Deploy-ClaudeProjection.ps1:196-206`).

## Options considered

1. **Build context = repository root with a `.dockerignore`.** One less copy step, but the
   upload follows whatever the ignore file misses, and the runner archive would still need its own
   file list. Rejected: two lists drift.
2. **One staging function that writes a package directory** (`sync/` plus
   `resolver/src/entitlement.mjs` at the path `plan.mjs` imports). The image builds from it and the
   runner archive is made from it. Chosen.
3. **Keep the registry inside the renewal template and deploy it twice** (first with a placeholder
   image). Rejected: a job deployed with a placeholder is a job that runs the wrong image until the
   second deployment, and admission's digest check would then depend on deployment timing.
4. **A registry template deployed first** (registry, job identity, AcrPull), then the image build,
   then the renewal template with the registry and identity as existing resources. Chosen.
5. **Business units passed to the job at deployment** as an ordered list. Smaller, but a unit added
   later by a script, AUM or Turnstile reaches the projection only after someone redeploys the job.
6. **Business units read by the job on every run** from `bu-registry` and `bu-parents`, ordered as
   `Sort-ClaudeBuByDepth` orders them. Chosen; the job gets a read-only named-value role (U117).

## Decision

1. `scripts/ClaudeProjectionPackage.ps1` writes the sync package: `sync/Dockerfile`,
   `sync/package.json`, `sync/package-lock.json`, `sync/src/` and `resolver/src/entitlement.mjs`,
   at their repository-relative paths. The runner archive is made from that directory and
   unpacks at `/work`; the image builds from it with `--file sync/Dockerfile`. The image installs
   with `npm ci --omit=dev` and keeps `ENTRYPOINT ["node", "/app/sync/src/apply-projection.mjs"]`;
   its command is `--graph`.
2. Deployment has three phases, run by `scripts/Deploy-ClaudeProjectionRenewal.ps1`:
   `infra/projection-registry.bicep` (registry, user-assigned identity, AcrPull), then
   `az acr build` from the package and a digest read-back (`sha256:` and 64 hex digits), then
   `infra/projection-renewal.bicep` with the registry and identity as existing resources. The
   identity exists before the job, so the tenant administrator can grant Graph access during the
   build.
3. `infra/projection-network.bicep` adds a `renewal` subnet, a `/27` delegated to
   `Microsoft.App/environments` at `cidrSubnet(vnetAddressPrefix, 27, 26)` (10.10.3.64/27 in the
   default plan, after the resolver's /26), and outputs `renewalSubnetId`. With an existing VNet the
   caller passes `renewalSubnetId`.
4. The job sets `AZURE_CLIENT_ID`, the tier group object ids and the gateway resource id. Each run
   reads `bu-registry` and `bu-parents` through ARM; a failed read writes nothing. Admission's
   job-definition check requires these settings.
5. The environment uses `azure-monitor` logs with a diagnostic setting to the gateway's workspace.
   The job prints one final JSON line per run with `event` set to `projection-renewal-succeeded` or
   `projection-renewal-failed` (with `stage`). Each alert filters on the job name, reads a fuzzy
   union with an empty table (U109), and returns rows only when unhealthy (U108).
6. (P95) A switch never repopulates. One function checks named-value drift, exports the gateway's
   decisions, compares through the runner, runs admission, takes a backup and writes
   `entitlement-source`; the deployer, the installer and the guided flow call it.
7. (P95) The renewal deploy script writes a receipt with no secrets (job id, image digest, action
   group, runner, Cosmos account, tenant, entry point, source commit). The guided flow reads it and
   confirms the job against ARM before admission.

## Consequences

+ The image, the runner and the guide use one package layout, and a test proves the import closure
  of that layout.
+ The deployment order is a script with tests instead of prose, and every phase can be rerun.
+ A unit change reaches the projection on the next run without redeploying the job.
− The job gains a dependency on ARM (`management.azure.com`) besides Graph and Cosmos, and a
  read-only role on the gateway's named values.
− A digest-pinned image means a code change needs a new build and a renewal redeploy; admission
  refuses evidence from the old digest until three runs of the new one exist.
− `sync/package-lock.json` must be refreshed when the sync dependencies change.

## How we'd know this was wrong

- The first live deployment fails in phase 3 with an image-pull or query-validation error that a
  rerun does not clear (U109, U113).
- The live job's console line is not visible in `ContainerAppConsoleLogs` with its job name, so the
  alerts never see an event (U107).
- Admission refuses after three successful live runs for a reason the offline simulation does not
  reproduce.
