#!/usr/bin/env python3
"""Normalize split HP-FWP OpenModelica results into one canonical RAW file.

The fixed-closed post-transition model constrains the R&D isolation flow to
Qleak. OpenModelica may eliminate that constant flow as an alias and omit it
from CSV output. When that happens this adapter recovers the value from the
versioned model contract. It never invents a field tag or a scenario label.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


CANONICAL_FIELDS: Tuple[str, ...] = (
    "time",
    "rpm_command",
    "hp_boundary_flow",
    "hp_process_flow",
    "isolation_opening",
    "BallonHP.zl",
    "BallonHP.P",
    "BallonMP.zl",
    "BallonMP.P",
    "BallonBP.zl",
    "BallonBP.P",
)

RPM_COLUMNS = (
    "arretPomesHP.y.signal",
    "arretPomesHP.y",
    "PompeAlimHP.Vr",
    "PompeAlimHP.rpm_or_mpower.signal",
)
BOUNDARY_FLOW_COLUMNS = (
    "tripLensFwpHpDischargeNRV.Q",
    "PompeAlimHP.Q",
)
PROCESS_FLOW_COLUMNS = (
    "CapteurDebitEauHP.Measure.signal",
    "EconomiseurHP4.TwoPhaseFlowPipe.Q[4]",
)
OPENING_COLUMNS = ("tripLensFwpHpDischargeNRV.opening",)
DRUM_COLUMNS = CANONICAL_FIELDS[5:]


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transition", type=Path, required=True)
    parser.add_argument("--post", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    return parser.parse_args()


def _read_csv(path: Path) -> Tuple[List[str], List[Dict[str, str]]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise SystemExit(f"{path}: CSV has no header")
        header = [name.strip().strip('"') for name in reader.fieldnames]
        rows: List[Dict[str, str]] = []
        for raw in reader:
            rows.append(
                {
                    key.strip().strip('"'): value
                    for key, value in raw.items()
                    if key is not None
                }
            )
    if not rows:
        raise SystemExit(f"{path}: CSV has no data rows")
    return header, rows


def _resolve(
    header: Sequence[str], label: str, candidates: Iterable[str]
) -> Optional[str]:
    del label
    for name in candidates:
        if name in header:
            return name
    return None


def _require(
    header: Sequence[str], path: Path, label: str, candidates: Iterable[str]
) -> str:
    candidates = tuple(candidates)
    found = _resolve(header, label, candidates)
    if found is None:
        raise SystemExit(
            f"{path}: missing {label}; candidates={candidates}; "
            f"available={header}"
        )
    return found


def _number(row: Mapping[str, str], column: str, path: Path) -> float:
    try:
        value = float(row[column].strip().strip('"'))
    except (KeyError, AttributeError, ValueError) as exc:
        raise SystemExit(
            f"{path}: invalid {column} value: {row.get(column)!r}"
        ) from exc
    if not math.isfinite(value):
        raise SystemExit(f"{path}: non-finite {column} value: {value}")
    return value


def _format(value: float) -> str:
    return format(value, ".17g")


def main() -> int:
    args = _arguments()
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    if not contract.get("post_transition_fixed_closed_topology"):
        raise SystemExit(
            "contract does not authorize fixed-closed alias recovery"
        )
    if "post_transition_numerical_leak_kg_s" not in contract:
        raise SystemExit(
            "contract is missing post_transition_numerical_leak_kg_s"
        )
    post_qleak = float(contract["post_transition_numerical_leak_kg_s"])
    if not math.isfinite(post_qleak) or abs(post_qleak) > 0.2:
        raise SystemExit(f"invalid contract Qleak: {post_qleak}")

    combined: List[Dict[str, float]] = []
    last_time = -math.inf
    segment_sources: Dict[str, Dict[str, object]] = {}

    for segment, path in (
        ("transition", args.transition),
        ("post", args.post),
    ):
        header, rows = _read_csv(path)
        time_column = _require(header, path, "time", ("time",))
        rpm_column = _require(header, path, "rpm", RPM_COLUMNS)
        process_column = _require(
            header, path, "HP process flow", PROCESS_FLOW_COLUMNS
        )
        opening_column = _require(
            header, path, "HP isolation opening", OPENING_COLUMNS
        )
        drum_columns = {
            name: _require(header, path, name, (name,))
            for name in DRUM_COLUMNS
        }

        boundary_column = _resolve(
            header, "HP isolation boundary flow", BOUNDARY_FLOW_COLUMNS
        )
        recovered = False
        if boundary_column is None:
            if segment != "post":
                raise SystemExit(
                    f"{path}: transition boundary flow cannot be recovered "
                    "from a fixed-closed contract"
                )
            recovered = True
            boundary_source = (
                "contract.post_transition_numerical_leak_kg_s "
                "(compiler-eliminated fixed equation)"
            )
        else:
            boundary_source = f"csv:{boundary_column}"

        segment_sources[segment] = {
            "rpm": f"csv:{rpm_column}",
            "boundary_flow": boundary_source,
            "process_flow": f"csv:{process_column}",
            "isolation_opening": f"csv:{opening_column}",
            "boundary_alias_recovered": recovered,
            "input_rows": len(rows),
        }

        for row in rows:
            time_s = _number(row, time_column, path)
            if time_s <= last_time + 1e-7:
                continue
            boundary_flow = (
                post_qleak
                if boundary_column is None
                else _number(row, boundary_column, path)
            )
            record: Dict[str, float] = {
                "time": time_s,
                "rpm_command": _number(row, rpm_column, path),
                "hp_boundary_flow": boundary_flow,
                "hp_process_flow": _number(row, process_column, path),
                "isolation_opening": _number(row, opening_column, path),
            }
            for canonical, source in drum_columns.items():
                record[canonical] = _number(row, source, path)
            combined.append(record)
            last_time = time_s

    if not combined:
        raise SystemExit("no canonical RAW rows were produced")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CANONICAL_FIELDS)
        writer.writeheader()
        for record in combined:
            writer.writerow(
                {name: _format(record[name]) for name in CANONICAL_FIELDS}
            )

    provenance = {
        "status": "pass",
        "adapter": "TripLens Plant Model v2 HP-FWP RAW normalizer",
        "scenario_label_emitted": False,
        "canonical_fields": list(CANONICAL_FIELDS),
        "raw_rows": len(combined),
        "raw_start_s": combined[0]["time"],
        "raw_end_s": combined[-1]["time"],
        "post_transition_numerical_leak_kg_s": post_qleak,
        "segments": segment_sources,
        "guardrail": (
            "Recovered boundary flow is the versioned fixed-closed R&D model "
            "equation removed from CSV by compiler alias elimination; it is "
            "not a field tag, inferred accident result, or Competition label."
        ),
    }
    args.provenance.parent.mkdir(parents=True, exist_ok=True)
    args.provenance.write_text(
        json.dumps(provenance, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    print(
        "FWP_HP_CANONICAL_RAW_PASS",
        f"rows={len(combined)}",
        f"range={combined[0]['time']}..{combined[-1]['time']}",
        "post_alias_recovered="
        f"{segment_sources['post']['boundary_alias_recovered']}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
