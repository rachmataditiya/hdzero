# HDZero Tools

Open-source tools for working with **[HDZero](https://www.hd-zero.com/) digital FPV** video — the
goggle recordings, the footage, the workflow around it. Built by [Arkana](https://arkana.co.id) for
our own FPV work and shared freely.

> Not affiliated with or endorsed by HDZero / Divimath. Trademarks belong to their owners.

## Tools

| Tool | Platform | What it does |
|---|---|---|
| **[HDZero Converter](HDZeroConverter/)** | macOS 13+ | Native SwiftUI app (bundled ffmpeg) that fixes HDZero recordings so Apple decoders play them correctly — converts full-range `yuvj420p` H.264 → limited-range BT.709 and re-wraps for broad compatibility (QuickTime/iPhone stop showing black / washed-out). Fully portable, no Homebrew needed on the target Mac. |

More tools will land here over time.

## HDZero Converter — download

Grab the signed + notarized `.dmg` from the [**Releases**](../../releases) page, drag the app to
`/Applications`, and double-click. No Terminal/`xattr` workaround needed (Apple-notarized).

To build it yourself, see [`HDZeroConverter/README.md`](HDZeroConverter/README.md).

## Releasing (maintainers)

Releases are built, **signed (Developer ID), notarized, and published** entirely by GitHub Actions
([`.github/workflows/release-converter.yml`](.github/workflows/release-converter.yml)) on a macOS
runner. Push a tag and the workflow attaches the notarized `.dmg` to a GitHub Release:

```bash
git tag converter-v1.4 && git push origin converter-v1.4
```

(Or run the workflow manually via **Actions → Build & Release → Run workflow** — that builds + signs +
notarizes and uploads the `.dmg` as a run artifact, without cutting a release. Good for testing.)

### One-time secrets

The notarization secrets (App Store Connect API key) are already set. The **Developer ID signing
certificate** must be added once (it needs your Keychain password, so it isn't scriptable from CI):

1. **Keychain Access** → *My Certificates* → right-click **“Developer ID Application: ARKANA SOLUSI
   DIGITAL, PT”** → **Export…** → save as `cert.p12`, set an export password.
2. Upload it as two repo secrets:
   ```bash
   base64 -i cert.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo rachmataditiya/hdzero
   gh secret set DEVELOPER_ID_P12_PASSWORD --repo rachmataditiya/hdzero   # paste the export password
   rm cert.p12
   ```

| Secret | Set by | Purpose |
|---|---|---|
| `ASC_API_KEY_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | ✅ already set | App Store Connect API key → `notarytool` |
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | **you, once (above)** | Developer ID cert → `codesign` |

## License

[MIT](LICENSE) © Arkana Solusi Digital, PT.

The macOS app **bundles** `ffmpeg`/`ffprobe` at build time (copied from your local Homebrew install,
not redistributed in this repo). ffmpeg is licensed under the LGPL/GPL by its own authors — see
[ffmpeg.org/legal.html](https://ffmpeg.org/legal.html). This repository's own source code is MIT.
