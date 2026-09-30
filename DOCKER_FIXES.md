# Redmine Docker Setup — End-to-End Fix Log

How this repo (Redmine 7.0.1-devel, Rails 8.1, `ruby >= 3.3`) was containerized,
every build error hit, and what fixed it. Files involved: `Dockerfile`,
`docker-entrypoint.sh`, `docker-compose.yaml`, `.env.example`, `.dockerignore`.

---

## Step 0 — Inspect the app (what a Dockerfile needs)

| # | What to look at | File | Finding |
|---|---|---|---|
| 1 | Runtime | `Gemfile:3,5`, `doc/INSTALL:10` | `ruby >= 3.3, < 4.1`, `rails 8.1.4`, Propshaft + Importmap, no Sprockets/ActiveStorage |
| 2 | Server/port/health | `config.ru`, `doc/INSTALL:99` | Puma via `rails server`, port `3000`, health `GET /up` (`config/routes.rb`) |
| 3 | DB adapters | `Gemfile:58-97`, `config/database.yml.example` | Gems install **based on `database.yml` adapter** (`mysql2`/`trilogy`/`pg`/`sqlite3`/`tiny_tds`); default MySQL `utf8mb4` + `transaction_isolation: READ-COMMITTED` |
| 4 | App config | `config/configuration.yml.example` | SMTP, `attachments_storage_path`, `scm_*_command`, `database_cipher_key`, `secret_token` |
| 5 | Secret | `lib/tasks/initializers.rake:20`, `config/initializers/30-redmine.rb:16` | `rake generate_secret_token` writes `config/initializers/secret_token.rb`; must be stable across restarts/replicas |
| 6 | Writable dirs | `doc/INSTALL:90-97` | `files/`, `log/`, `tmp/`, `public/assets` (+ `public/plugin_assets/`, `plugins/`, `themes/`) |
| 7 | Logs | `config/environments/production.rb:61` | `RAILS_LOG_TO_STDOUT=1` for containers |
| 8 | Boot order | `doc/INSTALL:63-88` | `bundle install` → `assets:precompile` → `db:migrate` → `rails server` |
| 9 | OS deps | `doc/INSTALL:18-26`, `.github/actions/setup-redmine/action.yml:19` | `git/svn/hg/cvs`, `imagemagick + ghostscript`, `pandoc`, DB client libs, build tools |

---

## Step 1 — `Dockerfile` (base image + layers)

Base `ruby:3.4-slim-bookworm`. Layer order for caching:

1. `apt-get`: `build-essential`, `default-libmysqlclient-dev`, `libpq-dev`,
   `libsqlite3-dev`, `libxml2-dev/libxslt1-dev`, `git subversion mercurial cvs`,
   `imagemagick ghostscript gsfonts`, `pandoc`, `curl tzdata`, clients.
2. `COPY Gemfile` → seed temp `database.yml` listing all 3 adapters
   (`mysql2`/`postgresql`/`sqlite3`) so **one image supports all DBs**
   → `bundle install --without development test` → delete seed.
3. `COPY . ./`, create `redmine` user (uid 1000), `mkdir files log tmp
   public/assets public/plugin_assets db`, `chown`.
4. `assets:precompile` with dummy secret + dummy DB (see Fix 4, Fix 5).
5. `EXPOSE 3000`, `HEALTHCHECK curl -f http://localhost:3000/up`,
   `ENTRYPOINT docker-entrypoint.sh`, `CMD rails server -b 0.0.0.0 -p 3000`.

---

## Step 2 — `docker-entrypoint.sh` (why it exists)

The image is frozen; DB host/password/secret are only known at **start**.
The entrypoint runs on every container start:

1. **Secret** — writes `config/initializers/secret_token.rb` from
   `$REDMINE_SECRET_KEY_BASE`, else runs `rake generate_secret_token`.
2. **DB config** — if `config/database.yml` is missing/empty:
   use `$DATABASE_URL` (Rails 8 native) if set, else build the file from
   `REDMINE_DB_ADAPTER/HOST/PORT/NAME/USER/PASS`.
3. **Wait** — TCP-probe the DB host/port (up to ~120 s).
4. **Migrate** — `rails db:migrate` (creates tables + `admin/admin` on fresh DB).
5. `exec "$@"` (the Puma server).

`.env` only *carries* values; this script *acts* on them.

---

## Step 3 — `docker-compose.yaml` + `.env`

`docker-compose.yaml`: `db` (`mysql:8.4`,
`--transaction-isolation=READ-COMMITTED --character-set-server=utf8mb4`,
healthchecked) + `redmine` (build, port `3000:3000`, named volumes
`mysql-data`, `redmine-files/log/tmp/plugins/themes`).

`.env` (copied from `.env.example`): `DATABASE_URL`
(e.g. `mysql2://techhaus:techhaus%40123@db:3306/techhausdb?encoding=utf8mb4`),
`REDMINE_DB_*` fallback, `REDMINE_SECRET_KEY_BASE` (`openssl rand -hex 40`),
`MYSQL_*` for the container.

