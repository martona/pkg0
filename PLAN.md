# pkg0 — implementation spec (v3)

A sidecar package manager for `.deb`s (later `.rpm`s) published via **GitHub Releases**. Invoked
separately from apt; never touches apt's own inventory. Goal: stay ahead of glacial distro repos
with a handful of commands and one state file.

v2: URLs are gone. The interface is **repospec + optional glob**; an interactive resolver handles
every case where the glob doesn't identify exactly one asset.

v3: leaner and more precise. `gh` is dropped entirely (curl-only, public repos). `rollback`,
`resolve`, and `--force` are dropped. Arch-aware default-glob ladder, digest-based download
skipping, attestation before parsing, atomic state writes, postinst lock handshake.

```
pkg0 install <owner>/<repo>[@<tag>] [<glob>] [--no-attest]
pkg0 update  [<name>...] [--non-interactive]
pkg0 remove  <name> [--purge-cache]
pkg0 selfupdate                    # sugar for: pkg0 update pkg0
pkg0 list
```

```
pkg0 install martona/clipp                            # one .deb in latest → just works
pkg0 install martona/clipp 'clipp-linux-*-amd64.deb'
pkg0 install martona/clipp@v1.2.3                     # pinned; update skips it
```

---

## 1. Interface & resolution model

### 1.1 Repospec

`owner/repo` targets `releases/latest` (which excludes drafts and prereleases by definition).
`owner/repo@tag` targets `releases/tags/<tag>` and records the package as **pinned** — `update`
skips it. **Unpin** by reinstalling without the tag: `pkg0 install owner/repo`. **Downgrade** by
remove + pinned install: `pkg0 remove foo && pkg0 install owner/foo@v1.2.2` — there is no
rollback command.

**Public repos only.** Discovery, download, and attestation fetch all run unauthenticated.
Private repos would need a token in every path; out of scope until a need shows up.

GitHub Releases is the only source in v1. Vendor-hosted stable URLs (rclone-style) are dropped;
if ever needed, they return as a second source type behind the install shim (§6), not as a
complication of the primary interface.

### 1.2 Glob semantics

The glob is matched (`fnmatch`) against `assets[].name` of the resolved release, considering only
names ending in `.deb`.

**Default-glob ladder (no glob given):** try `*.deb`; if that doesn't match exactly one asset,
try `*<arch>.deb` with `<arch>` from `dpkg --print-architecture` (e.g. `*amd64.deb`); if still
not exactly one, resolver. This covers the two common release shapes — a single deb, and one deb
per architecture — without ever asking. Whichever rung won is what gets stored.

| Glob | Matches | Action |
|---|---|---|
| none: `*.deb` | exactly 1 | install; store `*.deb` |
| none: `*<arch>.deb` | exactly 1 | install; store `*<arch>.deb` |
| none: neither rung unique | — | resolver (§1.3) |
| given/stored | exactly 1 | proceed |
| given/stored | 0 or 2+ | resolver (§1.3) — globs and upstream filenames both drift; this is the designed recovery path, not an error |

The stored glob is always a ladder rung or a user-confirmed generalization — never silently
derived from a filename. `*.deb` on the smooth path is honest ("there was only one"), can't be
wrong, and the moment upstream adds a second deb it stops matching uniquely, which fires the
resolver: exactly the intended behavior.

**Zero-match fork (before invoking the resolver):**
- 0 matches but other `.deb`s present → glob drift → resolver.
- 0 `.deb`s in the release at all, and the tag is **new** → asset-upload race: print "release
  $TAG found, no debs yet; retrying next run", no state change, not an error.
- 0 `.deb`s at all, tag **not** new → upstream stopped shipping debs → HOLD (§1.4) with that message.

### 1.3 Interactive resolver

Runs when a glob (given, stored, or the default ladder) matches ≠ 1 asset. Only when interactive
(`[ -t 0 ]` and not `--non-interactive`).

1. List the release's `.deb` assets, numbered, with sizes.
2. User picks one.
3. **Prompt for a glob to store, prefilled with a generalization of the chosen name** — not the
   filename itself (it embeds the version and is guaranteed to break next release). Generalize by
   replacing the release's `tag_name`, and the tag with any leading `v` stripped, with `*`:
   `clipp-linux-v1.2.3-amd64.deb` + tag `v1.2.3` → `clipp-linux-*-amd64.deb`.
4. **Validate the accepted glob against the live asset list: must match exactly 1.** Loop until
   it does or the user aborts. This kills the "saved an already-broken glob" case for free.
