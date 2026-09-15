# Releasing

`CHANGELOG.md` is the release record. `tests/Test-ReleaseLog.ps1` enforces its
shape and runs in the normal suite, so a malformed changelog fails the build
rather than being noticed later by a reader.

## Cutting a release

1. Move the entries out of `## [Unreleased]` into a new
   `## [x.y.z] - YYYY-MM-DD` heading, newest first.
2. Add the compare link at the bottom of the file, and repoint `[Unreleased]` at
   the new tag.
3. Tag the commit:

   ```bash
   git tag -a v1.5.0 -m "Short description of the release"
   git push --tags
   ```

4. Run the suite. The release test checks the changelog and the tags agree.

   ```powershell
   ./tests/Test-ReleaseLog.ps1
   ```

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
