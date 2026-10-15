# Build UI — clone from GitHub
FROM node:22-bookworm AS ui

ARG REACT_REPO_URL
ARG REACT_BRANCH=master

RUN apt-get update -qq && apt-get install -y -qq git

WORKDIR /react

RUN git clone --branch ${REACT_BRANCH} ${REACT_REPO_URL} .

# Async bundles must have deployment-specific URLs.  The Rails entrypoint is
# fingerprinted by Sprockets, but webpack loads its lazy route bundles directly
# from /assets; stable chunk names can therefore mix modules from two releases
# in a browser or CDN cache.
RUN sed -i \
      -e 's/makerspace-react\.\[name\]\.js/makerspace-react.[name].[contenthash].js/g' \
      -e 's/makerspace-react\.\[name\]\.css/makerspace-react.[name].[contenthash].css/g' \
      prod.config.js && \
    grep -Fq 'chunkFilename: "makerspace-react.[name].[contenthash].js"' prod.config.js && \
    grep -Fq 'chunkFilename: `makerspace-react.[name].[contenthash].css`' prod.config.js

RUN yarn install --ignore-engines && PORT=3000 yarn build

# Build backend
FROM ruby:3.4-bookworm

WORKDIR /app

EXPOSE 3000

# Install MongoDB Database Tools (provides mongodump for backups)
RUN apt-get update -qq && \
    apt-get install -y -qq ca-certificates curl gnupg && \
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
      gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg && \
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" > /etc/apt/sources.list.d/mongodb-org-7.0.list && \
    apt-get update -qq && \
    apt-get install -y -qq mongodb-database-tools && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./

RUN bundle install

ARG ENVIRONMENT="production"
ARG APP_DOMAIN="members.manchestermakerspace.org"
ENV RAILS_ENV=$ENVIRONMENT
ENV RACK_ENV=$ENVIRONMENT
ENV RAILS_SERVE_STATIC_FILES=true

COPY . .

RUN mkdir -p /app/app/assets/builds
COPY --from=ui /react/dist/ /app/app/assets/builds/
RUN rm -f /app/app/assets/builds/manifest.js
COPY --from=ui /react/dist/manifest.js /app/app/assets/config/manifest.js

RUN SECRET_KEY_BASE_DUMMY=1 APP_DOMAIN=${APP_DOMAIN} bundle exec rails assets:precompile
RUN cp -r /app/app/assets/builds/. /app/public/assets/ && rm -f /app/public/assets/manifest.js

# Keep database maintenance out of web dyno startup. Heroku runs it as the
# release process declared in heroku.yml, so a transient database failure does
# not put every web dyno into a crash loop.
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
