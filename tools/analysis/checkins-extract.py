#!/usr/bin/env python3
"""Read-only checkin export utility."""

import argparse
import csv
import json
import math
import os
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import yaml
from bson import ObjectId, json_util
from pymongo import MongoClient
from pymongo.uri_parser import parse_uri

REPOSITORY = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = REPOSITORY / "tools/config.yaml"
MILLISECONDS_THRESHOLD = 100_000_000_000
MIN_DATETIME_MILLISECONDS = -62_135_596_800_000
MAX_DATETIME_MILLISECONDS = 253_402_300_799_999


class UserError(Exception):
    pass


@dataclass
class Settings:
    uri: str | None
    database: str | None
    input_file: Path | None
    start_date: date | None
    end_date: date | None
    output_format: str
    timezone_name: str
    suppress: list[str]
    remap: list[tuple[str, str]]
    coalesce: float
    day_of_week: bool


def parser():
    p = argparse.ArgumentParser(description="Export checkins without modifying MongoDB")
    p.add_argument("--config", type=Path)
    p.add_argument("--input-file", type=Path)
    p.add_argument("--start-date")
    p.add_argument("--end-date")
    p.add_argument("--format", choices=("csv", "json", "ilp"), dest="output_format")
    p.add_argument("--timezone-name")
    p.add_argument("--suppress", nargs="*")
    p.add_argument("--remap", action="append")
    p.add_argument("--coalesce", type=float)
    weekdays = p.add_mutually_exclusive_group()
    weekdays.add_argument("--day-of-week", action="store_true", dest="day_of_week")
    weekdays.add_argument("--no-day-of-week", action="store_false", dest="day_of_week")
    p.set_defaults(day_of_week=None)
    return p


def parse_day(value, label):
    if value in (None, ""):
        return None
    try:
        return date.fromisoformat(str(value))
    except ValueError as exc:
        raise UserError(f"invalid {label}: expected YYYY-MM-DD") from exc