URL anatomy: `adapter://user:pass@host:port/dbname?options`.
Special chars in passwords must be percent-encoded (`@` → `%40`);
the plain `@` before the host is the separator and must stay.

---

## Step 4 — Fixes applied (chronological)

### Fix 1 — `VOLUME` used relative paths
- **Error:** `VOLUME ["./files", ...]` invalid.
- **Fix:** absolute paths —
  `VOLUME ["/usr/src/redmine/files", "/usr/src/redmine/log",
  "/usr/src/redmine/tmp", "/usr/src/redmine/plugins", "/usr/src/redmine/themes"]`.

### Fix 2 — compose failed without `.env`
- **Error:** `env file .env not found`.
- **Fix:** `env_file: [{path: .env, required: false}]`; verified
  `docker compose config` passes with and without `.env`.

### Fix 3 — compose `environment:` overrode `.env`
- **Error:** `.env` said `techhaus/...`, running config showed `redmine/redmine`.
- **Cause:** compose `environment:` always wins over `env_file:`.
- **Fix:** interpolate every value —
  `DATABASE_URL: ${DATABASE_URL:-mysql2://redmine:redmine@db:3306/redmine?encoding=utf8mb4}`,
  `MYSQL_*: ${...}`, `REDMINE_DB_*: ${...}`, healthcheck password too.
  `.env` is now the single source of truth.

### Fix 4 — `assets:precompile` → `AdapterNotSpecified`
- **Error:** `ActiveRecord::AdapterNotSpecified: The 'production' database is
  not configured` (`Tasks: TOP => assets:precompile => environment`).
- **Cause:** empty `config/database.yml` (from `touch`) has no `production` key;
  precompile boots Rails → `10-patches.rb` loads ActiveRecord → abort.
- **Fix:** write dummy sqlite config for the build only, delete after:
  `printf 'production:\n  adapter: sqlite3\n  database: ":memory:"\n' >
  config/database.yml && ... assets:precompile ... && rm -f config/database.yml`.

### Fix 5 — `configuration.yml is not a valid Redmine configuration file`
- **Error:** precompile aborted at `config/configuration.yml`.
- **Cause:** `lib/redmine/configuration.rb:100-119` — empty file YAML-parses to
  `false` (not a `Hash`) → `abort`; a **missing** file is skipped (line 52).
- **Fix:** never `touch` it; `rm -f` only if exists-but-empty (a real user
  config is preserved).

### Fix 6 — `.env` secrets baked into image- **Error:** none yet — latent leak: `COPY . ./` copies `.env` (real passwords)
  into a layer.
- **Fix:** new `.dockerignore` excluding `.env`, `.git`, `log/`, `tmp/`,
  `files/`, `public/assets`, tests. No image was pushed before the fix.

### Fix 7 — runtime `Gem::LoadError: mysql2 is not part of the bundle`
- **Error:** `db:migrate` died with `LoadError: ... mysql2 is not part of the
  bundle`, plus a twice-printed `Please configure your config/database.yml first`.
- **Cause:** `Gemfile:58-97` declares DB gems from the adapter in
  `config/database.yml` **at Bundler evaluation time**. The entrypoint skipped
  writing that file when `DATABASE_URL` was set, so `bundle exec` saw zero
  adapters and excluded `mysql2` — even though the gem is installed in the image.
- **Fix:** entrypoint now always writes a minimal `database.yml` (adapter parsed
  from the `DATABASE_URL` scheme) before any `bundle exec`. Rails still takes
  host/user/pass/db from `DATABASE_URL`, which overrides the file.

### Fix 8 — `Could not find a server gem` (container restart loop)
- **Error:** migrations all green, then `Could not find a server gem. Maybe you
  need to add one ... gem "puma"`, exit 0, restart loop, browser refused to connect.
- **Cause:** upstream declares `puma` only in `group :test` (`Gemfile:116`),
  but the image sets `BUNDLE_WITHOUT="development:test"` — production had no
  server for `rails server` to use.
- **Fix:** `echo 'gem "puma"' > Gemfile.local` before `bundle install`.
  `Gemfile.local` is auto-loaded by upstream (`Gemfile:129-132`), so no
  upstream file is modified.

---

## Step 5 — Run it

```bash
cp .env.example .env        # edit values; generate secret:
openssl rand -hex 40        # → REDMINE_SECRET_KEY_BASE
docker compose up --build -d
# → http://localhost:3000  (admin/admin)
# → Administration → Load default data (roles, trackers, statuses, workflow)
```

Useful checks: `docker compose config` (resolved values),
`docker compose logs -f redmine`, `curl -f http://localhost:3000/up`.

---

## Appendix — unrelated workstation fix (bat warning)

`[bat warning]: Unknown theme 'Catppuccin-macchiato'` came from
`~/.zshrc:113` (`BAT_THEME`), not the repo. Installed the official
`Catppuccin-macchiato.tmTheme` + `bat cache --build`; user preferred the old
fallback look, so set `BAT_THEME="Monokai Extended"` (bat's default) instead.
No repo files involved.
