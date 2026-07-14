# Releasing pkg0

## Normal flow

```sh
git tag v0.1.0
git push --tags
```

`release-tag.yml` fires: builds `pkg0_0.1.0_all.deb`, smoke-tests it (install, postinst
seeding, exit codes, no-clobber reinstall), attests it with `actions/attest-build-provenance`,
**verifies the attestation is live** via `gh attestation verify`, and creates a **draft**
release. Review, then publish via the UI or:

```sh
gh release edit v0.1.0 --draft=false
```

Publishing the draft is what makes it visible to `releases/latest` — i.e. to pkg0 clients.

## Why the tag flow is canonical

pkg0 verifies its own updates against a derived identity regexp that pins tag refs
(`.../workflows/[^@]+@refs/tags/`, PLAN.md §5.2). A tag-push build's attestation certificate
names `_release.yml@refs/tags/vX.Y.Z` and passes out of the box.

`release-manual.yml` (workflow_dispatch with a version input) exists to exercise the pipeline;
its attestation names `@refs/heads/<branch>`, which pkg0 clients — including pkg0's own
selfupdate — flag as an identity mismatch (trust prompt when interactive, HOLD otherwise).
Don't ship real releases from it.

## Invariants the pipeline enforces

- The attestation must verify against the live API before any release is created — the deb
  seeds itself with `attest: "required"`, so an unattested release would brick selfupdate.
- The draft flow and the duplicate-build guard compose: publishing a manually-built draft
  creates the tag, which re-fires `release-tag.yml`, which sees the release exists and no-ops.
- Version comes from the tag (`v` stripped) and must be debian-shaped
  (`^[0-9][A-Za-z0-9.+~]*$`); it is stamped into the control file, `pkg0 version`, and the
  postinst-seeded state entry.
