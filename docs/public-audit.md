# Public release input review

Review for the 0.2.0 early alpha, performed on 2026-09-06.

## Scope and results

- Scanned all 53 commits reachable from the repository refs before the release-preparation commit,
  plus current tracked and proposed source inputs, using verified Gitleaks 8.30.1 with full redaction.
  Neither scan reported credential findings. The release script can repeat the source/history check.
- Scanned the 55 pre-existing GitHub issues and their comments with the same redacted scanner.
  No credential findings or user-attachment image URLs were found. The release tracker contains
  implementation plans and aggregate acceptance evidence only.
- Reviewed tracked file types: source, documentation, example configuration, licenses, and app artwork.
  No model weights, camera/microphone recordings, local login stores, provisioning profiles, private
  keys, or built application archives are tracked. Icon PNG metadata contains image timestamps,
  not capture location or account information.
- Removed unused deployment-specific preset code and generalized the legacy compatible-service example.
  Moved machine-specific password/signing instructions to ignored `AGENTS.local.md`, preserving
  local operational guidance without including it in the release source. Public documentation no
  longer presents retired UI or local-service setup as the current product.
- Git history retains ordinary author metadata, prior development context, former public service
  URLs, and historical validation evidence. No history rewrite was performed; these are not signing
  keys or account credentials. An automated scanner cannot prove the absence of every possible secret.
- Verified public, unauthenticated access to pinned model provenance. Added the Hy-MT2 and RF-DETR
  Apache 2.0 texts, original YOLO public-domain notice, and consolidated third-party attribution.
  The app includes its project LICENSE/NOTICE and runtime notices. Weights remain optional downloads.

## Release artifacts

Only the final notarized installer, SHA256SUMS, release notes, and required notices are intended
for GitHub assets. Archive/export directories, provisioning/signing configuration, temporary logs,
local settings, credentials, and model downloads stay out of the published assets. Public certificates
and distribution provisioning metadata embedded by Apple's export process are normal distribution
material; they do not include private signing keys.

Exact source commit, final artifact inspection, notarization results, acceptance limits, and public
URLs belong in the release tracker. This review does not claim complete penetration testing or
production-quality platform coverage for an early alpha.
