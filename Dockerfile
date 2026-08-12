# Build UI — clone from GitHub
FROM node:22-bookworm AS ui

ARG REACT_REPO_URL
ARG REACT_BRANCH=master

RUN apt-get update -qq && apt-get install -y -qq git

WORKDIR /react

RUN git clone --branch ${REACT_BRANCH} ${REACT_REPO_URL} .

RUN yarn install --ignore-engines && PORT=3000 yarn build

# Build backend
FROM ruby:3.4-bullseye

WORKDIR /app

EXPOSE 3000

# Install MongoDB Database Tools (provides mongodump for backups)
RUN apt-get update -qq && \
    apt-get install -y -qq wget gnupg && \
    wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | apt-key add - && \
    echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/debian bullseye/mongodb-org/7.0 main" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list && \
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

CMD ["sh", "-c", "bundle exec rake reservations:backfill_resource_manager_shops && exec bundle exec rails server -b 0.0.0.0"]
