# GitHub Actions for self-hosted deployments

The default pipeline validates changes. Docker Hub application and prepared computer images
are published only through manual runs on `main`. Optional upstream services remain in the
repository to keep upstream merges small; see [workflow controls](workflow-controls.zh-CN.md)
for repository-level disabling and manual publication.

## Default pipeline

- `ci.yml`: lint, translations, typechecks, unit tests, PostgreSQL journeys, production builds,
  relevant native tests and browser tests. Keep these checks enabled.
- `playwright.yml`: called by CI; keeps screenshots and diagnostics as GitHub artifacts without
  requiring a public screenshot website.
- `computer-replay.yml`: runs for changes affecting computer execution.
- `publish-server-image.yml`: validates Dockerfiles on relevant pull requests. Its GHCR
  publication is disabled by default; this does not disable pull-request image validation.
- `publish-dockerhub.yml`: publishes the application only on manual runs on main,
  using the existing Docker Hub credentials. It publishes full commit tags and `latest` after
  image checks. See [Docker Hub configuration](self-host-model-account.md#docker-hub-amd64-publication).
- `publish-execution.yml`: validates and publishes the prepared computer image only on manual
  runs on main. Computer execution tests remain in `computer-replay.yml` and core CI.

## Optional repository variables

Set these under repository **Settings → Secrets and variables → Actions → Variables**.
An absent variable is disabled. Enable a feature by setting its value to exactly `true` only
after configuring the corresponding credentials. The switches do not contain credentials.

| Variable                        | Enables                                                                                                | Additional configuration                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `GHCR_PUBLISH_ENABLED`          | Multi-architecture app, updater and computer publication to GHCR on main, release tags and manual runs | Package publishing permissions; Depot configuration only if using Depot             |
| `DESKTOP_PUBLISH_ENABLED`       | Tagged/manual desktop releases                                                                         | Platform signing and notarization configuration as required by the release workflow |
| `MOBILE_PUBLISH_ENABLED`        | Manual iOS/Android releases and automatic compatible mobile OTA updates                                | Expo project/token and the applicable store credentials                             |
| `SCREENSHOT_PUBLISH_ENABLED`    | Public web and Android screenshot galleries                                                            | S3 access keys, bucket, endpoint/region and public report URL                       |
| `NIGHTLY_VERIFICATION_ENABLED`  | Scheduled extended browser verification                                                                | No hosted report service required; artifacts are retained                           |
| `AUTOMATED_MAINTENANCE_ENABLED` | Scheduled dependency and model-catalog updates                                                         | Credentials required by the respective update workflow                              |
| `REVIEW_BOT_ENABLED`            | Comment-driven handoff between installed review bots                                                   | Install/configure the desired review applications separately                        |

`PRODUCTION_DEPLOY_ENABLED` remains an independent, existing opt-in. The upstream deployment
uses GHCR images, so configure GHCR publication as well before enabling it. Docker Hub
publication alone does not deploy a server or publish client applications.

## Manual tools

- macOS desktop screenshots, Android screenshots and topology verification remain available
  through **Run workflow**. macOS screenshots no longer run on pushes or pull requests.
- Nightly verification and maintenance workflows can also be started manually without enabling
  their schedule. Manual maintenance still needs its own credentials.
- Desktop and mobile release switches apply to manual releases too, to prevent accidental
  publication before signing and store settings have been configured.
- Screenshot capture and GitHub artifact upload work without S3; only public gallery upload
  requires `SCREENSHOT_PUBLISH_ENABLED`.

Disabled jobs may appear as **Skipped** in Actions. Historical failures remain in the run
history; disabling an optional publisher does not erase them. A failed core CI job should be
investigated, not disabled to make the history look green.