def load_settings(args):
    explicit = args.config is not None
    config_path = (args.config or DEFAULT_CONFIG).resolve()
    if not config_path.exists():
        if explicit:
            raise UserError(f"configuration file does not exist: {config_path}")
        config = {}
    else:
        try:
            config = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError) as exc:
            raise UserError(f"cannot read configuration: {exc}") from exc
        if not isinstance(config, dict):
            raise UserError("configuration root must be a mapping")
    mongo = config.get("mongo") or {}
    section = config.get("checkins_extract") or {}
    if not isinstance(mongo, dict) or not isinstance(section, dict):
        raise UserError("mongo and checkins_extract must be mappings")
    raw_input = args.input_file if args.input_file is not None else section.get("input_file")
    input_file = None
    if raw_input:
        input_file = Path(raw_input)
        if args.input_file is None and not input_file.is_absolute():
            input_file = config_path.parent / input_file
        input_file = input_file.resolve()
    tz_name = args.timezone_name or config.get("timezone_name") or "America/New_York"
    try:
        ZoneInfo(tz_name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise UserError(f"unknown timezone: {tz_name}") from exc
    start = parse_day(args.start_date if args.start_date is not None else section.get("start_date"), "start date")
    end = parse_day(args.end_date if args.end_date is not None else section.get("end_date"), "end date")
    if start and end and start > end:
        raise UserError("start date must not be after end date")
    coalesce = args.coalesce if args.coalesce is not None else section.get("coalesce", 0)
    if isinstance(coalesce, bool):
        raise UserError("coalesce must be a nonnegative number")
    try:
        coalesce = float(coalesce)
    except (TypeError, ValueError) as exc:
        raise UserError("coalesce must be a nonnegative number") from exc
    if not math.isfinite(coalesce) or coalesce < 0:
        raise UserError("coalesce must be a nonnegative number")
    remaps = args.remap if args.remap is not None else section.get("remap", [])
    if not isinstance(remaps, list):
        raise UserError("remap must be a list")
    parsed_remaps, targets = [], set()
    for item in remaps:
        if not isinstance(item, str) or "=" not in item:
            raise UserError(f"invalid remap {item!r}; expected TARGET=SOURCE")
        target, source = item.split("=", 1)
        if not target or not source:
            raise UserError(f"invalid remap {item!r}; expected TARGET=SOURCE")
        if target in targets:
            raise UserError(f"duplicate remap target: {target}")
        targets.add(target)
        parsed_remaps.append((target, source))
    suppress = args.suppress if args.suppress is not None else section.get("suppress", [])
    if not isinstance(suppress, list) or not all(isinstance(x, str) for x in suppress):
        raise UserError("suppress must be a list of field names")
    uri = os.environ.get("MLAB_URI") or mongo.get("uri")
    if not input_file and not uri:
        raise UserError("MongoDB URI required (set MLAB_URI or mongo.uri), unless --input-file is used")
    output_format = args.output_format or section.get("format", "csv")
    if output_format not in ("csv", "json", "ilp"):
        raise UserError("format must be csv, json, or ilp")
    return Settings(uri, mongo.get("database"), input_file, start, end,
                    output_format, tz_name,
                    suppress, parsed_remaps, coalesce,
                    args.day_of_week if args.day_of_week is not None else bool(section.get("day_of_week", False)))


def read_file(path):
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise UserError(f"cannot read input file: {exc}") from exc
    try:
        value = json_util.loads(raw)
        records = value if isinstance(value, list) else [value]
    except (ValueError, TypeError):
        try:
            records = [json_util.loads(line) for line in raw.splitlines() if line.strip()]
        except (ValueError, TypeError) as exc:
            raise UserError(f"malformed JSON input: {exc}") from exc
    if not all(isinstance(row, dict) for row in records):
        raise UserError("input must contain JSON objects")
    return records


def bounds(settings):
    zone = ZoneInfo(settings.timezone_name)
    start = datetime.combine(settings.start_date, time.min, zone) if settings.start_date else None
    finish = datetime.combine(settings.end_date + timedelta(days=1), time.min, zone) if settings.end_date else None
    return start.astimezone(timezone.utc) if start else None, finish.astimezone(timezone.utc) if finish else None


def valid_epoch_millis(value):
    return isinstance(value, int) and not isinstance(value, bool)


def fallback_time(value, zone):
    if isinstance(value, datetime):
        result = value
    elif isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        seconds = value / 1000 if abs(value) >= MILLISECONDS_THRESHOLD else value
        try:
            return datetime.fromtimestamp(seconds, timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    elif isinstance(value, str):
        try:
            result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    else:
        return None
    if result.tzinfo is None:
        result = result.replace(tzinfo=zone)
    return result.astimezone(timezone.utc)


def effective_time(record, zone):
    if valid_epoch_millis(record.get("time")):
        try:
            return datetime.fromtimestamp(record["time"] / 1000, timezone.utc)
        except (OverflowError, OSError, ValueError):
            pass
    return fallback_time(record.get("timeOf"), zone)


def mongo_records(settings, lower, upper):
    numeric = {"$type": ["int", "long"]}
    if lower: numeric["$gte"] = int(lower.timestamp() * 1000)
    if upper: numeric["$lt"] = int(upper.timestamp() * 1000)
    query = {"$or": [{"time": numeric}, {"time": {"$exists": False}},
                     {"time": None}, {"time": {"$not": {"$type": ["int", "long"]}}}]}
    # Integers outside Python's datetime range are unusable and therefore must
    # be fetched as timeOf fallback candidates even when date bounds are set.
    if lower or upper:
        query["$or"].extend((
            {"time": {"$type": ["int", "long"], "$lt": MIN_DATETIME_MILLISECONDS}},
            {"time": {"$type": ["int", "long"], "$gt": MAX_DATETIME_MILLISECONDS}},
        ))
    client = MongoClient(settings.uri)
    database = settings.database or parse_uri(settings.uri).get("database")
    if not database:
        raise UserError("MongoDB database required in mongo.database or the URI")
    try:
        return list(client[database]["checkins"].find(query))
    finally:
        client.close()


def transform(records, settings):
    lower, upper = bounds(settings)
    zone, rows, skipped = ZoneInfo(settings.timezone_name), [], 0
    for position, original in enumerate(records):
        stamp = effective_time(original, zone)
        if stamp is None:
            skipped += 1
            continue
        if (lower and stamp < lower) or (upper and stamp >= upper):
            continue
        row = dict(original)
        for target, source in settings.remap:
            if target not in original and source in original:
                row[target] = original[source]
        if "reader" not in row:
            row["reader"] = "default"
        row["Datetime"] = stamp.isoformat(timespec="milliseconds").replace("+00:00", "Z")
        if settings.day_of_week:
            row["DayOfWeek"] = stamp.astimezone(zone).strftime("%A")
        rows.append((stamp, str(original.get("_id", "")), position, row))
    rows.sort(key=lambda item: item[:3])
    retained, identities = [], {"name": {}, "uid": {}}
    window = timedelta(minutes=settings.coalesce)
    for stamp, _, _, row in rows:
        duplicate = False
        if settings.coalesce:
            for key in ("name", "uid"):
                value = row.get(key)
                if value not in (None, "") and value in identities[key] and stamp - identities[key][value] < window:
                    duplicate = True
        if duplicate:
            continue
        retained.append((stamp, {k: v for k, v in row.items() if k not in settings.suppress}))
        for key in ("name", "uid"):
            value = row.get(key)
            if value not in (None, ""):
                identities[key][value] = stamp
    return retained, skipped


def json_safe(value):
    if isinstance(value, ObjectId): return str(value)
    if isinstance(value, datetime):
        if value.tzinfo is None: value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    if isinstance(value, dict): return {k: json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)): return [json_safe(v) for v in value]
    return value


def output_csv(rows, stream):
    keys = set().union(*(row.keys() for _, row in rows)) if rows else set()
    fields = (["Datetime"] if "Datetime" in keys else []) + sorted(keys - {"Datetime"})
    writer = csv.DictWriter(stream, fieldnames=fields)
    writer.writeheader()
    for _, row in rows:
        cooked = {}
        for key, value in row.items():
            value = json_safe(value)
            cooked[key] = "" if value is None else (json.dumps(value, separators=(",", ":"), ensure_ascii=False) if isinstance(value, (dict, list)) else value)
        writer.writerow(cooked)


def esc(value, tag=False):
    value = str(value).replace("\\", "\\\\").replace(",", "\\,").replace(" ", "\\ ")
    return value.replace("=", "\\=") if tag else value


def ilp_field(value):
    value = json_safe(value)
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, int): return f"{value}i"
    if isinstance(value, float):
        if not math.isfinite(value): raise UserError("ILP cannot represent non-finite numbers")
        return repr(value)
    if isinstance(value, (dict, list)): value = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    if isinstance(value, str): return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'
    raise UserError(f"ILP cannot represent {type(value).__name__} values")


