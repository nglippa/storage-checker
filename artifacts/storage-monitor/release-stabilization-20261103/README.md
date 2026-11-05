# Release stabilization record

This directory records the November 3–4 release stabilization work. The reports distinguish implementation, automated checks, selected native observations, and acceptance that remains unverified. Historical source hashes and results are preserved rather than relabelled as current.

The Git record includes the reports and a curated set of small text/JSON receipts: the original and final source manifests, current and retained regression results and input proofs, lifecycle safety/transaction/deadline results, and the final native session summary and teardown. These files contain fixture results and source provenance, not production databases or credentials.

The full local `evidence/` directory is intentionally ignored. It also contains screenshots, raw accessibility/process observations, scratch programs, temporary profiles, copied sources, obsolete executables, and complete logs. Those materials remain on the development machine; links to them in historical reports are local evidence references and may not resolve in a fresh clone. Do not infer that an omitted screenshot or a source-rendered image establishes native acceptance.

Selected receipts are explicitly force-added from the ignored directory. New generated evidence must be reviewed before committing; never add the whole directory. Distribution images, mounted volumes, test databases, and generated application bundles do not belong in Git.

The source selected for this milestone is the existing `migration-readiness` branch. The source manifest and current regression record identify its content independently of later documentation commits. Package verification, when performed, must name the exact source commit, version/build, image filename and SHA-256; it must not imply notarization or public-release acceptance.

## Committed development package

[Package verification](PACKAGE-VERIFICATION-3670499.md) records the image built from committed source `3670499`. Its structural/native ARM checks passed; the extra Rosetta full suite failed twice and remains unresolved. Gatekeeper rejected the ad-hoc package. This later report commit does not change compiler inputs or designate an accepted release.

Latest corrected CLI self-test/package result: [diagnosis](SELF-TEST-DIAGNOSIS-20261105.md) and [package verification](PACKAGE-VERIFICATION-199ece9.md). Corrected packaged ARM238 and Rosetta238 pass; old367 failures remain historical records.
