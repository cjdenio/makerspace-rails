import importlib.util
import io
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from bson import ObjectId

MODULE_PATH = Path(__file__).with_name("checkins-extract.py")
SPEC = importlib.util.spec_from_file_location("checkins_extract", MODULE_PATH)
extract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(extract)


class CheckinsExtractTest(unittest.TestCase):
    def setUp(self):
        # A deterministic 32-record synthetic corpus with names and UIDs that do
        # not reproduce personal sample data.
        base = 1_767_240_000_000
        self.records = [
            {"_id": ObjectId(), "time": base + i * 60_000,
             "uid": f"R7X{i:03d}", "name": f"Synthetic Person {i}"}
            for i in range(32)
        ]

    def settings(self, **overrides):
        values = dict(uri=None, database=None, input_file=Path("input.json"),
                      start_date=None, end_date=None, output_format="json",
                      timezone_name="America/New_York", suppress=[], remap=[],
                      coalesce=0, day_of_week=False)
        values.update(overrides)
        return extract.Settings(**values)

    def test_transforms_all_32_and_generates_defaults(self):
        rows, skipped = extract.transform(self.records, self.settings(day_of_week=True))
        self.assertEqual((len(rows), skipped), (32, 0))
        self.assertEqual(rows[0][1]["reader"], "default")
        self.assertEqual(rows[0][1]["DayOfWeek"], "Wednesday")
        self.assertTrue(rows[0][1]["Datetime"].endswith("Z"))

    def test_valid_time_wins_and_invalid_time_falls_back(self):
        records = [
            {"time": 1_767_240_000_000, "timeOf": "1999-01-01T00:00:00Z"},
            {"time": "not milliseconds", "timeOf": 1_767_240_001},
            {"time": None, "timeOf": {"bad": True}},
        ]
        rows, skipped = extract.transform(records, self.settings())
        self.assertEqual(len(rows), 2)
        self.assertEqual(skipped, 1)
        self.assertEqual(rows[0][1]["Datetime"], "2026-01-01T04:00:00.000Z")

    def test_dst_date_bounds_include_entire_local_days(self):
        spring = self.settings(start_date=datetime(2026, 3, 8).date(),
                               end_date=datetime(2026, 3, 8).date())
        fall = self.settings(start_date=datetime(2026, 11, 1).date(),
                             end_date=datetime(2026, 11, 1).date())
        s1, s2 = extract.bounds(spring)
        f1, f2 = extract.bounds(fall)
        self.assertEqual((s2 - s1).total_seconds(), 23 * 3600)
        self.assertEqual((f2 - f1).total_seconds(), 25 * 3600)

    def test_remap_copy_then_coalesce_and_exact_boundary(self):
        base = 1_767_240_000_000
        records = [
            {"time": base, "holder": "Nova"},
            {"time": base + 299_999, "name": "Nova"},
            {"time": base + 300_000, "uid": "same"},
            {"time": base + 599_999, "uid": "same"},
            {"time": base + 600_000, "uid": "same"},
        ]
        settings = self.settings(remap=[("name", "holder")], coalesce=5)
        rows, _ = extract.transform(records, settings)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0][1]["holder"], "Nova")
        self.assertEqual(rows[0][1]["name"], "Nova")

    def test_null_reader_is_not_defaulted_and_suppression_is_last(self):
        records = [{"time": 1_767_240_000_000, "reader": None, "uid": "u"}]
        rows, _ = extract.transform(records, self.settings(suppress=["reader", "Datetime", "uid"]))
        self.assertEqual(rows[0][1], {"time": 1_767_240_000_000})

    def test_extended_json_array_and_ndjson(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "in.json")
            path.write_text('[{"time":{"$numberLong":"1767240000000"}}]')
            self.assertIsInstance(extract.read_file(path)[0]["time"], int)
            path.write_text('{"time":1767240000000}\n{"timeOf":{"$date":"2026-01-01T00:01:00Z"}}\n')
            self.assertEqual(len(extract.read_file(path)), 2)

    def test_csv_union_and_json_are_valid(self):
        rows = [(datetime.now(timezone.utc), {"Datetime": "x", "a": 1}),
                (datetime.now(timezone.utc), {"Datetime": "y", "nested": {"x": 2}})]
        output = io.StringIO()
        extract.output_csv(rows, output)
        self.assertEqual(output.getvalue().splitlines()[0], "Datetime,a,nested")
        self.assertIn('"{""x"":2}"', output.getvalue())
        self.assertEqual(json.loads(json.dumps([extract.json_safe(r) for _, r in rows]))[0]["a"], 1)

    def test_ilp_escaping_types_suppression_and_collision(self):
        stamp = datetime(2026, 1, 1, tzinfo=timezone.utc)
        row = {"reader": "front desk", "where": "a,b", "time": 12,
               "_id": ObjectId("000000000000000000000001"), "ok": True,
               "count": 2, "ratio": 1.5, "text": 'a"b'}
        output = io.StringIO()
        extract.output_ilp([(stamp, row)], output)
        line = output.getvalue()
        self.assertIn("reader=front\\ desk,where=a\\,b", line)
        self.assertIn("source_time=12i", line)
        self.assertIn("ok=true", line)
        with self.assertRaisesRegex(extract.UserError, "collision"):
            extract.output_ilp([(stamp, {"time": 1, "source_time": 2})], io.StringIO())

    def test_configuration_precedence_file_only_and_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "input.json").write_text("[]")
            config = root / "config.yml"
            config.write_text("mongo:\n  uri: mongodb://yaml/db\ntimezone_name: UTC\ncheckins_extract:\n  input_file: input.json\n  suppress: [yaml]\n")
            args = extract.parser().parse_args(["--config", str(config), "--suppress"])
            with patch.dict(os.environ, {"MLAB_URI": "mongodb://env/db"}):
                settings = extract.load_settings(args)
            self.assertEqual(settings.uri, "mongodb://env/db")
            self.assertEqual(settings.suppress, [])
            self.assertEqual(settings.input_file, root / "input.json")
        with self.assertRaises(extract.UserError):
            extract.load_settings(extract.parser().parse_args(["--timezone-name", "Mars/Olympus"]))

    def test_uri_required_without_input(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(extract, "DEFAULT_CONFIG", Path("/missing")):
            with self.assertRaisesRegex(extract.UserError, "URI required"):
                extract.load_settings(extract.parser().parse_args([]))

    def test_mongo_query_bounds_valid_time_and_fallback_candidates(self):
        settings = self.settings(uri="mongodb://example/source", database="db", input_file=None,
                                 start_date=datetime(2026, 1, 1).date(), end_date=datetime(2026, 1, 1).date())
        captured = {}
        class Collection:
            def find(self, query): captured["query"] = query; return []
        class Database:
            def __getitem__(self, name): self.name = name; return Collection()
        class Client:
            def __init__(self, uri): captured["uri"] = uri
            def __getitem__(self, name): captured["database"] = name; return Database()
            def close(self): captured["closed"] = True
        lower, upper = extract.bounds(settings)
        with patch.object(extract, "MongoClient", Client):
            extract.mongo_records(settings, lower, upper)
        numeric = captured["query"]["$or"][0]["time"]
        self.assertEqual(numeric["$gte"], int(lower.timestamp() * 1000))
        self.assertEqual(numeric["$lt"], int(upper.timestamp() * 1000))
        self.assertTrue(captured["closed"])


if __name__ == "__main__":
    unittest.main()
