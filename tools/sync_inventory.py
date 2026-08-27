#!/usr/bin/env python3
"""Read-only Gagaodok storage inventory.

This tool deliberately avoids the app's normal loaders because those loaders can
run legacy migrations and rewrite message files. Reports contain aggregate
counts, field names, hashes, and opaque file IDs only; conversation text, room
names, persona text, attachment names, and base64 payloads are never emitted.
"""

from __future__ import annotations

import argparse
import codecs
import hashlib
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterator


REPORT_SCHEMA_VERSION = 1
READ_CHUNK_BYTES = 1024 * 1024
MAX_JSON_FILE_BYTES = 512 * 1024 * 1024
MESSAGE_SUFFIX = "_messages.json"
DIGEST_SUFFIX = "_digest.json"
WORLDLINE_PATTERN = re.compile(
    r"^room_([0-9a-fA-F-]+)_worldline_([0-9a-fA-F-]+)_(messages|digest)\.json$"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(READ_CHUNK_BYTES):
            digest.update(chunk)
    return digest.hexdigest()


def _opaque_file_id(relative_path: str) -> str:
    return hashlib.sha256(relative_path.encode("utf-8")).hexdigest()[:16]


def _category(path: Path) -> str:
    name = path.name
    if name == "rooms_list.json":
        return "room_list"
    if name.endswith(MESSAGE_SUFFIX):
        return "message"
    if name.endswith(DIGEST_SUFFIX):
        return "digest"
    if name.lower().startswith("avatar_") or name == "profile_avatar.png":
        return "avatar"
    return "other"


def capture_snapshot(source: Path | str, source_space: str) -> dict[str, Any]:
    root = Path(source).resolve()
    if not root.is_dir():
        raise ValueError("source must be an existing directory")

    files: list[dict[str, Any]] = []
    for path in sorted(
        item for item in root.rglob("*") if item.is_file() and not item.is_symlink()
    ):
        stat = path.stat()
        relative = path.relative_to(root).as_posix()
        files.append(
            {
                "relative_path": relative,
                "category": _category(path),
                "size": stat.st_size,
                "mtime_ns": stat.st_mtime_ns,
                "sha256": _sha256(path),
            }
        )
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "source_space": source_space,
        "files": files,
    }


