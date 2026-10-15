import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from bson import ObjectId

import res2mqtt


class Published:
    rc = 0


class FakeMqtt:
    def __init__(self):
        self.messages = []

    def publish(self, topic, payload, qos, retain):
        self.messages.append((topic, payload, qos, retain))
        return Published()


class ReservationDaemonTest(unittest.TestCase):
    def setUp(self):
        self.shop_id, self.tool_id, self.member_id = ObjectId(), ObjectId(), ObjectId()
        settings = res2mqtt.Settings("mongodb://example/db", None, "mqtt")
        self.mqtt = FakeMqtt()
        self.daemon = res2mqtt.ReservationDaemon(settings, None, self.mqtt)
        self.daemon.names = {
            "shops": {str(self.shop_id): {"name": "Wood Shop"}},
            "tools": {str(self.tool_id): {"name": "Table Saw"}},
            "members": {
                str(self.member_id): {
                    "firstname": "Ada",
                    "lastname": "Lovelace",
                    "slack_id": "U123",
                }
            },
        }

    def reservation(self, start, end, status="approved"):
        return {
            "_id": ObjectId(),
            "shop_id": self.shop_id,
            "tool_ids": [self.tool_id],
            "member_id": self.member_id,
            "reservation_scope": "tools",
            "title": "Cut stock",
            "status": status,
            "start_at": start,
            "end_at": end,
        }

    def test_publishes_ongoing_and_retained_up_next(self):
        now = datetime(2026, 8, 12, 12, tzinfo=timezone.utc)
        ongoing = self.reservation(
            now - timedelta(minutes=30), now + timedelta(minutes=30)
        )
        upcoming = self.reservation(now + timedelta(hours=1), now + timedelta(hours=2))
        self.daemon.cache = {str(r["_id"]): r for r in (ongoing, upcoming)}

        self.daemon.publish_state(now)

        self.assertEqual(self.mqtt.messages[0][0], "reservations/Wood Shop/Table Saw")
        self.assertFalse(self.mqtt.messages[0][3])
        payload = json.loads(self.mqtt.messages[0][1])
        self.assertEqual(payload["member"]["slack_id"], "U123")
        self.assertEqual(payload["start_at"], int(ongoing["start_at"].timestamp()))
        self.assertEqual(
            self.mqtt.messages[1][0], "reservations/Wood Shop/Table Saw/UpNext"
        )
        self.assertTrue(self.mqtt.messages[1][3])

    def test_clears_old_up_next_when_it_is_no_longer_approved(self):
        now = datetime.now(timezone.utc)
        reservation = self.reservation(
            now + timedelta(hours=1), now + timedelta(hours=2)
        )
        self.daemon.cache[str(reservation["_id"])] = reservation
        self.daemon.publish_state(now)
        reservation["status"] = "cancelled"

        self.daemon.publish_state(now)

        self.assertEqual(
            self.mqtt.messages[-1],
            ("reservations/Wood Shop/Table Saw/UpNext", "", 1, True),
        )


class SettingsTest(unittest.TestCase):
    def test_cli_overrides_environment_and_yaml(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory, "config.yaml")
            config.write_text(
                "mongo:\n  uri: mongodb://yaml/yaml_db\nmqtt:\n  host: yaml-host\n  port: 1884\n"
            )
            args = res2mqtt.parse_args(
                ["--config", str(config), "--mqtt-host", "cli-host"]
            )
            with patch.dict(
                os.environ,
                {"MLAB_URI": "mongodb://env/env_db", "MQTT_PORT": "1885"},
                clear=False,
            ):
                settings = res2mqtt.load_settings(args)
        self.assertEqual(settings.mongo_uri, "mongodb://env/env_db")
        self.assertEqual(settings.mqtt_host, "cli-host")
        self.assertEqual(settings.mqtt_port, 1885)


class MqttCompatibilityTest(unittest.TestCase):
    def settings(self):
        return res2mqtt.Settings(
            "mongodb://example/db", None, "mqtt.example", mqtt_client_id="reservations"
        )

    def fake_client(self, calls):
        class Client:
            def __init__(self, *args, **kwargs):
                calls.append((args, kwargs))

            def connect(self, *args, **kwargs):
                pass

            def loop_start(self):
                pass

        return Client

    def test_builds_paho_1_6_client_without_callback_api_argument(self):
        calls = []
        paho_1 = SimpleNamespace(Client=self.fake_client(calls))

        with patch.object(res2mqtt, "mqtt", paho_1):
            res2mqtt.build_mqtt(self.settings())

        self.assertEqual(calls, [((), {"client_id": "reservations"})])

    def test_builds_paho_2_client_with_versioned_callback_api(self):
        calls = []
        version_2 = object()
        paho_2 = SimpleNamespace(
            Client=self.fake_client(calls),
            CallbackAPIVersion=SimpleNamespace(VERSION2=version_2),
        )

        with patch.object(res2mqtt, "mqtt", paho_2):
            res2mqtt.build_mqtt(self.settings())

        self.assertEqual(calls, [((version_2,), {"client_id": "reservations"})])


if __name__ == "__main__":
    unittest.main()
