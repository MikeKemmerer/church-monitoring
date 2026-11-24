#!/usr/bin/env python3
"""Offline contract fixtures; never contact a deployed backend."""
import copy
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("adapter", str(ROOT / "client" / "church-monitoring-streaming"))
spec = importlib.util.spec_from_loader(loader.name, loader)
adapter = importlib.util.module_from_spec(spec)
loader.exec_module(adapter)
NOW = dt.datetime(2026, 11, 24, 18, tzinfo=dt.timezone.utc).timestamp()


def stamp(offset=0):
    return dt.datetime.fromtimestamp(NOW + offset, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def component(**details):
    return {"severity": "ok", "reason": "Healthy", "observed_at": stamp(),
            "age_seconds": 0, "stale": False, **details}


def fixture():
    return {"schema_version": 1, "generated_at": stamp(), "severity": "error",
            "components": {
                "playback": component(expected="stopped", actual="inactive", intentional_pause=True),
                "encoder": component(status="stopped"),
                "storage": component(mount={"required": False, "mounted": False},
                                     available_count=4, saved_enabled_count=0, selection_source="directory_scan"),
                "scheduling": component(source="youtube", provider="yt-dlp", calendar_required=False,
                                        discovery_fresh=True, discovery_checked_at=stamp(),
                                        discovery_age_seconds=0, decision_observed_at=stamp(),
                                        weekly_observed_at=None),
                "services": component(units={"streamer.service": {"state": "inactive", "restarts": 9}}),
                "auth": component(mode="not_applicable"),
                "resources": component(severity="error")},
            "next_action": {"action": "church_pause", "at": None}}


GROUP = {"name": "streaming", "label": "Streaming", "type": "group", "provider": "yt-streamer"}
CONFIG = {"monitors": [GROUP], "streaming_diagnostics": {"enabled": True}}
SOURCE_FIXTURES = None
if "--source-fixtures" in sys.argv:
    sys.argv.remove("--source-fixtures")
    SOURCE_FIXTURES = json.load(sys.stdin)


class ProjectionTests(unittest.TestCase):
    @unittest.skipUnless(SOURCE_FIXTURES, "optional authorized builder fixtures not supplied")
    def test_actual_source_builder_applicability(self):
        for item in SOURCE_FIXTURES["fixtures"]:
            with self.subTest(source=item["name"]):
                result, metric = adapter.project(GROUP, item["payload"], SOURCE_FIXTURES["now"])
                self.assertEqual(result["severity"], item.get("expected_severity", "ok"))
                self.assertEqual(metric["value"], "msi")
                scheduling = item["payload"]["components"]["scheduling"]
                ignored = "weekly_observed_at" if scheduling["source"] == "youtube" else "decision_observed_at"
                self.assertIsNone(scheduling[ignored])

    def row(self, payload, name, now=NOW):
        result, _ = adapter.project(GROUP, payload, now)
        return next(c for c in result["children"] if c["label"] == adapter.ROWS[name])

    def test_four_rows_and_no_top_severity_or_resources(self):
        result, metric = adapter.project(GROUP, fixture(), NOW)
        self.assertEqual([c["label"] for c in result["children"]], list(adapter.ROWS.values()))
        self.assertEqual(result["severity"], "ok")
        self.assertIsNone(metric)
        self.assertNotIn("units", result["children"][-1]["details"])
        self.assertEqual(self.row(fixture(), "storage")["severity"], "ok")

    def test_failures_keep_all_unknown(self):
        for payload in ({}, {"schema_version": 2}, {**fixture(), "components": []},
                        {**fixture(), "generated_at": "yesterday"}, {**fixture(), "schema_version": True}):
            result, metric = adapter.project(GROUP, payload, NOW)
            self.assertEqual(len(result["children"]), 4)
            self.assertTrue(all(c["severity"] == "unknown" for c in result["children"]))
            self.assertEqual(metric["value"], "unknown")
        payload = fixture()
        del payload["components"]["playback"]
        self.assertEqual(self.row(payload, "playback")["severity"], "unknown")

    def test_source_error_not_hidden_by_pause_or_directory_fallback(self):
        payload = fixture()
        payload["components"]["storage"] = component(severity="error", reason="Required mount absent")
        self.assertEqual(self.row(payload, "storage")["severity"], "error")
        payload["components"]["encoder"] = component(severity="unknown", reason="Missing telemetry")
        self.assertEqual(self.row(payload, "encoder")["severity"], "unknown")
        payload["components"]["encoder"] = component(severity="error", reason="Confirmed stalled progress",
                                                      progress_observed_at=stamp(-3600))
        self.assertEqual(self.row(payload, "encoder")["severity"], "error")
        payload["components"]["encoder"]["progress_observed_at"] = stamp(3)
        self.assertEqual(self.row(payload, "encoder")["severity"], "unknown")

    def test_timestamp_boundaries_and_historical_errors(self):
        payload = fixture()
        self.assertEqual(adapter.project(GROUP, payload, NOW + 90)[0]["severity"], "ok")
        self.assertEqual(adapter.project(GROUP, payload, NOW + 90.01)[0]["severity"], "unknown")
        for offset, expected in ((2, "ok"), (2.01, "unknown")):
            payload["generated_at"] = stamp(offset)
            self.assertEqual(adapter.project(GROUP, payload, NOW)[0]["severity"], expected)
        payload = fixture()
        storage = payload["components"]["storage"]
        storage.update(observed_at=stamp(-120), age_seconds=120, severity="error")
        self.assertEqual(self.row(payload, "storage")["severity"], "error")
        storage["observed_at"] = stamp(-120.01)
        row = self.row(payload, "storage")
        self.assertEqual(row["severity"], "unknown")
        self.assertIn("historical", row["reason"])
        storage.update(observed_at=stamp(), stale=True)
        self.assertEqual(self.row(payload, "storage")["severity"], "unknown")
        storage.update(stale=False, observed_at="invalid")
        self.assertEqual(self.row(payload, "storage")["severity"], "unknown")

    def test_scheduling_freshness_independent_services_fold(self):
        payload = fixture()
        schedule = payload["components"]["scheduling"]
        services = payload["components"]["services"]
        services.update(observed_at=stamp(-120), age_seconds=120)
        self.assertEqual(self.row(payload, "scheduling")["severity"], "ok")
        services["observed_at"] = stamp(-121)
        self.assertEqual(self.row(payload, "scheduling")["severity"], "unknown")
        services.update(observed_at=stamp(), age_seconds=0, severity="error", reason="Caddy failed")
        self.assertEqual(self.row(payload, "scheduling")["reason"], "Caddy failed")
        services.update(severity="warn", reason="Control warning")
        schedule["decision_observed_at"] = stamp(-91)
        row = self.row(payload, "scheduling")
        self.assertEqual(row["severity"], "warning")
        self.assertIn("uncertain", row["reason"])
        del payload["components"]["services"]
        self.assertEqual(self.row(payload, "scheduling")["severity"], "unknown")

    def test_discovery_calendar_decision_ttls(self):
        for field, boundary in (("weekly_observed_at", 90), ("decision_observed_at", 90)):
            payload = fixture()
            if field == "weekly_observed_at":
                payload["components"]["scheduling"].update(source="weekly", discovery_fresh=False,
                                                              decision_observed_at=None)
            payload["components"]["scheduling"][field] = stamp(-boundary)
            self.assertEqual(self.row(payload, "scheduling")["severity"], "ok")
            payload["components"]["scheduling"][field] = stamp(-boundary - .01)
            self.assertEqual(self.row(payload, "scheduling")["severity"], "unknown")
        payload = fixture()
        payload["components"]["scheduling"].update(observed_at=stamp(-600), age_seconds=600,
                                                      discovery_age_seconds=600, discovery_checked_at=None)
        self.assertEqual(self.row(payload, "scheduling")["severity"], "ok")
        self.assertEqual(self.row(payload, "scheduling", NOW + .01)["severity"], "unknown")
        payload = fixture()
        payload["components"]["scheduling"].update(calendar_required=True, calendar_ready=True,
                                                     calendar_age_seconds=180)
        self.assertEqual(self.row(payload, "scheduling")["severity"], "ok")
        self.assertEqual(self.row(payload, "scheduling", NOW + .01)["severity"], "unknown")
        payload["components"]["scheduling"].update(source="weekly", provider="api", calendar_required=False,
                                                      weekly_observed_at=stamp(), decision_observed_at=None)
        self.assertEqual(self.row(payload, "scheduling")["severity"], "ok")

    def test_sas_modes_boundaries_and_stale(self):
        for days, expected in ((31, "ok"), (30, "warn"), (7, "error"), (0, "error"), (-1, "error")):
            src = component(mode="sas", expires_at=stamp(days * 86400), days_remaining=days)
            self.assertEqual(adapter.blob(src, NOW)["status"], expected)
        for mode in ("msi", "azcli", "workloadidentity", "key", "accountkey"):
            self.assertEqual(adapter.blob(component(mode=mode), NOW)["status"], "ok")
        for src in (component(mode="sas"), component(mode="unknown"),
                    component(mode="sas", expires_at="bad", days_remaining=50), {},
                    component(mode="msi", observed_at=stamp(-121))):
            self.assertEqual(adapter.blob(src, NOW)["value"], "unknown")
        self.assertIsNone(adapter.blob(component(mode="not_applicable"), NOW))
        self.assertEqual(adapter.blob(component(mode="not_applicable", stale=True), NOW)["value"], "unknown")

    def test_source_applicability_independent_ages_and_stale_projection(self):
        youtube = fixture()
        youtube["components"]["scheduling"].update(observed_at=stamp(-500), age_seconds=500,
                                                       discovery_age_seconds=500, discovery_checked_at=None)
        row = self.row(youtube, "scheduling")
        self.assertEqual(row["severity"], "ok")
        self.assertEqual(row["source_observations"]["scheduling"]["observed_at"], stamp(-500))
        self.assertEqual(row["source_observations"]["services"]["observed_at"], stamp())
        youtube["components"]["services"].update(age_seconds=120)
        row = self.row(youtube, "scheduling", NOW + 1)
        self.assertEqual(row["severity"], "unknown")
        self.assertEqual(row["source_observations"]["services"]["age_seconds"], 121)
        self.assertEqual(row["source_observations"]["scheduling"]["age_seconds"], 501)
        result, metric = adapter.project(GROUP, fixture(), NOW + 91)
        self.assertNotIn("next_action", result)
        self.assertEqual(metric["value"], "unknown")
        result, metric = adapter.project(GROUP, fixture(), NOW, enabled=False)
        self.assertNotIn("next_action", result)
        self.assertEqual(metric["value"], "unknown")
        weekly = fixture()
        weekly["components"]["scheduling"] = component(source="weekly", provider="api",
            discovery_fresh=False, discovery_age_seconds=None, calendar_required=False,
            calendar_ready=True, decision_observed_at=None, weekly_observed_at=stamp())
        self.assertEqual(self.row(weekly, "scheduling")["severity"], "ok")
        missing_calendar = fixture()
        missing_calendar["components"]["scheduling"].update(severity="error", reason="Missing calendar",
            calendar_required=True, calendar_ready=False, calendar_age_seconds=None)
        self.assertEqual(self.row(missing_calendar, "scheduling")["severity"], "error")
        missing_calendar["components"]["scheduling"]["stale"] = True
        row = self.row(missing_calendar, "scheduling")
        self.assertEqual(row["severity"], "unknown")
        self.assertIn("historical", row["reason"])

    def test_sanitization_and_static_links(self):
        payload = fixture()
        payload["components"]["encoder"].update(encoder_pid=123, telemetry_pid=456,
                                                token="SECRET", api_url="SECRET")
        payload["components"]["storage"]["mount"]["credentials"] = "SECRET"
        payload["components"]["auth"]["signature"] = "SECRET"
        payload["summary"] = "SECRET"
        payload["next_action"] = {"action": "restart-with-SECRET", "at": "bad"}
        clean = adapter.sanitize(payload)
        self.assertNotIn("SECRET", json.dumps(clean))
        self.assertNotIn("pid", json.dumps(clean))
        self.assertEqual(clean["next_action"], {"action": "unknown", "at": None})
        for link in ("javascript:alert(1)", "http://a/?token=secret", "http://user:pass@a/",
                     "http://a/\"x", "http://a/\\evil", "http://a:bad", "https://a/#token"):
            self.assertIsNone(adapter.safe_url(link))
        self.assertEqual(adapter.safe_url("https://streaming.example.org/"), "https://streaming.example.org/")

    def test_merge_preserves_host_and_disabled_unknown(self):
        host = {"cpu": 33, "memory": {"percent": 42}, "timestamp": stamp(-200),
                "services": [{"name": "apache", "status": "active"}, GROUP],
                "slow_metrics": [{"id": "cert_expiry", "value": "10d"}, {"id": "blob_access", "value": "old"}],
                "private_existing_field": {"retained": True}}
        original = copy.deepcopy(host)
        result = adapter.merge(host, CONFIG, fixture(), NOW)
        self.assertEqual(host, original)
        for field in ("cpu", "memory", "timestamp", "private_existing_field"):
            self.assertEqual(result[field], original[field])
        self.assertEqual(result["services"][0], host["services"][0])
        self.assertEqual(result["slow_metrics"], [host["slow_metrics"][0]])
        result = adapter.merge(host, {**CONFIG, "streaming_diagnostics": {"enabled": False}}, fixture(), NOW)
        self.assertEqual(result["services"][-1]["severity"], "unknown")
        self.assertEqual(adapter.merge(host, {"monitors": []}, {}, NOW), host)
        for config in ({**GROUP, "children": []}, {**GROUP, "provider": "unknown"},
                       {**GROUP, "name": "--bad"}):
            self.assertFalse(adapter.valid_group(config, [config]))
        self.assertFalse(adapter.valid_group(GROUP, [GROUP, {"name": "x", "children": None}, GROUP]))

    def test_collect_disabled_lock_atomic_failure_replaces_green(self):
        work = ROOT / f".test-streaming-python-{os.getpid()}"
        work.mkdir()
        cache = str(work / "streaming.json")
        try:
            with patch.object(adapter, "fetch", return_value=adapter.sanitize(fixture())) as fetch:
                adapter.collect({"monitors": [GROUP]}, cache)
                fetch.assert_not_called()
                with open(cache + ".lock", "a") as lock:
                    adapter.fcntl.flock(lock, adapter.fcntl.LOCK_EX)
                    adapter.collect(CONFIG, cache)
                    fetch.assert_not_called()
                adapter.collect(CONFIG, cache)
                self.assertEqual(adapter.load(cache)["schema_version"], 1)
                self.assertFalse(Path(cache + ".new").exists())
            with patch.object(adapter, "fetch", side_effect=ValueError("404")):
                adapter.collect(CONFIG, cache)
                self.assertEqual(adapter.load(cache), {})
        finally:
            shutil.rmtree(work)


class TransportTests(unittest.TestCase):
    def test_bounded_fixed_request_no_proxy_redirects(self):
        responses = {}
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                calls.append(self.path)
                code, body, delay, chunked = responses["next"]
                time.sleep(delay)
                try:
                    self.send_response(code)
                    self.send_header("Location", "/must-not-follow")
                    if chunked:
                        self.send_header("Transfer-Encoding", "chunked")
                    else:
                        self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    if chunked:
                        self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n0\r\n\r\n")
                    else:
                        self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/api/streamer/diagnostics"
        work = ROOT / f".test-streaming-http-{os.getpid()}"
        work.mkdir()
        (work / ".curlrc").write_text('location\nurl = "http://127.0.0.1:1/not-allowed"\n')
        try:
            with patch.object(adapter, "ENDPOINT", url), patch.dict(
                    os.environ, {"http_proxy": "http://127.0.0.1:1", "ALL_PROXY": "http://127.0.0.1:1",
                                 "CURL_HOME": str(work)}):
                responses["next"] = (200, json.dumps(fixture()).encode(), 0, False)
                self.assertEqual(adapter.fetch()["schema_version"], 1)
                for code, body, chunked in ((404, b"missing", False), (302, json.dumps(fixture()).encode(), False),
                                            (200, b"x" * (adapter.LIMIT + 1), False),
                                            (200, b"x" * (adapter.LIMIT + 1), True),
                                            (200, b"not json", False)):
                    responses["next"] = (code, body, 0, chunked)
                    with self.assertRaises(ValueError):
                        adapter.fetch()
                responses["next"] = (200, b"{}", 3.2, False)
                started = time.monotonic()
                with self.assertRaises(ValueError):
                    adapter.fetch()
                self.assertLess(time.monotonic() - started, 3.6)
                self.assertTrue(all(path == "/api/streamer/diagnostics" for path in calls))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            shutil.rmtree(work)
        with patch.object(adapter, "ENDPOINT", url):
            with self.assertRaises(ValueError):
                adapter.fetch()


if __name__ == "__main__":
    unittest.main()
