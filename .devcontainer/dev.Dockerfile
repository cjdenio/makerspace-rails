FROM ruby:3.2-bullseye

WORKDIR /app

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - &&\
    apt-get install -y nodejs

EXPOSE 3000

COPY Gemfile Gemfile.lock ./

RUN bundle install

COPY . .

WORKDIR /app/ui

RUN npm install --global yarn && \
    yarn install

WORKDIR /app

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
