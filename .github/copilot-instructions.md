# Repository guidance

## Commands and runtime

This is an interpreted Bash/Apache CGI application with a plain HTML/CSS/JavaScript
dashboard. Deployment targets Debian/Ubuntu and Raspberry Pi OS, with systemd,
cron, OpenSSL, curl, jq, and GNU/Linux utilities. Run shell commands below in a
Linux Bash environment from the repository root.

Run an individual regression script directly:

```bash
bash tests/test-branding-cgi.sh
bash tests/test-calendar-days-setting.sh
bash tests/test-standby-timer.sh
bash tests/test-upload-cgi-validation.sh
node tests/test-escape-attr.js
node tests/test-monitor-groups.js
node tests/test-streaming-renderer.js
node tests/test-standby-renderer.js
python3 tests/test-streaming-adapter.py
```

The two calendar integration tests additionally need Python 3 and a
church-calendar checkout containing `image_schedule.py`. They default to a
sibling checkout; override it explicitly when needed:

```bash
CALENDAR_SRC=/path/to/church-calendar bash tests/test-image-schedule-helpers.sh
CALENDAR_SRC=/path/to/church-calendar bash tests/test-external-images-folder.sh
```

Run all existing tests, stopping on the first failure:

```bash
export CALENDAR_SRC=/path/to/church-calendar
for test in tests/test-*.sh; do bash "$test" || exit 1; done
for test in tests/test-*.js; do node "$test" || exit 1; done
python3 tests/test-streaming-adapter.py
```

Use a development environment rather than a deployed monitoring host:
`test-upload-cgi-validation.sh` expects the installed upload helper to be absent.
Shell tests use temporary directories, environment overrides, and PATH stubs;
follow those patterns to avoid touching real services or configuration.
For shell syntax checking, use `bash -n <changed-script>`; this also applies to
`.cgi` files and extensionless `client/church-monitoring-*` Bash helpers.

Installation is a privileged deployment operation, not a local build:

```bash
sudo ./server/install.sh
sudo ./client/install.sh
sudo ./server/install.sh --update
sudo ./client/install.sh --update --config-choice E
```

