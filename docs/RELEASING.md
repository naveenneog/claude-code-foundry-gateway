# Releasing

`CHANGELOG.md` is the release record. `tests/Test-ReleaseLog.ps1` enforces its
shape and runs in the normal suite, so a malformed changelog fails the build
rather than being noticed later by a reader.

## Prerequisites

Repository release/tag permission, an approved release branch/commit, Git and
the tools required by [Contributor checks](REFERENCE.md#contributor-checks).
Start from a clean checkout and fetch tags. Resolve release-blocking unknowns
in the engineering record; do not lower a gate to publish.
There is no Azure portal action that releases this repository.

## Cutting a release

1. Move the entries out of `## [Unreleased]` into a new
   `## [x.y.z] - YYYY-MM-DD` heading, newest first.
2. Add the compare link at the bottom of the file, and repoint `[Unreleased]` at
   the new tag.
3. Commit the reviewed release record on the approved branch with the required
   trailers from `AGENTS.md`. Use a new version, not the example's prior tag.
   Create its annotated tag **locally**:

   ```powershell
   $version = 'vX.Y.Z' # replace with the approved unused version
   git tag -a $version -m 'Release description'
   ```

4. Validate that exact committed tree and tag before pushing. The release gate
   includes the packet checks and additional release requirements:

   ```powershell
   ./tests/Test-ReleaseLog.ps1
   node .ironclad/gate.mjs --stage release
   git status --short
   ```

   A failure means do not publish. Fix the cause; never move an already-published
   tag. The release gate currently blocks while required unknowns are open.

5. After approval and a passing gate, push **only** the release branch and its
   specific tag through the repository's normal protected-branch workflow.
   Do not use `git push --tags`, which also publishes unrelated local tags.

   ```powershell
   git push origin '<approved-release-branch>'
   git push origin $version
   git ls-remote --tags origin "refs/tags/$version"
   ```

**GitHub web alternative:** repository > Releases > Draft a new release >
choose the already-validated tag, review notes and publish. It does not replace
the local gate or approve a deployment. The Azure portal only operates the
deployed gateway.

## Verify and troubleshoot

Check the remote tag and release resolve to the gated commit, all release-note
links open, and no generated config, credentials or unredacted images are in the
release. If `Test-ReleaseLog` reports an unreachable tag, inspect the branch/tag
relationship instead of rewriting published history. If Test-All finishes
unexpectedly early, read its full summary: all registered checks must run.

## What the test enforces

| Rule | Why |
|---|---|
| Every version carries an ISO date | A release with no date cannot be placed in time |
| Releases run newest first | A changelog is read top-down |
| No release repeats a section heading | Two `### Fixed` blocks in one release means a reader sees only the first. This happened, which is why the check exists |
| Sections use the Keep a Changelog set | `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`, plus `Known limitation` |
| No release is empty | |
| Every version has a compare link | |
| Every version has a git tag | A version nobody can check out is not a release |
| The newest release matches the newest tag reachable from `HEAD` | Catches a changelog edited without tagging, and a tag pushed without a changelog entry |

Each of these was negative-tested by breaking the changelog and confirming the
test fails.

## Version numbers

[Semantic Versioning](https://semver.org/spec/v2.0.0.html). For an accelerator,
the practical reading is:

- **Patch** — a fix that changes no interface and no behaviour anyone depends on.
- **Minor** — new capability, or a new named value with a safe default.
- **Major** — a change that breaks an existing deployment on redeploy, or removes
  a script or named value.

A behaviour change that makes something fail where it used to pass silently is
not a bug fix from the caller's point of view. Record it under `Changed` and say
so plainly — v1.5.0 has an example.

## Known limitations

`Known limitation` is not part of Keep a Changelog, and is used here for
behaviour that is documented, measured, and not yet fixed — the sort of thing a
reader needs before they trust a number. v1.5.0 records that the per-user token
budget does not count cache tokens, and by how much.

## Next steps

[Operations](OPERATIONS.md#4-back-up-change-restore-verify) covers customer
upgrade/restore preparation. A repository release does not deploy itself.
