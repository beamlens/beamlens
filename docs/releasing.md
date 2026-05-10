# Releasing

Beamlens releases are cut by pushing a `vX.Y.Z` tag. GitHub Actions runs the `Release` workflow, which gates the publish step on a manual approval inside the `hex` environment.

## TL;DR

1. Open a PR that bumps `@version` in `mix.exs` and renames the `## [Unreleased]` heading in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD` (and adds a fresh `## [Unreleased]` heading for next time).
2. Merge.
3. From `main`, tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. Watch the `Release` workflow. When it pauses on **Publish to Hex**, click **Review deployments** and approve.

## What the workflow guarantees

The release run has five sequential stages. Any failure aborts before anything reaches Hex.

1. **Verify** — tag is valid SemVer, points at a commit reachable from `main`, matches `@version` in `mix.exs`, has a matching `CHANGELOG.md` entry, and is not already on Hex.
2. **Checks** — re-runs the full CI matrix (tests, credo, sobelow, dialyzer, deps.audit, hex.audit, docs) on the tagged commit.
3. **Build** — runs `mix hex.build` and uploads the tarball as a workflow artifact, with the file list printed in the logs.
4. **Publish** — gated by the `hex` environment with required reviewers. A maintainer must approve. `HEX_API_KEY` is only available to this job.
5. **GitHub release** — extracts the matching CHANGELOG section as release notes and attaches the Hex tarball.

## One-time setup

### Generate a scoped Hex API key

A package-scoped, write-only key — it cannot publish other packages or modify account settings.

```sh
mix hex.user key generate \
  --key-name beamlens-github-actions \
  --permission api:write \
  --permission "package:beamlens"
```

### Configure the `hex` GitHub environment

Repository **Settings → Environments → New environment**, name `hex`. Then:

- **Required reviewers** — add the maintainers who can approve releases.
- **Deployment branches and tags** — choose "Selected branches and tags" and add a rule for tags matching `v*`.
- **Environment secrets** — add `HEX_API_KEY` with the value from above.

The secret is only readable from jobs that declare `environment: hex`, and those jobs only run after a reviewer clicks Approve.

## Pre-releases

Tags like `v0.5.0-rc.1` flow through the same pipeline. Hex auto-detects pre-release versions from the SemVer suffix, and the GitHub release is marked as a pre-release.

## Troubleshooting

- **Verify failed** — fix `mix.exs`, `CHANGELOG.md`, or the tag, then push a new tag.
- **Checks failed on the tag** — push a fix to `main`, delete the tag locally and on the remote (`git tag -d vX.Y.Z && git push origin :vX.Y.Z`), and re-tag the new HEAD.
- **Publish step crashed after Hex accepted the upload** — Hex versions are immutable. Re-run the `github-release` job manually, or run `gh release create vX.Y.Z --notes-file …` locally.
- **A bad version reached Hex** — `mix hex.retire beamlens X.Y.Z <reason>` and ship a fixed version.