5. Save glob to state; proceed with the chosen asset.

There is no standalone `resolve` command: interactive runs always resolve fully, so the fix for a
held package is simply to re-run the install interactively.

### 1.4 Non-interactive behavior

- `install` with an unresolvable glob → **fail** (exit 2, usage-class error).
- `update` with an unresolvable glob → **HOLD** that package: stays at current version, state
  gains `needs_resolve: true`, summary prints
  `clipp  HELD — glob matched 3 assets; re-run 'pkg0 install martona/clipp' interactively`,
  and the run's exit code signals holds distinctly from hard failures (§8). Never abort the whole
  update run, never silently skip.

### 1.5 Shell-expansion guard

An unquoted glob argument gets expanded by the caller's shell iff a matching file exists in cwd —
works in testing, breaks in the one directory containing debs. Guard: if the glob argument
contains **no** glob metacharacters (`*?[`) **and** names an existing local file, bail:
"argument looks like a shell-expanded local file — quote your glob."

## 2. State

Single JSON file: `/var/lib/pkg0/state.json`, root-owned, **mode 0644** — only root writes, but
unprivileged `list` must read it. `flock` for the whole run (see §7.5 for the postinst
handshake). **All writes are atomic**: render to a temp file in the same directory, `mv` over.
Deb cache: `/var/cache/pkg0/<pkg_name>/`, last **3** debs kept, pruned after successful install.

**Entry identity is (repo, glob)**: the repo narrows to one release stream, the glob picks one
asset within it, so the pair names one package. The state is a JSON **array** (composite keys
make lousy object keys). `pkg_name` — always from `dpkg-deb`, never from a filename — is kept
for display, dpkg operations, and the cache path.

Reconciliation rules:
- `install` where the resolved deb's `pkg_name` matches an existing entry for the same repo →
  same package: update that entry in place (glob, pin state, ...), don't create a duplicate.
  This is also the unpin path.
- `update` where the downloaded deb's `pkg_name` **differs** from the entry's stored `pkg_name`
  (and no interactive pick confirmed it) → the glob drifted onto a *different* package in a
  multi-deb repo → treat as unresolvable: resolver when interactive, HOLD otherwise. Never
  silently retarget.
- CLI `<name>` arguments match `pkg_name`, `owner/repo`, or bare repo name; ambiguous → list the
  candidates and fail.

```json
[
  {
    "repo":          "martona/clipp",
    "glob":          "clipp-linux-*-amd64.deb",
    "pkg_name":      "clipp",
    "installed_ver": "1.2.3",
    "tag":           "v1.2.3",
    "asset_name":    "clipp-linux-v1.2.3-amd64.deb",
    "asset_digest":  "sha256:abc123...",
    "etag":          "\"abc123...\"",
    "attest":        "required",
    "signer":        null,
    "pinned":        false,
    "needs_resolve": false,
    "installed_at":  "2026-07-13T14:00:00Z"
  }
]
```

`installed_ver` comes from `dpkg-deb` at install time. `asset_digest` is the release API's
per-asset digest (§3). `attest` is `required | none | opted-out` (§5.3). `signer` is set when a
non-default workflow identity was explicitly trusted (§5.2); otherwise the expected identity is
derived from `repo`.

## 3. Discovery (curl only)

No `gh` anywhere — one fewer dependency, one glob engine, one code path. Everything is
unauthenticated `curl` against the public API.

```sh
curl -fsS -D "$HDRS" -o "$BODY" -H "If-None-Match: $CACHED_ETAG" \
  "https://api.github.com/repos/$REPO/releases/latest"
# 304 → up to date, done for this package. 200 → parse JSON (jq), capture new ETag.
```

Rate limit: 60 req/hr/IP, **but conditional requests answered 304 don't count against the
limit** — routine polling of dozens of packages is fine; only cold installs consume quota.
(Assumption under watch: GitHub has fiddled with rate-limit accounting before.)
On 403 rate-limit: report, skip the package, no state change — and distinguish it from 404 (§10).

**Digest short-circuit.** The ETag covers the whole API response — editing release *notes* alone
invalidates it. On a 200, before downloading anything: if `tag_name` and the matched asset's
`digest` both equal the stored values, there is nothing to do — refresh the etag and move on.

**Download by name, never by glob twice.** Once `match_asset()` has picked exactly one asset,
fetch that asset's `browser_download_url` directly. The glob is evaluated by exactly one engine
(ours); nothing re-matches it at download time.

## 4. Update decision

