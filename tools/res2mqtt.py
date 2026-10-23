#!/usr/bin/env python3
"""Publish current and upcoming Makerspace reservations to MQTT."""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

import yaml
from paho.mqtt import client as mqtt
from pymongo import MongoClient


LOG = logging.getLogger("res2mqtt")
APPROVED = "approved"


@dataclass(frozen=True)
class Settings:
    mongo_uri: str
    mongo_database: str | None
    mqtt_host: str
    mqtt_port: int = 1883
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    mqtt_client_id: str = "res2mqtt"
    mqtt_tls: bool = False
    mqtt_topic_prefix: str = "reservations"
    refresh_minutes: float = 30.0
    window_hours: float = 8.0
    timezone_name: str = "America/New_York"
    log_level: str = "INFO"


SETTING_ENV = {
    "mongo_uri": "MLAB_URI",
    "mongo_database": "MONGO_DATABASE",
    "mqtt_host": "MQTT_HOST",
    "mqtt_port": "MQTT_PORT",
    "mqtt_username": "MQTT_USERNAME",
    "mqtt_password": "MQTT_PASSWORD",
    "mqtt_client_id": "MQTT_CLIENT_ID",
    "mqtt_tls": "MQTT_TLS",
    "mqtt_topic_prefix": "MQTT_TOPIC_PREFIX",
    "refresh_minutes": "REFRESH_MINUTES",
    "window_hours": "WINDOW_HOURS",
    "timezone_name": "TIMEZONE",
    "log_level": "LOG_LEVEL",
}


def parse_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"invalid boolean value: {value!r}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config", default=os.getenv("RES2MQTT_CONFIG", "tools/config.yaml")
    )
    for name in SETTING_ENV:
        option = "--" + name.replace("_", "-")
        parser.add_argument(option, dest=name, default=None)
    return parser.parse_args(argv)


def load_settings(args: argparse.Namespace) -> Settings:
    path = Path(args.config)
    file_values: dict[str, Any] = {}
    if path.exists():
        loaded = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if not isinstance(loaded, dict):
            raise ValueError(f"{path} must contain a YAML mapping")
        # Accept either a flat file or convenient mongo:/mqtt: sections.
        file_values.update({k: v for k, v in loaded.items() if not isinstance(v, dict)})
        for section in ("mongo", "mqtt"):
            for key, value in loaded.get(section, {}).items():
                file_values[f"{section}_{key}"] = value
        if "mongo_uri" not in file_values and loaded.get("mongo", {}).get("uri"):
            file_values["mongo_uri"] = loaded["mongo"]["uri"]

    defaults = {
        "mqtt_port": 1883,
        "mqtt_client_id": "res2mqtt",
        "mqtt_tls": False,
        "mqtt_topic_prefix": "reservations",
        "refresh_minutes": 30,
        "window_hours": 8,
        "timezone_name": "America/New_York",
        "log_level": "INFO",
    }
    values: dict[str, Any] = {}
    for name, env_name in SETTING_ENV.items():
        values[name] = (
            getattr(args, name)
            or os.getenv(env_name)
            or file_values.get(name)
            or defaults.get(name)
        )

    missing = [name for name in ("mongo_uri", "mqtt_host") if not values.get(name)]
    if missing:
        raise ValueError("missing required setting(s): " + ", ".join(missing))
    values["mqtt_port"] = int(values["mqtt_port"])
    values["refresh_minutes"] = float(values["refresh_minutes"])
    values["window_hours"] = float(values["window_hours"])
    values["mqtt_tls"] = parse_bool(values["mqtt_tls"])
    if values["refresh_minutes"] <= 0 or values["window_hours"] <= 0:
        raise ValueError("refresh_minutes and window_hours must be greater than zero")
    ZoneInfo(values["timezone_name"])
    return Settings(**values)


def mongo_database_name(settings: Settings) -> str:
    if settings.mongo_database:
        return settings.mongo_database
    name = urlparse(settings.mongo_uri).path.lstrip("/").split("?")[0]
    if not name:
        raise ValueError("Mongo database is absent from MLAB_URI; set MONGO_DATABASE")
    return name


