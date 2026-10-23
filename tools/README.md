# Reservation-to-MQTT daemon

`res2mqtt.py` polls MongoDB for approved shop and tool reservations and publishes
ongoing reservations plus retained `UpNext` messages. It refreshes its eight-hour
cache every 30 minutes by default and also publishes a reservation when its start
time arrives.

## Setup and use

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
cp tools/config.yaml.example tools/config.yaml
.venv/bin/python tools/res2mqtt.py
```

Configuration precedence is CLI, environment, then YAML. The default YAML path
is `tools/config.yaml`; change it with `--config` or `RES2MQTT_CONFIG`.
Every YAML key has a same-named kebab-case CLI option. Environment variables are:

`MLAB_URI` (required), `MONGO_DATABASE`, `MQTT_HOST` (required), `MQTT_PORT`,
`MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_CLIENT_ID`, `MQTT_TLS`,
`MQTT_TOPIC_PREFIX`, `REFRESH_MINUTES`, `WINDOW_HOURS`, `TIMEZONE`, and
`LOG_LEVEL`.

Topics use the resource's human-readable name without modification:
`reservations/<SHOPNAME>` for shop reservations and
`reservations/<SHOPNAME>/<TOOLNAME>` for tools. The next approved reservation
for each resource is retained at the same topic with `/UpNext` appended. MQTT
QoS 1 is used. Ensure shop and tool names are valid for your broker's topic
policy (MQTT itself permits spaces in topic names).

Both the legacy `paho-mqtt` 1.6.1 callback API and the versioned callback API
from `paho-mqtt` 2.x are supported.

## Checkins extraction

`analysis/checkins-extract.py` is a read-only exporter for the MongoDB
`checkins` collection. It writes data only to standard output and diagnostics
to standard error, so ordinary shell redirection works:

```sh
.venv/bin/python tools/analysis/checkins-extract.py \
  --start-date 2026-01-01 --end-date 2026-01-31 --format csv > checkins.csv
.venv/bin/python tools/analysis/checkins-extract.py \
  --input-file mongo-export.json --format json > checkins.json
```

The default configuration is `tools/config.yaml`; it need not exist. An
explicitly named `--config` must exist. The tool reads the existing
`mongo.uri`, optional `mongo.database`, and `timezone_name` keys and accepts a
section like this (command-line values override it):

```yaml
checkins_extract:
  input_file: exports/checkins.json # Relative to this configuration file.
  start_date: 2026-01-01
  end_date: 2026-01-31
  format: csv                       # csv, json, or ilp
  suppress: [email]
  remap: ["name=holder"]
  coalesce: 5
  day_of_week: true
```

`--input-file` supports a JSON array or newline-delimited JSON, including
MongoDB Extended JSON, and does not require a database URI. Otherwise
`MLAB_URI` takes precedence over `mongo.uri`; the configured database takes
precedence over the database in that URI. Date boundaries are local calendar
dates in `--timezone-name` (default `America/New_York`), including the complete
end date and accounting for daylight-saving transitions.

The `time` field is accepted only as integer epoch milliseconds. If it is
missing or unusable, `timeOf` may be a BSON/Extended JSON date, ISO timestamp,
or numeric Unix timestamp. Numeric fallback values with an absolute magnitude
of at least `100_000_000_000` are milliseconds; smaller values are seconds.
Naive ISO timestamps use the selected timezone. A valid `time` always wins,
even if it falls outside the requested range.

Remaps copy a source into a missing target (without deleting either source or
overwriting even a null target), followed by the default reader and generated
UTC `Datetime` and optional local `DayOfWeek`. Suppression occurs last.
Coalescing retains the first chronologically sorted event and removes a later
event less than the requested number of minutes away when its nonempty `name`
or `uid` exactly matches a retained event. Readers and locations do not affect
matching, discarded events do not extend the window, and an event exactly at
the boundary remains.

CSV places `Datetime` first, uses the union of columns, and JSON-encodes nested
cells. JSON retains nested native values while making BSON identifiers and
dates portable. InfluxDB line protocol uses the `checkins` measurement,
nonempty `reader` and `where` tags, typed fields, and nanosecond event times.
For ILP, `time` becomes `source_time`, underscore-prefixed source keys gain a
`source` prefix (`_id` becomes `source_id`), null fields are omitted, and key
collisions or otherwise unrepresentable points are errors. Because reader is a
tag, simultaneous events with identical tags can merge when imported.
