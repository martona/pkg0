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

## Attestation identity

pkg0 verifies updates against a derived identity regexp that accepts **any workflow in the
source repo, on any ref** (`.../workflows/[^@]+@`, PLAN.md §5.2) — the repo, not the ref, is
the security boundary. A tag-push build's certificate names `_release.yml@refs/tags/vX.Y.Z`; a
`release-manual.yml` (workflow_dispatch) build names `@refs/heads/<branch>`. Both verify;
non-tag refs get a one-line note in pkg0's output rather than a prompt. Prefer the tag flow
because it's the tidier provenance story, not because the manual one breaks anything.

## Invariants the pipeline enforces

- The attestation must verify against the live API before any release is created — the deb
  seeds itself with `attest: "required"`, so an unattested release would brick selfupdate.
- The draft flow and the duplicate-build guard compose: publishing a manually-built draft
  creates the tag, which re-fires `release-tag.yml`, which sees the release exists and no-ops.
- Version comes from the tag (`v` stripped) and must be debian-shaped
  (`^[0-9][A-Za-z0-9.+~]*$`); it is stamped into the control file, `pkg0 version`, and the
  postinst-seeded state entry.