def compare_snapshots(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    before_files = {item["relative_path"]: item for item in before.get("files", [])}
    after_files = {item["relative_path"]: item for item in after.get("files", [])}
    added = set(after_files) - set(before_files)
    removed = set(before_files) - set(after_files)
    changed = {
        path
        for path in set(before_files) & set(after_files)
        if any(
            before_files[path].get(field) != after_files[path].get(field)
            for field in ("size", "mtime_ns", "sha256")
        )
    }
    return {
        "unchanged": not added and not removed and not changed,
        "added_file_count": len(added),
        "removed_file_count": len(removed),
        "changed_file_count": len(changed),
    }


def write_json(path: Path | str, value: Any) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _iter_json_array(path: Path) -> Iterator[Any]:
    if path.stat().st_size > MAX_JSON_FILE_BYTES:
        raise ValueError("file_too_large")

    decoder = json.JSONDecoder()
    utf8_decoder = codecs.getincrementaldecoder("utf-8")()
    buffer = ""
    position = 0
    eof = False
    started = False

    with path.open("rb") as handle:
        while True:
            if position > READ_CHUNK_BYTES:
                buffer = buffer[position:]
                position = 0

            while position < len(buffer) and buffer[position].isspace():
                position += 1

            if not started:
                if position >= len(buffer):
                    if eof:
                        raise json.JSONDecodeError("expected array", buffer, position)
                    chunk = handle.read(READ_CHUNK_BYTES)
                    eof = not chunk
                    buffer += utf8_decoder.decode(chunk, final=eof)
                    continue
                if buffer[position] != "[":
                    raise json.JSONDecodeError("expected array", buffer, position)
                position += 1
                started = True
                continue

            while position < len(buffer) and buffer[position].isspace():
                position += 1
            if position < len(buffer) and buffer[position] == "]":
                return
            if position < len(buffer) and buffer[position] == ",":
                position += 1
                continue

            try:
                value, end = decoder.raw_decode(buffer, position)
            except json.JSONDecodeError:
                if eof:
                    raise
                chunk = handle.read(READ_CHUNK_BYTES)
                eof = not chunk
                buffer += utf8_decoder.decode(chunk, final=eof)
                continue
            position = end
            yield value


def _decoded_base64_size(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    compact_length = sum(1 for char in value if not char.isspace())
    if compact_length == 0:
        return 0
    padding = 0
    for char in reversed(value):
        if char == "=":
            padding += 1
        elif char.isspace():
            continue
        else:
            break
    return max(0, (compact_length * 3) // 4 - min(padding, 2))


def _timestamp_seconds(value: Any) -> float | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    numeric = float(value)
    return numeric / 1000.0 if abs(numeric) >= 100_000_000_000 else numeric


def _empty_metrics(source_space: str, snapshot: dict[str, Any]) -> dict[str, Any]:
    category_counts = Counter(item["category"] for item in snapshot["files"])
    sizes = [item["size"] for item in snapshot["files"]]
    worldline_files = sum(
        1 for item in snapshot["files"] if WORLDLINE_PATTERN.match(item["relative_path"])
    )
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "source_space": source_space,
        "files": {
            "total": len(snapshot["files"]),
            "total_bytes": sum(sizes),
            "max_file_bytes": max(sizes, default=0),
            "room_list": category_counts["room_list"],
            "message": category_counts["message"],
            "digest": category_counts["digest"],
            "avatar": category_counts["avatar"],
            "other": category_counts["other"],
            "worldline": worldline_files,
        },
        "rooms": {"count": 0, "group_room_count": 0, "worldline_count": 0},
        "turn_identity": {
            "nil_turn_id_file_count": 0,
            "non_null_turn_id_file_count": 0,
            "mixed_generation_file_count": 0,
            "speaker_room_id_file_count": 0,
            "immediate_risk_file_count": 0,
            "ai_run_distinct_turn_ids": {"0": 0, "1": 0, "2_plus": 0},
            "timestamp_gap_over_seconds": {"5": 0, "30": 0, "60": 0},
            "max_adjacent_ai_gap_seconds": 0.0,
        },
        "attachments": {
            "count": 0,
            "declared_total_bytes": 0,
            "declared_max_bytes": 0,
            "decoded_total_bytes": 0,
            "decoded_max_bytes": 0,
            "declared_decoded_mismatch_count": 0,
            "mime_counts": {},
        },
        "avatars": {"count": category_counts["avatar"], "max_bytes": 0},
        "digests": {"count": 0, "legacy_unversioned_count": 0},
        "group_references": {
            "participant_count": 0,
            "speaker_message_count": 0,
            "reaction_count": 0,
            "heart_change_count": 0,
        },
        "schema_fields": {"room": [], "message": [], "digest": []},
        "errors": {
            "decode_error": 0,
            "encoding_error": 0,
            "read_error": 0,
            "file_too_large": 0,
        },
        "risk_candidates": [],
    }


def _record_error(metrics: dict[str, Any], error: Exception) -> None:
    if isinstance(error, ValueError) and str(error) == "file_too_large":
        metrics["errors"]["file_too_large"] += 1
    elif isinstance(error, UnicodeDecodeError):
        metrics["errors"]["encoding_error"] += 1
    elif isinstance(error, json.JSONDecodeError):
        metrics["errors"]["decode_error"] += 1
    else:
        metrics["errors"]["read_error"] += 1


def _finish_ai_run(
    metrics: dict[str, Any],
    run_turn_ids: set[str],
    run_has_nil: bool,
    gaps: list[float],
) -> bool:
    if not run_turn_ids and not run_has_nil and not gaps:
        return False
    count = len(run_turn_ids)
    bucket = "0" if count == 0 else "1" if count == 1 else "2_plus"
    metrics["turn_identity"]["ai_run_distinct_turn_ids"][bucket] += 1
    if gaps:
        run_max = max(gaps)
        metrics["turn_identity"]["max_adjacent_ai_gap_seconds"] = max(
            metrics["turn_identity"]["max_adjacent_ai_gap_seconds"], run_max
        )
        for threshold in (5, 30, 60):
            metrics["turn_identity"]["timestamp_gap_over_seconds"][str(threshold)] += sum(
                1 for gap in gaps if gap > threshold
            )
    return count >= 2


def _scan_rooms(path: Path, metrics: dict[str, Any]) -> None:
    fields: set[str] = set(metrics["schema_fields"]["room"])
    for room in _iter_json_array(path):
        if not isinstance(room, dict):
            continue
        metrics["rooms"]["count"] += 1
        fields.update(str(key) for key in room)
        group = room.get("groupChat")
        if isinstance(group, dict):
            metrics["rooms"]["group_room_count"] += 1
            participants = group.get("participants")
            if isinstance(participants, list):
                metrics["group_references"]["participant_count"] += len(participants)
            worldlines = group.get("worldlines")
            if isinstance(worldlines, list):
                metrics["rooms"]["worldline_count"] += len(worldlines)
    metrics["schema_fields"]["room"] = sorted(fields)


def _scan_messages(path: Path, metrics: dict[str, Any], relative: str) -> None:
    fields: set[str] = set(metrics["schema_fields"]["message"])
    has_nil = False
    has_non_null = False
    has_speaker = False
    has_multiple_turn_id_run = False
    in_ai_run = False
    run_turn_ids: set[str] = set()
    run_has_nil = False
    run_gaps: list[float] = []
    previous_ai_timestamp: float | None = None

    for message in _iter_json_array(path):
        if not isinstance(message, dict):
            continue
        fields.update(str(key) for key in message)
        turn_id = message.get("turnId")
        if turn_id is None:
            has_nil = True
        else:
            has_non_null = True

        speaker = message.get("speakerRoomId")
        if speaker is not None:
            has_speaker = True
            metrics["group_references"]["speaker_message_count"] += 1
        reactions = message.get("reactions")
        if isinstance(reactions, list):
            metrics["group_references"]["reaction_count"] += len(reactions)
        heart_changes = message.get("heartChanges")
        if isinstance(heart_changes, list):
            metrics["group_references"]["heart_change_count"] += len(heart_changes)

        attachment = message.get("attachment")
        if isinstance(attachment, dict):
            metrics["attachments"]["count"] += 1
            declared = attachment.get("fileSize")
            if isinstance(declared, int) and not isinstance(declared, bool) and declared >= 0:
                metrics["attachments"]["declared_total_bytes"] += declared
                metrics["attachments"]["declared_max_bytes"] = max(
                    metrics["attachments"]["declared_max_bytes"], declared
                )
            else:
                declared = None
            decoded = _decoded_base64_size(attachment.get("dataBase64"))
            if decoded is not None:
                metrics["attachments"]["decoded_total_bytes"] += decoded
                metrics["attachments"]["decoded_max_bytes"] = max(
                    metrics["attachments"]["decoded_max_bytes"], decoded
                )
            if declared is not None and decoded is not None and declared != decoded:
                metrics["attachments"]["declared_decoded_mismatch_count"] += 1
            mime = attachment.get("mimeType")
            if isinstance(mime, str) and mime:
                metrics["attachments"]["mime_counts"][mime] = (
                    metrics["attachments"]["mime_counts"].get(mime, 0) + 1
                )

        is_ai = str(message.get("sender", "")).lower() == "sapiens"
        if not is_ai:
            if in_ai_run:
                has_multiple_turn_id_run |= _finish_ai_run(
                    metrics, run_turn_ids, run_has_nil, run_gaps
                )
            in_ai_run = False
            run_turn_ids = set()
            run_has_nil = False
            run_gaps = []
            previous_ai_timestamp = None
            continue

        timestamp = _timestamp_seconds(message.get("timestamp"))
        if not in_ai_run:
            in_ai_run = True
        elif timestamp is not None and previous_ai_timestamp is not None:
            run_gaps.append(abs(timestamp - previous_ai_timestamp))
        previous_ai_timestamp = timestamp
        if turn_id is None:
            run_has_nil = True
        else:
            run_turn_ids.add(str(turn_id))

    if in_ai_run:
        has_multiple_turn_id_run |= _finish_ai_run(
            metrics, run_turn_ids, run_has_nil, run_gaps
        )

    if has_nil:
        metrics["turn_identity"]["nil_turn_id_file_count"] += 1
    if has_non_null:
        metrics["turn_identity"]["non_null_turn_id_file_count"] += 1
    if has_nil and has_non_null:
        metrics["turn_identity"]["mixed_generation_file_count"] += 1
    if has_speaker:
        metrics["turn_identity"]["speaker_room_id_file_count"] += 1
    candidate_reasons: list[str] = []
    if has_nil:
        candidate_reasons.append("legacy_nil_turn_id")
    if has_multiple_turn_id_run:
        candidate_reasons.append("adjacent_distinct_turn_ids")
    if has_nil and has_multiple_turn_id_run:
        metrics["turn_identity"]["immediate_risk_file_count"] += 1
        candidate_reasons.append("nil_and_multiple_turn_ids")
    if candidate_reasons:
        metrics["risk_candidates"].append(
            {"file_id": _opaque_file_id(relative), "reasons": candidate_reasons}
        )
    metrics["schema_fields"]["message"] = sorted(fields)


def _scan_digest(path: Path, metrics: dict[str, Any]) -> None:
    if path.stat().st_size > MAX_JSON_FILE_BYTES:
        raise ValueError("file_too_large")
    with path.open("r", encoding="utf-8") as handle:
        digest = json.load(handle)
    if not isinstance(digest, dict):
        return
    metrics["digests"]["count"] += 1
    fields = set(metrics["schema_fields"]["digest"])
    fields.update(str(key) for key in digest)
    metrics["schema_fields"]["digest"] = sorted(fields)
    version_keys = {
        "checkpointSchemaVersion",
        "compactionProfileId",
        "compactionContractFingerprint",
    }
    if not version_keys.intersection(digest):
        metrics["digests"]["legacy_unversioned_count"] += 1


def _summary_markdown(metrics: dict[str, Any]) -> str:
    files = metrics["files"]
    turns = metrics["turn_identity"]
    attachments = metrics["attachments"]
    errors = metrics["errors"]
    return "\n".join(
        [
            "# Gagaodok Phase 0 inventory summary",
            "",
            f"- source space: `{metrics['source_space']}`",
            f"- files: {files['total']} ({files['total_bytes']} bytes)",
            f"- rooms: {metrics['rooms']['count']} (group: {metrics['rooms']['group_room_count']})",
            f"- message files: {files['message']}",
            f"- worldline files: {files['worldline']}",
            f"- attachments: {attachments['count']} (max decoded bytes: {attachments['decoded_max_bytes']})",
            f"- mixed legacy/current turn files: {turns['mixed_generation_file_count']}",
            f"- immediate-risk files: {turns['immediate_risk_file_count']}",
            f"- decode/read errors: {sum(errors.values())}",
            "",
            "> This report intentionally excludes conversation text, room and persona names, attachment names, and base64 data.",
            "",
        ]
    )


def run_inventory(
    source: Path | str, output_dir: Path | str, source_space: str
) -> dict[str, Any]:
    root = Path(source).resolve()
    output = Path(output_dir).resolve()
    if not root.is_dir():
        raise ValueError("source must be an existing directory")
    try:
        output.relative_to(root)
    except ValueError:
        pass
    else:
        raise ValueError("output directory must not be inside source")

    snapshot = capture_snapshot(root, source_space)
    metrics = _empty_metrics(source_space, snapshot)
    avatar_sizes = [
        item["size"] for item in snapshot["files"] if item["category"] == "avatar"
    ]
    metrics["avatars"]["max_bytes"] = max(avatar_sizes, default=0)

    for item in snapshot["files"]:
        relative = item["relative_path"]
        path = root / relative
        try:
            if item["category"] == "room_list":
                _scan_rooms(path, metrics)
            elif item["category"] == "message":
                _scan_messages(path, metrics, relative)
            elif item["category"] == "digest":
                _scan_digest(path, metrics)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            _record_error(metrics, error)

    metrics["attachments"]["mime_counts"] = dict(
        sorted(metrics["attachments"]["mime_counts"].items())
    )
    metrics["risk_candidates"].sort(key=lambda item: item["file_id"])

    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "inventory-manifest.json", snapshot)
    write_json(output / "schema-summary.json", {
        "schema_version": REPORT_SCHEMA_VERSION,
        "source_space": source_space,
        "schema_fields": metrics["schema_fields"],
        "errors": metrics["errors"],
    })
    write_json(output / "risk-candidates.json", {
        "schema_version": REPORT_SCHEMA_VERSION,
        "source_space": source_space,
        "candidates": metrics["risk_candidates"],
    })
    write_json(output / "inventory-metrics.json", metrics)
    (output / "inventory-summary.md").write_text(
        _summary_markdown(metrics), encoding="utf-8"
    )
    return metrics


def _load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("manifest must be a JSON object")
    return value


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read-only Gagaodok storage inventory")
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--source", required=True, type=Path)
    snapshot_parser.add_argument("--space", required=True)
    snapshot_parser.add_argument("--output", required=True, type=Path)

    inventory_parser = subparsers.add_parser("inventory")
    inventory_parser.add_argument("--source", required=True, type=Path)
    inventory_parser.add_argument("--space", required=True)
    inventory_parser.add_argument("--output-dir", required=True, type=Path)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--before", required=True, type=Path)
    compare_parser.add_argument("--after", required=True, type=Path)
    compare_parser.add_argument("--output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.command == "snapshot":
        write_json(args.output, capture_snapshot(args.source, args.space))
        print("snapshot complete")
        return 0
    if args.command == "inventory":
        result = run_inventory(args.source, args.output_dir, args.space)
        print(
            f"inventory complete: {result['source_space']}, "
            f"{result['files']['total']} files, {sum(result['errors'].values())} errors"
        )
        return 0 if sum(result["errors"].values()) == 0 else 2
    comparison = compare_snapshots(_load_json(args.before), _load_json(args.after))
    if args.output:
        write_json(args.output, comparison)
    print("unchanged" if comparison["unchanged"] else "changed")
    return 0 if comparison["unchanged"] else 3


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"inventory failed: {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)