New tag alone isn't authoritative — compare the **actually installed** version so out-of-band
updates (vendor selfupdate, manual dpkg) don't confuse pkg0. Never string-compare tags
(`v` prefixes, rc suffixes, epochs). Runs on a downloaded, digest-checked, attestation-passed
deb (§6 order).

```sh
CAND=$(dpkg-deb -f "$DEB" Version)
CURR=$(dpkg-query -W -f '${Version}' "$PKG_NAME" 2>/dev/null || true)
[ -n "$CURR" ] && dpkg --compare-versions "$CAND" le "$CURR" && skip  # refresh tag/etag/digest, move on
```

## 5. Attestation

**cosign is the one and only verifier.** `gh attestation verify` is auth-gated (dedicated exit
code 4: "authentication required"; open upstream issues asking for unauthenticated verification
of public repos) and the token/keyring precedence dance isn't worth maintaining a second path
for. In v3 gh plays no role in pkg0 at all — not even discovery.

### 5.1 Verifier availability

1. `cosign` on PATH (distro package: Ubuntu 26.04 ships 2.6.x; **24.04 does not**), **subject to
   a minimum-version check** (floor: 2.2.0; check `cosign version` output). Flag drift is real
   and confirmed: **cosign 3.x makes the sigstore bundle format the default and deprecates
   `--new-bundle-format`** (passing it still works but warns); 2.x requires the flag. pkg0
   detects the major version and passes the flag only on 2.x. Too old → treat as absent (and
   say why).
2. Else a pkg0-managed cosign (§5.4).
3. Else: verifier absent → right-hand column of the policy matrix (§5.3).

### 5.2 Mechanics

The attestation *data* is public. For public repos the bundle endpoint works with unauthenticated
curl, and the Sigstore trusted root comes from Sigstore's own TUF infra (fetched and cached under
`~/.sigstore` on first run) — zero GitHub credentials, ever.

```sh
DIGEST=$(sha256sum "$DEB" | cut -d' ' -f1)
curl -fsS "https://api.github.com/repos/$REPO/attestations/sha256:$DIGEST"
# 404 / empty attestations[] → none published
```

**Bundles are no longer inline.** The API now returns, per attestation, a `bundle_url`
(short-lived signed blob URL) and `bundle: null`; the blob it serves is **raw-snappy-compressed**
sigstore-bundle JSON (undocumented — confirmed against cli/cli, and it's what gh itself does:
`snappy.Decode` unconditionally). pkg0 handles both shapes: inline bundle if present, else fetch
`bundle_url` and decompress. Raw snappy is ~30 lines of perl, and `perl-base` is Essential on
every deb system — zero added dependencies.

```sh
# for each bundle (repos may publish several: provenance, SBOM, ...):
cosign verify-blob-attestation "$DEB" \
  --bundle bundle.json \
  --type slsaprovenance1 \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --certificate-identity-regexp "$IDENTITY_RE"
# + --new-bundle-format on cosign 2.x only (§5.1)
# pass = at least one SLSA-provenance bundle verifies
```

**Verdict classes** (what verify can conclude, and what each means):
- **VERIFIED** — some bundle verifies under the expected identity.
- **MISMATCH** — a bundle verifies under a permissive identity but not the expected one:
  genuine signature, different workflow → trust prompt below.
- **UNSUPPORTED** — no bundle chains to the public Sigstore root **and** a cert names a
  non-`sigstore.dev` issuer. Confirmed in the wild: GitHub signs some artifacts (cli/cli's debs
  among them) with its *internal* Sigstore instance (issuer "GitHub, Inc.", no Rekor entry,
  RFC3161 timestamp only) — unverifiable with the public trust root, **not malicious**. Warn and
  proceed; under `attest: required` → HOLD, never a scream.
- **INVALID** — a public-instance bundle that still fails → forgery/corruption → abort, scream,
  delete the download.

**Identity regexp — derived, never user-written.** The cert's SAN names the *workflow identity*
(`https://github.com/o/r/.github/workflows/x.yml@refs/tags/v1.2.3`), and every GitHub Actions
user gets an equally genuine cert for *their* workflow — all security lives in the identity
match. pkg0 templates it mechanically from the repospec, anchored and escaped: **any workflow in
the target repo, any ref**:

```
^https://github\.com/<repo_regex_escaped>/\.github/workflows/[^@]+@
```

