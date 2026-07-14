# Releasing pkg0

## Normal flow

```sh
git tag v0.1.0
git push --tags
```

`release-tag.yml` fires: builds the deb, smoke-tests it (install, postinst seeding, exit
codes, no-clobber reinstall, seeded-glob-matches-asset), attests it with
`actions/attest-build-provenance`, **verifies the attestation is live** via
`gh attestation verify`, and creates a **draft** release. Review, then publish via the UI or:

```sh
gh release edit v0.1.0 --draft=false
```

Publishing the draft is what makes it visible to `releases/latest` — i.e. to pkg0 clients.

## Release assets

Every release ships exactly two assets, both under **stable, version-less names** so
`releases/latest/download/<name>` URLs never change (the version lives in the deb's control
file and `pkg0 version`):

- `pkg0_latest_all.deb` — the package. The name deliberately keeps the `pkg0_*_all.deb`
  shape: that is `SELF_GLOB` in `packaging/postinst` — the glob every install since v0.0.2
  carries in its state — so existing installs selfupdate across the rename from the old
  versioned asset names. It must also match the filename in `scripts/install.sh`; the
  release smoke test asserts the glob↔asset match, so a rename can't silently brick
  selfupdate.
- `install.sh` — the bootstrap installer, so
  `curl -fsSL https://github.com/martona/pkg0/releases/latest/download/install.sh | bash`
  always installs the latest release.

Both assets are attested and both attestations are verified before the release is created.

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
