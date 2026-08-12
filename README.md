# Makerspace Rails
Application to handle member management at the Manchester Makerspace.  Connects with
key fob system for facility entry and Braintree API for payment processing.

# Development

1. Configure `.env` file
See `sample.env` for required environment variables per feature.
Contact @lynch16 for variables for the Manchester Makerspace.
2. Spin up rails server
```
$ rails s
```

### Wiki URLs

Set `WIKI_URL` to the public wiki base URL, without a required trailing slash:

```env
WIKI_URL=https://wiki.manchestermakerspace.org
```

The React footer uses this runtime value. Shops and tools may store an explicit
Wiki URL. When blank, shop links default to
`<WIKI_URL>/workshops/<slugified-shop-name>` and tool links default to
`<WIKI_URL>/workshops/<slugified-shop-name>#<slugified-tool-name>`. Slugs are
lowercase and punctuation/whitespace are converted to hyphens.

Authenticated members can browse these links at `/workshops`. Disabled shops
are restricted to admins and board members. Hidden tools are shown only to
admins/board, the shop's resource managers, or members with an active checkout
for that tool.

Shops and tools can also store an optional Google Drive folder ID. The workshop
page uses shop IDs for an embedded Documentation tab and tool IDs for links to
their Drive folders.

### Slack public channel cache

Public Slack channel metadata is cached in Redis under
`slack:public_channel:<normalized-name>`. Each value contains the channel ID,
name, topic, and purpose and expires after 3000 hours. Shop/tool and Slack portal
setting saves remove leading `#` characters from channel names. A cache miss
during a channel-name change opportunistically pages through
`conversations.list`, caching every public channel encountered until the
requested name is found.

Refresh the complete public-channel cache manually with:

```sh
bundle exec rake slack:refresh_public_channel_cache
```

`config/schedule.rb` runs this rake task monthly. The configured Slack token
must include permission to list public conversations.

## With Docker

1. Install [Docker](https://docs.docker.com/get-started/get-docker/)
2. Run `docker compose up` in the repo directory. Will take several minutes on the first run.
3. Visit http://localhost:3000
4. **To stop the server:** `docker compose down`
5. **To open a Rails console:** `docker compose exec web rails console`
6. **To open a [Mongo console](https://www.mongodb.com/docs/mongodb-shell/):** `docker compose exec db mongosh admin`

# Importing an archived db or Restoring production to development
First dump production to a local backup folder
```
mongodump --uri "<uri for prod db>" -o ./dump
```
Then restore to development server
```
mongorestore --uri "<uri for dev db>" dump/ --drop
```


# Testing
Rspec is used for unit testing the ruby backend.
```
$ rspec
```
Selenium integration tests for the [makerspace-react](https://github.com/ManchesterMakerspace/makerspace-react) can be run with
```
$ rake integration
```
Emails in the development environment are published to MailTrap under the adgrants@ user in Lastpass. To preview emails, you can view them in the browser by starting a server with `TEST_MAIL=true rails s`; this will start a development server, which will preview emails, using a test database to hydrate values for all the mocks. If you need to test that the emails actually sent, you may use `MAILTRAP_API_TOKEN` environment variable in the development environment. 

# Swagger
An OpenSwagger spec of the JSON API can be generated or updated with `rake rswag:specs:swaggerize`. To view an interactive version of this swagger, start a development server with `rails s` and navigate to `/api-docs`

# Documentation

- [Public resources inventory](docs/public-resources.MD)
- [Member statuses](docs/member-statuses.md)
- [Shop and tool reservations](docs/reservations.MD) — includes the public
  `GET /reservations/agenda` display and JSON feed contract.
- [Public rental-spot API](docs/rental-spots.MD) — unauthenticated JSON for QR
  and deep-link experiences.
- [Public volunteer resources](docs/volunteer-public-resources.MD) — bounty feeds
  and the volunteer leaderboard.

# CONTRIBUTIONS

Bug reports and pull requests are welcome on GitHub at https://github.com/ManchesterMakerspace/makerspace-interface. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the Contributor Covenant code of conduct.

All pull requests require Travis CI tests to pass before being merged.

# LICENSE

The app is available as open source under the terms of the MIT License.