class ReservationDaemon:
    def __init__(self, settings: Settings, database: Any, mqtt_client: Any):
        self.settings = settings
        self.db = database
        self.mqtt = mqtt_client
        self.stop_event = threading.Event()
        self.cache: dict[str, dict[str, Any]] = {}
        self.names: dict[str, dict[str, Any]] = {
            "shops": {},
            "tools": {},
            "members": {},
        }
        self.retained: dict[str, str] = {}
        self.next_refresh = 0.0
        self.local_tz = ZoneInfo(settings.timezone_name)

    def refresh(self, now: datetime) -> None:
        end = now + timedelta(hours=self.settings.window_hours)
        query = {"end_at": {"$gt": now}, "start_at": {"$lte": end}}
        documents = list(self.db.reservations.find(query))
        self.cache = {str(document["_id"]): document for document in documents}
        self._warm_names(documents)
        self.publish_state(now)
        self.next_refresh = time.monotonic() + self.settings.refresh_minutes * 60
        LOG.info("cached %d reservations through %s", len(documents), end.isoformat())

    def _warm_names(self, reservations: Iterable[dict[str, Any]]) -> None:
        shop_ids = {r.get("shop_id") for r in reservations if r.get("shop_id")}
        tool_ids = {tool_id for r in reservations for tool_id in r.get("tool_ids", [])}
        member_ids = {r.get("member_id") for r in reservations if r.get("member_id")}
        self._load_missing("shops", shop_ids, {"name": 1})
        self._load_missing("tools", tool_ids, {"name": 1, "shop_id": 1})
        self._load_missing("members", member_ids, {"firstname": 1, "lastname": 1})

        missing_slack = [
            member_id
            for member_id in member_ids
            if "slack_id" not in self.names["members"].get(str(member_id), {})
        ]
        if missing_slack:
            slack_by_member = {
                str(row["member_id"]): row.get("slack_id")
                for row in self.db.slack_users.find(
                    {"member_id": {"$in": missing_slack}},
                    {"member_id": 1, "slack_id": 1},
                )
            }
            for member_id in missing_slack:
                self.names["members"].setdefault(str(member_id), {})["slack_id"] = (
                    slack_by_member.get(str(member_id))
                )

    def _load_missing(
        self, collection: str, ids: set[Any], projection: dict[str, int]
    ) -> None:
        missing = [item for item in ids if str(item) not in self.names[collection]]
        if not missing:
            return
        for row in self.db[collection].find({"_id": {"$in": missing}}, projection):
            self.names[collection][str(row["_id"])] = row

    def topics(self, reservation: dict[str, Any]) -> list[str]:
        shop = (
            self.names["shops"]
            .get(str(reservation.get("shop_id")), {})
            .get("name", str(reservation.get("shop_id")))
        )
        base = f"{self.settings.mqtt_topic_prefix.rstrip('/')}/{shop}"
        if reservation.get("reservation_scope") == "shop":
            return [base]
        return [
            f"{base}/{self.names['tools'].get(str(tool_id), {}).get('name', str(tool_id))}"
            for tool_id in reservation.get("tool_ids", [])
        ]

    def payload(self, reservation: dict[str, Any]) -> str:
        start, end = reservation["start_at"], reservation["end_at"]
        member = self.names["members"].get(str(reservation.get("member_id")), {})
        shop = self.names["shops"].get(str(reservation.get("shop_id")), {})
        tools = [
            self.names["tools"].get(str(i), {}).get("name", str(i))
            for i in reservation.get("tool_ids", [])
        ]
        result = {
            "id": str(reservation["_id"]),
            "status": reservation.get("status"),
            "title": reservation.get("title"),
            "start_at": int(start.timestamp()),
            "start_at_short": start.astimezone(self.local_tz).strftime(
                "%b %-d, %-I:%M %p"
            ),
            "end_at_short": end.astimezone(self.local_tz).strftime("%b %-d, %-I:%M %p"),
            "shop": shop.get("name", str(reservation.get("shop_id"))),
            "tools": tools,
            "member": {
                "first_name": member.get("firstname"),
                "last_name": member.get("lastname"),
            },
        }
        if member.get("slack_id"):
            result["member"]["slack_id"] = member["slack_id"]
        return json.dumps(result, separators=(",", ":"), sort_keys=True)

    def publish_state(self, now: datetime) -> None:
        self.cache = {
            reservation_id: reservation
            for reservation_id, reservation in self.cache.items()
            if reservation.get("end_at") > now
        }
        valid = [
            r
            for r in self.cache.values()
            if r.get("status") == APPROVED and r.get("end_at") > now
        ]
        ongoing = [r for r in valid if r.get("start_at") <= now]
        upcoming: dict[str, dict[str, Any]] = {}
        for reservation in valid:
            if reservation.get("start_at") <= now:
                continue
            for topic in self.topics(reservation):
                if (
                    topic not in upcoming
                    or reservation["start_at"] < upcoming[topic]["start_at"]
                ):
                    upcoming[topic] = reservation
        for reservation in ongoing:
            self.publish_reservation(reservation)

        desired = {
            f"{topic}/UpNext": self.payload(reservation)
            for topic, reservation in upcoming.items()
        }
        for topic in self.retained.keys() - desired.keys():
            self._publish(topic, "", retain=True)
        for topic, payload in desired.items():
            # Republish after every query, even when unchanged, per daemon contract.
            self._publish(topic, payload, retain=True)
        self.retained = desired

    def publish_reservation(self, reservation: dict[str, Any]) -> None:
        payload = self.payload(reservation)
        for topic in self.topics(reservation):
            self._publish(topic, payload, retain=False)

    def _publish(self, topic: str, payload: str, retain: bool) -> None:
        result = self.mqtt.publish(topic, payload, qos=1, retain=retain)
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            LOG.error("MQTT publish failed for %s: rc=%s", topic, result.rc)

    def run(self) -> None:
        self.refresh(datetime.now(timezone.utc))
        while not self.stop_event.is_set():
            now = datetime.now(timezone.utc)
            if time.monotonic() >= self.next_refresh:
                try:
                    self.refresh(now)
                except Exception:
                    LOG.exception("Mongo refresh failed; retaining previous cache")
                    self.next_refresh = time.monotonic() + min(
                        60, self.settings.refresh_minutes * 60
                    )
                continue
            starts = [
                r["start_at"]
                for r in self.cache.values()
                if r.get("status") == APPROVED and r.get("start_at") > now
            ]
            wait = min(1.0, max(0.0, self.next_refresh - time.monotonic()))
            if starts:
                wait = min(wait, max(0.0, (min(starts) - now).total_seconds()))
            if self.stop_event.wait(wait):
                break
            new_now = datetime.now(timezone.utc)
            due = [
                r
                for r in self.cache.values()
                if r.get("status") == APPROVED and now < r.get("start_at") <= new_now
            ]
            if due:
                self.publish_state(new_now)