Pitfalls this template exists to prevent: unanchored substring matches (`martona/clipp` matches
a cert from `notmartona/clipp` or `martona/clipp-utils` — genuine cert, attacker's repo),
unescaped dots, missing scheme anchor.

*Why no tag-ref pin (changed from the original design, which appended `refs/tags/`):* the repo
boundary is the actual security line — the attestation is fetched from the target repo's own
store, and the anchor rejects genuine certs from other repos. Pinning `@refs/tags/` on top of
that only adds value when tag-protection rules make tags harder to push than branches (an
attacker who can run a workflow in your repo can nearly always push a tag), and it
false-positives on real repos immediately: cli/cli releases from `trunk`, and any
workflow_dispatch-built release carries a branch ref. Same-repo non-tag refs are auto-trusted;
the ref is noted in output (`note: built from refs/heads/master rather than a tag`) so nothing
is silent.

**Identity mismatch — trust prompt, in plain language.** With same-repo-any-ref auto-trusted,
the derived regexp fails on *genuine* attestations in one remaining known-legitimate shape:
releases built by a **reusable workflow**, where the SAN names the shared workflow's repo, not
upstream's. When the signature is valid but the
identity doesn't match, pkg0 must not just say "verification failed" — it says exactly what
happened, so the trust decision the user is making is unmistakable:

```
attestation found and cryptographically valid, but it was produced by:
    https://github.com/other-org/release-tooling/.github/workflows/release.yml@refs/heads/main
pkg0 expected a workflow in martona/clipp.
This is normal for projects that release via a shared (reusable) workflow.
Trust this workflow identity for future updates of clipp? [y/N]
```

Accept → persist as `signer` in state (the workflow path, i.e. the identity up to the `@` —
the ref after it changes per release); subsequent verifies match `^<signer>@`.
Non-interactive → HOLD with the same message.

### 5.3 Policy matrix

`attest` is set at install time and only relaxed by explicit user action. **Ratchet up, never
silently down** — a previously-verified package whose attestation disappears or fails is the
actual attack signal.

| Situation | cosign available | cosign absent |
|---|---|---|
| First install, attestation **verifies** | Install; print **"✓ attestation verified ($REPO)"** loud & proud; `attest: required` | Existence check via curl. Exists → **warn** "attestation published but no verifier — installing anyway; run 'pkg0 install sigstore/cosign'"; `attest: none` |
| First install, none published | Install normally; `attest: none` | Same |
| First install, verification **FAILS** | **Abort. Scream. Delete the download.** | n/a |
| `--no-attest` | Skip verify; `attest: opted-out`; say so in output | Same |
| Update, `attest: required` | Verify or **abort** — package stays at current version | **HOLD**: "attestation-required but no verifier — install cosign or override" |
| Update, `attest: none/opted-out` | Opportunistically verify; if it now passes, brag and ratchet to `required` | Install; warn if existence check finds one |

### 5.4 Bootstrapping cosign (the 24.04 problem)

cosign can't be a hard `Depends:` (absent from 24.04's archive), but it *is* published as a
`.deb` on GitHub Releases — i.e. it's a pkg0 package like any other, and the default-glob ladder
resolves it without a glob (one deb per arch → `*<arch>.deb` rung):

```sh
pkg0 install sigstore/cosign
```

- pkg0 offers this automatically the first time verification is wanted and no verifier is found.
- **The first cosign install is TOFU by necessity** (nothing exists yet to verify it) — flag it
  loudly as such. What matters is the ratchet from that point on: every *subsequent* cosign
  update is verified by the incumbent cosign, so an attacker must compromise the very first
  download, on that box, or nothing.
- After bootstrap, retro-verify the cached cosign and pkg0 debs with the fresh binary. Honest
  footnote (per design discussion): a compromised binary can lie about its own verification, so
  this catches corruption and non-targeted tampering, not a competent attacker — do it, brag
  accordingly, don't oversell it.
- If a distro cosign exists or appears later, prefer it (PATH order) and let the standard
  "apt overtakes us" non-goal handle the rest; the pkg0-managed one simply stops winning.

## 6. Install/upgrade execution

```sh
apt-get install -y "./$DEB"       # NOT dpkg -i: resolves deps, marks manual
```

1. Download to tmpdir (`*.part`, rename when complete); check sha256 against the release asset's
   `digest` — transport integrity; catches truncation and HTML error pages before anything
   parses the file.
2. **Attestation policy (§5.3) next — before any parsing.** Verification needs only the file
   digest, so nothing has to read inside the archive until it has passed policy. Move into cache
   only after this gate.