def output_ilp(rows, stream):
    for stamp, row in rows:
        tags, fields = [], {}
        for key in ("reader", "where"):
            if row.get(key) not in (None, ""):
                tags.append(f"{esc(key, True)}={esc(row[key], True)}")
        for key, value in row.items():
            if key in ("reader", "where") or value is None: continue
            translated = "source_time" if key == "time" else ("source" + key if key.startswith("_") else key)
            if translated in fields: raise UserError(f"ILP key collision: {translated}")
            fields[translated] = ilp_field(value)
        if not fields: raise UserError("ILP point has no fields after suppression")
        prefix = "checkins" + (("," + ",".join(tags)) if tags else "")
        epoch_delta = stamp - datetime(1970, 1, 1, tzinfo=timezone.utc)
        nanoseconds = ((epoch_delta.days * 86_400 + epoch_delta.seconds) * 1_000_000
                       + epoch_delta.microseconds) * 1_000
        stream.write(prefix + " " + ",".join(f"{esc(k, True)}={v}" for k, v in fields.items()) + f" {nanoseconds}\n")


def run(argv=None, stdout=sys.stdout, stderr=sys.stderr):
    args = parser().parse_args(argv)
    settings = load_settings(args)
    lower, upper = bounds(settings)
    records = read_file(settings.input_file) if settings.input_file else mongo_records(settings, lower, upper)
    rows, skipped = transform(records, settings)
    if settings.output_format == "csv": output_csv(rows, stdout)
    elif settings.output_format == "json": json.dump([json_safe(r) for _, r in rows], stdout, ensure_ascii=False); stdout.write("\n")
    elif settings.output_format == "ilp": output_ilp(rows, stdout)
    else: raise UserError(f"invalid format: {settings.output_format}")
    if skipped: print(f"Skipped {skipped} record(s) without a usable timestamp.", file=stderr)


def main():
    try:
        run()
    except UserError as exc:
        print(f"checkins-extract: error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