Client update choices are `E` (keep enrolled host configuration), `I` (import
the installer's configuration), and `N` (prompt for new configuration).
`client/install.sh --renew` re-enrolls; it is not the routine update path.

## Architecture

- The browser loads `server/index.html`, which contains the dashboard's styles,
  rendering, polling, and action handlers inline. Login and help are separate
  static HTML pages. Browser requests go to server `/cgi-bin/` endpoints, not
  directly to agents.
- Server CGI scripts read `/etc/church-monitoring/server-config.json`.
  `fetch-status.cgi` queries configured clients in parallel and caches the
  aggregate for 30 seconds; `device-status.cgi` handles agentless devices.
  Action endpoints proxy to matching client CGI scripts over mutual TLS.
- Clients expose Apache CGI on port 8033. `client/collect.sh`, installed as
  `/usr/local/bin/church-monitoring-collect`, runs every five minutes via cron,
  uses a collection lock, and atomically replaces
  `/var/cache/church-monitoring/status.json`. `status.cgi` serves that cache.
  `refresh=1` starts collection in the background and returns existing data;
  fresh data arrives on a subsequent request. Expensive maintenance metrics
  have separate caches governed by `slow_metric_ttl_seconds`. CEC is on-demand.
- Opt-in streaming diagnostics use a separate 30-second systemd timer and
  sanitized snapshot, cheaply merged by `status.cgi` without rerunning host
  collection. The fixed loopback provider is read-only; source timestamps,
  unknown health, and the 90-second snapshot freshness limit must survive
  caching. Streaming shows top-level health and a service link, not telemetry.
- CGI scripts run as `www-data`; privileged or kiosk-user operations cross
  into narrowly scoped installed helpers through sudoers rules.
  `server/install.sh` and `client/install.sh` deploy scripts, permissions,
  Apache configuration, and supporting files. Server and client CGI directories
  are separate, allowing both roles on one host.
- Calendar scheduling belongs to the external church-calendar application.
  Monitoring helpers invoke its `image_schedule.py` and `image_optimizer.py`.
  Discover its code via `calendar_app_path`, then the calendar service's
  `WorkingDirectory`, then the parent of `calendar_images_path`; images may
  live on a share separate from code. Kiosk controls integrate with videokiosk2
  service users, hooks, and runtime state.
- Backups use the client configuration's `apps[]` as the recovery manifest:
  repositories, installers, dependencies, configuration paths, services, and
  ordering. Restore processes that manifest, with monitoring restored last
  and re-enrolled.

## Cross-cutting conventions

- A feature can span dashboard JavaScript, a server proxy (often
  `host-action.cgi`), a client CGI, and an extensionless helper. Keep parameter
  validation and response fields consistent across those boundaries. Deploy
  new files and sudoers permissions through the installers; the server has
  separate fresh-install and update copy lists, while the client maintains
  an explicit required-CGI list. Check `configure-apparmor.sh` when changing
  executable paths or file access needed by CGI scripts.
- Generic monitor groups support one child level; existing flat monitors and
  VLC/browser expected-down handling stay compatible. Group severity affects
  host health even when collapsed. Provider children do not authorize restarts.
- Saved TV standby defaults belong in the TV + HDMI dropdown, not on the main
  card. The kiosk reads `/etc/videokiosk2/standby-after-minutes` only for new
  countdowns; explicit current application uses the runtime adjustment and
  shared lock. Require `settings_version: 1`; never fabricate capability.
- Protected server CGI scripts source
  `/usr/local/lib/church-monitoring/auth-lib.sh` and call `require_role` before
  emitting response headers. Role order is `user < contributor < admin`:
  reads require user, actions contributor, account management and backup
  downloads admin. UI role checks do not replace endpoint enforcement.
  Keep the shared auth library outside the web-exposed CGI directory.
- Client certificate identity is the configured client `name`, not its `host`
  address. Preserve curl's `--connect-to` pattern: request
  `https://${NAME}:${PORT}/...` while connecting to the configured host.
  Agents require the server certificate CN `church-monitoring-server`.
- CGI JSON responses have a `Content-Type` header and a blank line before the
  body. Many operational failures are JSON `error`/`result` fields with a zero
  shell exit status; inspect the relevant endpoint contract rather than
  assuming process exit or HTTP success means the operation succeeded.
  Use jq arguments to construct JSON containing dynamic text.
- Dashboard strings need context-specific escaping: `escapeHtml` for markup,
  `escapeAttr` for JavaScript string arguments inside inline HTML handlers,
  and `encodeURIComponent` for URL parameters. The Node regression test
  extracts the actual `escapeAttr` function from `server/index.html`.
- Calendar file moves and schedule changes share `.image-schedule.lock` with
  church-calendar and propagate `IMAGE_SCHEDULE_LOCK_HELD=1`. Preserve rollback
  behavior and collision-safe archive/evergreen naming. Upload, restore, and
  activation require an explicit persistent/scheduled choice; scheduled images
  remain visible through their last day. Older calendars retain an uploaded
  image but report the missing schedule support; restore/activation refuse it.
- Edit tracked `client/config.example.json` and `server/config.example.json`
  for configuration examples. Real `config.json`/per-host snapshots, accounts,
  sessions, certificates, enrollment tokens, and the ntfy topic are private
  runtime data and gitignored. Never copy their contents into source or docs.
- Per README, update `VERSION` with user-visible changes using SemVer.
  `.github/workflows/release.yml` packages source and adds `RELEASE.json`;
  a tag's base version must match `VERSION`, including prerelease tags.
  Installers record per-role release metadata in
  `/etc/church-monitoring/installed-version.json`.
- Preserve LF endings for shell scripts and CGI files (`.gitattributes`).
