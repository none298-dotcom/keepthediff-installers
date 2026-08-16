# Keep the Diff, installers and CI

**No application source lives here, and none ever should.** This repo holds the CI that builds and
verifies the Windows EXE, and the finished installers it publishes. Source lives in the private repo
`none298-dotcom/keepthediff` and is fetched into the runner's ephemeral workspace at build time.

## Why the CI is here and not next to the source

GitHub Actions is metered on private repos and this account's metered budget is unavailable. A
workflow in the private repo does not fail, it never starts: no runner is assigned, the job reports
zero steps, and the only explanation is an annotation reading

> The job was not started because recent account payments have failed or your spending limit needs
> to be increased.

That is easy to misread as a build failure, because the run shows up red. Actions is free on public
repos, so CI lives here, exactly as it does for MyLinedChart, Reveal the Dream and The Long View.

A **read-only deploy key**, scoped to `keepthediff` alone, is stored here as the repository secret
`SOURCE_DEPLOY_KEY`. It is narrower than an account-level token: it can read one repo and write
nothing.

## Status

**Wired, not yet green.** The workflow is complete and correct, but `keepthediff` has no
`android/desktop/` module yet, so there is nothing to build. The first meaningful run happens at
phase 06 of the build plan. Running it before then will fail at the Gradle step, which is expected
and not a defect in this repo.

## Building and verifying the Windows EXE

`source_ref` takes a branch or, better, an exact commit sha, so the run says precisely what was
verified. A build takes about six minutes.

    gh workflow run windows-exe-verify.yml --repo none298-dotcom/keepthediff-installers \
      -f source_ref=$(git rev-parse HEAD)

Watch it, and read the result:

    gh run list  --repo none298-dotcom/keepthediff-installers --limit 3
    gh run watch --repo none298-dotcom/keepthediff-installers <run-id>

## Prove the checks can fail before trusting a green

A gate nobody has seen go red is not a gate. `break_mode` injects one known defect per run:

    -f break_mode=remove_arp_entry   # deletes the HKLM uninstall key; must fail Store 10.2.7
    -f break_mode=dead_button        # stubs the welcome button; must fail the click check

**Two other modes exist and no longer bite. Do not use them to prove an assertion works.**
`per_user_install` flipped the build to per-user scope on the theory that a certifier installs
elevated. Two real Microsoft rejections disproved that, so per-user is now the correct shipping
scope and injecting it correctly passes. `deny_users_read` only fed a cross-account standard-user
check that has since been retired. Both are kept so old dispatch links do not error.

Run both live modes against the first EXE this project produces, and confirm each goes red for its
own reason, before treating any green as meaningful.

## Publishing

    -f wait_seconds=40   # how long the installed app runs before it is judged
    -f publish=true      # upload the signed installer to its permanent URL

`publish` is off by default and is deliberately a separate decision from "did it pass". The path is
keyed by commit sha and cannot be overwritten, so a sha published today can never be republished.
Verify as often as you like; publish only when the build is the one you intend to ship.

The published URL must be direct, because Partner Center rejects a redirecting link. That is why
GitHub release links cannot be used for the Store package, and why the workflow fetches the URL
back, compares SHA256 against the bytes it verified, and re-checks the Authenticode signature
survived the round trip.

## Secrets this repo needs

| Secret | Purpose | State |
|---|---|---|
| `SOURCE_DEPLOY_KEY` | read-only checkout of `keepthediff` | set |
| `AZURE_CLIENT_ID` | Azure Trusted Signing, OIDC | **needed** |
| `AZURE_TENANT_ID` | Azure Trusted Signing, OIDC | **needed** |
| `AZURE_SUBSCRIPTION_ID` | Azure Trusted Signing, OIDC | **needed** |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 upload | **needed** |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 upload | **needed** |

Without the Azure secrets the build still runs and produces an **unsigned** installer, which is
deliberate so a fork works. Without the R2 secrets, `publish=true` fails.

The R2 bucket `keepthediff-downloads` and the custom domain `dl.keepthediff.com` must exist before
the first publish. The Cloudflare account id is already in the workflow and is not a secret; it
appears in every published URL anyway.

## When to run it

Any time anything under `android/desktop/` or the shared Kotlin modules changes. jpackage does not
cross-compile, so nothing on the Mac can produce or test the EXE. The DMG run proves the shared
jpackage config and module list are valid; everything genuinely Windows-only, meaning Authenticode,
silent install, install scope, the Start Menu shortcut, the ARP entry and SmartScreen, is only ever
exercised here.
