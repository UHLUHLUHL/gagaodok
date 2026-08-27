import contextlib
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

import sync_inventory


SECRET = "SECRET_SENTINEL_DO_NOT_LEAK"
SECRET_B64 = "U0VDUkVUX1NFTlRJTkVMX0RPX05PVF9MRUFL"
ROOM_ID = "11111111-1111-1111-1111-111111111111"
WORLDLINE_ID = "22222222-2222-2222-2222-222222222222"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class SyncInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "output"

        rooms = [
            {
                "id": ROOM_ID,
                "title": f"private room {SECRET}",
                "profile": {
                    "name": "private persona",
                    "persona": {
                        "description": SECRET,
                        "samples": [SECRET],
                        "styleGuide": SECRET,
                        "isEnabled": True,
                    },
                },
                "groupChat": {
                    "participants": [{"roomId": ROOM_ID}],
                    "worldlines": [{"id": WORLDLINE_ID}],
                },
            }
        ]
        (self.source / "rooms_list.json").write_text(
            json.dumps(rooms), encoding="utf-8"
        )

        messages = [
            {
                "id": "30000000-0000-0000-0000-000000000001",
                "sender": "user",
                "text": SECRET,
                "timestamp": 1000.0,
                "turnId": None,
            },
            {
                "id": "30000000-0000-0000-0000-000000000002",
                "sender": "sapiens",
                "text": SECRET,
                "timestamp": 1001.0,
                "turnId": "40000000-0000-0000-0000-000000000001",
                "canonicalText": SECRET,
                "speakerRoomId": ROOM_ID,
                "reactions": [{"participantRoomId": ROOM_ID, "emoji": "x"}],
            },
            {
                "id": "30000000-0000-0000-0000-000000000003",
                "sender": "sapiens",
                "text": SECRET,
                "timestamp": 1007.0,
                "turnId": "40000000-0000-0000-0000-000000000002",
                "heartChanges": [
                    {"participantRoomId": ROOM_ID, "delta": 1, "reason": SECRET}
                ],
                "attachment": {
                    "id": "50000000-0000-0000-0000-000000000001",
                    "type": "file",
                    "fileName": f"{SECRET}.txt",
                    "fileSize": 30,
                    "fileExtension": "txt",
                    "dataBase64": SECRET_B64,
                    "mimeType": "text/plain",
                },
            },
        ]
        message_name = (
            f"room_{ROOM_ID}_worldline_{WORLDLINE_ID}_messages.json"
        )
        (self.source / message_name).write_text(
            json.dumps(messages), encoding="utf-8"
        )
        digest_name = f"room_{ROOM_ID}_worldline_{WORLDLINE_ID}_digest.json"
        (self.source / digest_name).write_text(
            json.dumps({"segments": [{"text": SECRET}]}), encoding="utf-8"
        )
        (self.source / f"avatar_{ROOM_ID}.png").write_bytes(b"\x89PNG\r\n")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_inventory_is_non_destructive_deterministic_and_private(self) -> None:
        before = sync_inventory.capture_snapshot(self.source, "PHONE_SPACE")
        source_state = {
            path.relative_to(self.source).as_posix(): (
                sha256(path),
                path.stat().st_size,
                path.stat().st_mtime_ns,
            )
            for path in self.source.rglob("*")
            if path.is_file()
        }

        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            first = sync_inventory.run_inventory(
                self.source, self.output / "first", "PHONE_SPACE"
            )
            second = sync_inventory.run_inventory(
                self.source, self.output / "second", "PHONE_SPACE"
            )

        after = sync_inventory.capture_snapshot(self.source, "PHONE_SPACE")
        comparison = sync_inventory.compare_snapshots(before, after)
        self.assertTrue(comparison["unchanged"])
        self.assertEqual(first, second)
        self.assertEqual(first["files"]["message"], 1)
        self.assertEqual(first["files"]["worldline"], 2)
        self.assertEqual(first["rooms"]["group_room_count"], 1)
        self.assertEqual(first["turn_identity"]["mixed_generation_file_count"], 1)
        self.assertEqual(first["turn_identity"]["ai_run_distinct_turn_ids"]["2_plus"], 1)
        self.assertEqual(first["turn_identity"]["immediate_risk_file_count"], 1)
        self.assertEqual(first["attachments"]["count"], 1)
        self.assertEqual(first["attachments"]["mime_counts"], {"text/plain": 1})
        self.assertEqual(first["group_references"]["reaction_count"], 1)
        self.assertEqual(first["group_references"]["heart_change_count"], 1)
        self.assertEqual(first["digests"]["legacy_unversioned_count"], 1)

        current_state = {
            path.relative_to(self.source).as_posix(): (
                sha256(path),
                path.stat().st_size,
                path.stat().st_mtime_ns,
            )
            for path in self.source.rglob("*")
            if path.is_file()
        }
        self.assertEqual(source_state, current_state)

        rendered = stdout.getvalue() + stderr.getvalue()
        for path in self.output.rglob("*"):
            if path.is_file():
                rendered += path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET, rendered)
        self.assertNotIn(SECRET_B64, rendered)

    def test_malformed_json_reports_category_without_content(self) -> None:
        malformed = self.source / "room_bad_messages.json"
        malformed.write_text(f'[{{"text":"{SECRET}"}}, BROKEN]', encoding="utf-8")

        result = sync_inventory.run_inventory(
            self.source, self.output / "malformed", "MAC_SPACE"
        )

        self.assertGreaterEqual(result["errors"]["decode_error"], 1)
        rendered = "".join(
            path.read_text(encoding="utf-8")
            for path in (self.output / "malformed").rglob("*")
            if path.is_file()
        )
        self.assertNotIn(SECRET, rendered)

    def test_snapshot_json_round_trip_and_change_detection(self) -> None:
        before = sync_inventory.capture_snapshot(self.source, "MAC_SPACE")
        manifest_path = self.root / "manifest.json"
        sync_inventory.write_json(manifest_path, before)
        loaded = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(before, loaded)

        target = self.source / "rooms_list.json"
        original = target.read_bytes()
        target.write_bytes(original + b" ")
        os.utime(target, ns=(target.stat().st_atime_ns, target.stat().st_mtime_ns + 1))
        after = sync_inventory.capture_snapshot(self.source, "MAC_SPACE")
        comparison = sync_inventory.compare_snapshots(before, after)
        self.assertFalse(comparison["unchanged"])
        self.assertEqual(comparison["changed_file_count"], 1)

    def test_source_symlink_is_not_followed(self) -> None:
        outside = self.root / "outside-secret.txt"
        outside.write_text(SECRET, encoding="utf-8")
        (self.source / "linked-secret.txt").symlink_to(outside)

        snapshot = sync_inventory.capture_snapshot(self.source, "MAC_SPACE")

        paths = {entry["relative_path"] for entry in snapshot["files"]}
        self.assertNotIn("linked-secret.txt", paths)


if __name__ == "__main__":
    unittest.main()