3. `dpkg-deb -f` → `pkg_name`, version. **Validate `pkg_name` against dpkg's package-name
   grammar (`^[a-z0-9][a-z0-9+.-]+$`)** before using it as a path component or apt argument, and
   check it against the stored `pkg_name` (§2 reconciliation).
4. Version compare (§4): candidate `le` current → skip; refresh tag/etag/digest, move on.
5. If apt/dpkg is locked, wait: `-o DPkg::Lock::Timeout=60`.
6. Success → update state, clear `needs_resolve`, prune cache to last 3.
7. apt failure → state untouched; keep the deb in cache for inspection.

Root required for mutating verbs; `list` and discovery dry-runs run unprivileged. Keep
install/query behind a two-function shim (`pkg_install_file`, `pkg_query_version`) so an rpm
backend is a small add later.

## 7. Remove

```sh
pkg0 remove clipp    →   apt-get remove -y "$PKG_NAME"; delete state entry
                          cache kept unless --purge-cache
```

Downgrades are remove + pinned install (§1.1); no rollback machinery, no "previous deb"
bookkeeping. The cache still keeps the last 3 debs, so a manual
`apt-get install --allow-downgrades ./cached.deb` remains possible in a pinch — pkg0 just
doesn't wrap it.

## 7.5 Selfupdate

pkg0 is itself distributed as a `.deb` from GitHub Releases — i.e. it is exactly the kind of
package it manages. So self-management is not a special subsystem; it's **one more state entry**.

- **Seeding:** the deb's `postinst` registers pkg0 into its own state on first install (repo and
  glob baked in at build time), with `attest: "required"` — non-negotiable for the tool that does
  the verifying. If the state file doesn't exist yet, postinst creates it with just this entry.
  **Corollary: release CI must publish attestations from the very first shipped version, or
  every selfupdate aborts.** (Implemented: `.github/workflows/` — tag push → build → smoke test
  → attest → `gh attestation verify` gate → draft release; see RELEASING.md.)
- **`pkg0 selfupdate`** is literal sugar for `pkg0 update pkg0`. A plain `pkg0 update` includes
  pkg0 like any other package; no special ordering. New code takes effect on the next invocation.
- **Why in-flight replacement is safe:** dpkg installs files by unpacking to `*.dpkg-new` and
  **renaming over** the target. The running script's open fd keeps the old inode, so bash's
  incremental script reading never sees a half-swapped file. No copy-self-to-tmpfs-and-exec
  gymnastics needed — this is a freebie of being dpkg-managed. (Belt-and-suspenders anyway:
  structure the script as functions with a single `main "$@"` call on the last line.)
- **Lock handshake:** pkg0 holds the state flock for the whole run, and `apt-get` runs pkg0's
  own postinst mid-update — which must write state. pkg0 exports **`PKG0_LOCK_HELD=1`** around
  its `apt-get` invocations; postinst takes the flock only when the flag is absent (manual
  `apt-get install ./pkg0_*.deb`), and writes lock-free when it's set — the lock is already held
  by an ancestor that is blocked waiting on apt, so the write is race-free.
- **Guard:** `pkg0 remove pkg0` prompts for confirmation ("removing pkg0 with pkg0; state and
  cache will be orphaned") rather than refusing — it works fine mechanically (same inode
  argument), it's just rarely what anyone means.
- **Bootstrap:** trust-on-first-use — the first install isn't verified by pkg0 (nothing exists
  yet to verify it), and postinst takes it from there. Two equivalent paths: the shipped
  installer (`curl -fsSL .../releases/latest/download/install.sh | bash`), or manually
  downloading the release deb and `apt-get install ./pkg0_latest_all.deb`. The release
  publishes the deb under the stable version-less asset name `pkg0_latest_all.deb` — chosen
  to keep matching postinst's baked-in `pkg0_*_all.deb` glob (already seeded into every
  existing install's state), so selfupdate survived the switch from versioned asset names;
  release CI asserts glob and asset name agree.

## 8. Output & exit codes

- Per-package one-liners on `update`:
  `clipp  1.2.3 → 1.3.0  ✓ attested` · `rclone  1.71.0 (current)` ·
  `foo  HELD — glob matched 3 assets; re-run 'pkg0 install martona/foo' interactively`
- Attestation success is always printed, never silent — that's the point.
- Exit codes: `0` all good, `1` hard failure (failed verify, apt error), `2` usage,
  `3` completed but ≥1 package HELD (so cron wrappers can distinguish "act needed" from "broken").

## 9. Non-goals & deferred

