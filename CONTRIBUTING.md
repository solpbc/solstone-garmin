# Contributing to solstone-garmin

See [README.md](README.md) for current status and [AGENTS.md](AGENTS.md) for
Connect IQ platform invariants before sending substantial work.

## Development

```bash
git clone https://github.com/solpbc/solstone-garmin.git
cd solstone-garmin
make install
make ci
```

Requires Garmin Connect IQ SDK 9.3.0+ with device profiles for the targets in
`manifest.xml`. `make ci` runs `format-check` (SPDX headers, whitespace, and
strict 3-permission manifest allowlist), strict zero-warning release builds
across all 23 watches in `manifest.xml`, and the multi-watch simulator unit
test suite.

## Pull requests

- Keep changes scoped to one concern and use small, focused commits.
- Include simulator unit tests or hardware validation notes for behavior changes.
- Do **not** add analytics, tracking, crash-reporting SDKs, or manifest
  permissions outside `AudioInput`, `Background`, and `Communications`.
- Never commit Connect IQ developer signing keys (`.der`, `.pem`, `.key`) or
  any real audio, logs, or personal data.
- Call out wire-protocol (`SLV3`), storage-ring, background-service, or
  manifest device-list changes explicitly.

## License of contributions

By contributing to this repository, you agree that your contributions are
licensed under the GNU Affero General Public License v3.0 (AGPL-3.0-only), the
same license as the project.

You represent that you have the right to submit the contribution and that it
does not include proprietary, confidential, or third-party code that is
incompatible with the AGPL.

## Developer Certificate of Origin (DCO)

All contributions must be signed off using:

    git commit -s

This certifies compliance with the [Developer Certificate of Origin](https://developercertificate.org/).

## What this project does not accept

- Contributor License Agreements are not used here; the DCO sign-off above is sufficient.
- No GitHub Actions workflows. This repository does not accept `.github/workflows/` files.
