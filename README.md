# pkg0

Sidecar package manager for `.deb`s published via GitHub Releases. Installs and
updates packages from a repo's releases, verified against their Sigstore
attestations, without touching apt's own inventory. One bash script, one JSON
state file.

## Install

```sh
curl -fsSL https://github.com/martona/pkg0/releases/latest/download/install.sh | bash
```

(Or grab `pkg0_latest_all.deb` from [releases](https://github.com/martona/pkg0/releases)
and `sudo apt-get install ./pkg0_latest_all.deb` — same thing.)

## Use

```sh
sudo pkg0 install sigstore/cosign     # the verifier; makes everything after this attested
sudo pkg0 install <owner>/<repo>      # any repo that releases .debs
pkg0 list
sudo pkg0 update
```

pkg0 registers itself with attestation required, so `pkg0 selfupdate` refuses
anything that doesn't verify. Design in [PLAN.md](PLAN.md), release mechanics in
[RELEASING.md](RELEASING.md).