- **apt interplay** (pinning, sources.list.d detection): the mission is staying *ahead* of the
  repo; if apt overtakes a package, apt wins, nobody is hurt.
- **SHA256SUMS verification**: attestation or nothing. (The release API's per-asset digest is
  used for download *integrity* — that's transport, not authenticity.)
- **gh integration**: dropped from v1 entirely; revisit only if unauthenticated rate limits bite
  in practice.
- **`--force`**: removed until an actual need arises.
- **`rollback`**: removed; downgrade = remove + pinned install (§1.1).
- **Private repos**: would need tokens in discovery, download, and attestation paths.
- **rpm backend, non-GitHub sources, daemon/timer**: `pkg0 update` is cheap; wire it to
  cron/systemd-timer externally.

## 10. Edge-case checklist

- [ ] New tag, no debs yet (upload race) → retry-next-run, no state change, exit 0
- [ ] Glob matches ≠ 1 → resolver interactively; HOLD (update) / fail (install) otherwise
- [ ] Stored glob broken by upstream rename → same resolver path; `needs_resolve` until an
      interactive re-install fixes it
- [ ] Default ladder: `*.deb` → `*<arch>.deb` → resolver; store whichever rung won
- [ ] Resolver-accepted glob validated live: must match exactly 1 before saving
- [ ] Glob arg has no metacharacters and names an existing local file → bail: quote your glob
- [ ] Release notes edited → ETag changes, asset digest doesn't → refresh etag, skip download
- [ ] Asset replaced in-place under same tag → digest changes → download; version compare `le` → skip; acceptable
- [ ] Downloaded deb's pkg_name ≠ stored pkg_name → glob drifted onto a different package →
      resolver / HOLD; never silently retarget
- [ ] 403 rate limit → report, skip, no state change
- [ ] Download isn't a deb (HTML error page) → digest mismatch at §6 step 1 → clean abort;
      dpkg-deb never sees it
- [ ] apt repo overtakes our version → version compare handles it; refresh state; no fight
- [ ] Interrupted download → `*.part` + rename
- [ ] Concurrent pkg0 runs → `flock` on state file for the whole run
- [ ] State writes atomic → temp file + rename, same directory
- [ ] pkg0 upgrading itself mid-run → safe via dpkg's rename-over-inode; new code next run
- [ ] postinst during selfupdate → `PKG0_LOCK_HELD=1` handshake; seed only if entry absent
- [ ] pkg0's own attestation fails on selfupdate → abort loudly; this is the highest-value alarm
      the tool can raise
- [ ] No verifier on box → matrix right column; offer `pkg0 install sigstore/cosign` once, not naggingly
- [ ] cosign on PATH too old (flag drift) → treat as absent for verification; say why
- [ ] cosign bootstrap is TOFU → say so loudly at install; ratchet applies from then on
- [ ] Same-repo attestation from a non-tag ref → auto-trusted; ref noted in output, never silent
- [ ] Identity mismatch (cross-repo / reusable workflow) → plain-language trust prompt, persist
      `signer`; non-interactive → HOLD
- [ ] Attestation endpoint 404 vs rate-limit 403 → distinguish: "none published" vs "couldn't check"
- [ ] `bundle_url` blob is raw-snappy → embedded perl decoder; inline bundle still handled if present
- [ ] Attestation signed by a non-public Sigstore instance (GitHub internal) → UNSUPPORTED:
      warn & proceed / HOLD under required — never treated as forgery
- [ ] Wrong-arch deb chosen anyway (resolver override) → apt rejects; state untouched, deb kept

---

### Skeleton (bash, ~350 lines)

```
main()            dispatch, flock, root check for mutating verbs, tty detection
parse_spec()      "owner/repo[@tag]" [glob] → {repo, tag?, glob?}; shell-expansion guard
discover()        curl w/ ETag → {tag, assets[]} | UP_TO_DATE | RETRY_LATER
match_asset()     glob ladder vs assets → asset | AMBIGUOUS(list) | NONE
resolve()         interactive picker + glob generalization + live validation (§1.3)
fetch()           curl asset URL (by name, never re-globbed) → tmpfile; digest check
attest()          curl bundle + cosign verify-blob-attestation, policy §5.3 → OK | WARN | HOLD | ABORT
find_verifier()   cosign on PATH (min version) | pkg0-managed | ABSENT; offer bootstrap once
install_deb()     apt-get install ./ + state update + cache prune
cmd_install/update/remove/list()
cmd_selfupdate()  → cmd_update pkg0
```
