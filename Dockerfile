FROM ruby:3.4-slim-bookworm AS base

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1

WORKDIR /usr/src/redmine

# 1. System deps.
# build-essential + *-dev: native gems (mysql2, pg, sqlite3, nokogiri, commonmarker)
# git/subversion/mercurial/cvs/bzr: repository browsing (configuration.yml scm_*_command, must be in PATH)
# imagemagick/ghostscript: attachment thumbnails + Gantt PNG export
# pandoc: Office/RTF preview (doc/INSTALL recommends >= 3.8.3)
# curl/default-mysql-client/postgresql-client: healthcheck + wait-for-db in entrypoint
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      default-libmysqlclient-dev default-mysql-client \
      libpq-dev postgresql-client \
      libsqlite3-dev sqlite3 \
      libxml2-dev libxslt1-dev pkg-config \
      git subversion mercurial cvs \
      imagemagick ghostscript gsfonts \
      pandoc \
      curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# 2. Gems first for layer caching.
# Gemfile installs DB gems based on config/database.yml adapter (Gemfile:58-97),
# so seed a temp file listing all 3 adapters -> mysql2 + pg + sqlite3 all installed.
# No Gemfile.lock is shipped upstream.
# Puma is only in the :test group upstream (Gemfile:116) but BUNDLE_WITHOUT
# excludes dev+test, leaving production with no server gem (`rails server`
# aborts "Could not find a server gem"). Gemfile.local is auto-loaded
# (Gemfile:129-132), so declare puma there without touching upstream files.
COPY Gemfile ./
RUN echo 'gem "puma"' > Gemfile.local \
    && printf 'production:\n  adapter: mysql2\ndevelopment:\n  adapter: postgresql\ntest:\n  adapter: sqlite3\n' > config_database_seed.yml \
    && mkdir -p config && cp config_database_seed.yml config/database.yml \
    && bundle install \
    && rm config/database.yml config_database_seed.yml

# 3. App source.
COPY . ./

# 4. Non-root + writable dirs (doc/INSTALL step 8: files, log, tmp, public/assets).
# db/ included so sqlite3 file can live there. public/plugin_assets for plugins.
RUN useradd -m -u 1000 redmine \
    && mkdir -p files log tmp public/assets public/plugin_assets db \
    && chown -R redmine:redmine /usr/src/redmine

# 5. Assets. Auto-recompile on boot is on (production.rb: config.assets.redmine_detect_update),
# but precompiling at build keeps first boot fast. SECRET_KEY_BASE needed because
# Rails eager-loads config at precompile time.
# A dummy sqlite database.yml is required because a missing/empty one aborts
# the environment load (ActiveRecord::AdapterNotSpecified). An empty
# configuration.yml is likewise fatal (must be a Hash or absent,
# lib/redmine/configuration.rb:100-119), so an empty one is removed first.
# The dummy database.yml is deleted right after so the entrypoint generates
# the real config from DATABASE_URL / REDMINE_DB_* at runtime.
RUN if [ -e config/configuration.yml ] && [ ! -s config/configuration.yml ]; then rm -f config/configuration.yml; fi \
    && printf 'production:\n  adapter: sqlite3\n  database: ":memory:"\n' > config/database.yml \
    && SECRET_KEY_BASE=dummy-for-precompile bundle exec rails assets:precompile \
    && rm -f config/database.yml

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

VOLUME ["/usr/src/redmine/files", "/usr/src/redmine/log", "/usr/src/redmine/tmp", "/usr/src/redmine/plugins", "/usr/src/redmine/themes"]

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3000/up || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