def build_mqtt(settings: Settings) -> Any:
    # CallbackAPIVersion was introduced in paho-mqtt 2.0.  Passing it to the
    # 1.6 client raises a TypeError, so only opt in when the installed client
    # exposes the new API.
    callback_api_version = getattr(mqtt, "CallbackAPIVersion", None)
    if callback_api_version is None:
        client = mqtt.Client(client_id=settings.mqtt_client_id)
    else:
        client = mqtt.Client(
            callback_api_version.VERSION2, client_id=settings.mqtt_client_id
        )
    if settings.mqtt_username:
        client.username_pw_set(settings.mqtt_username, settings.mqtt_password)
    if settings.mqtt_tls:
        client.tls_set()
    client.connect(settings.mqtt_host, settings.mqtt_port, keepalive=60)
    client.loop_start()
    return client


def main(argv: list[str] | None = None) -> int:
    try:
        settings = load_settings(parse_args(argv))
    except (OSError, ValueError) as error:
        raise SystemExit(f"configuration error: {error}") from error
    logging.basicConfig(
        level=getattr(logging, settings.log_level.upper()),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    mongo_client = MongoClient(settings.mongo_uri, tz_aware=True)
    mqtt_client = build_mqtt(settings)
    daemon = ReservationDaemon(
        settings, mongo_client[mongo_database_name(settings)], mqtt_client
    )
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda _signum, _frame: daemon.stop_event.set())
    try:
        daemon.run()
    finally:
        mqtt_client.disconnect()
        mqtt_client.loop_stop()
        mongo_client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
