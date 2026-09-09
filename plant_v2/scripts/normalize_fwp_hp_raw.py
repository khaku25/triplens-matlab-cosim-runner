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


def _resample_to_physics_grid(
    records: Sequence[Mapping[str, float]], step_s: float = 0.1
) -> List[Dict[str, float]]:
    """Align adaptive/event solver output to the versioned physics RAW clock.

    OpenModelica can emit an event timestamp in place of one requested output
    point (for example 300.15 s instead of 300.2 s). The solver still advances
    with its configured maximum step. Canonical RAW is therefore reconstructed
    only from adjacent finite solver results by linear interpolation; no tag,
    command, alarm, or scenario result is synthesized.
    """
    if len(records) < 2:
        raise SystemExit("at least two solver records are required to resample")
    if not math.isfinite(step_s) or step_s <= 0.0:
        raise SystemExit(f"invalid physics RAW step: {step_s}")

    start_s = float(records[0]["time"])
    end_s = float(records[-1]["time"])
    interval_count = int(round((end_s - start_s) / step_s))
    if abs(start_s + interval_count * step_s - end_s) > 1e-7:
        raise SystemExit(
            f"solver evidence range {start_s}..{end_s} does not align "
            f"to the {step_s} s physics RAW clock"
        )

    result: List[Dict[str, float]] = []
    left_index = 0
    tolerance = 1e-9
    for index in range(interval_count + 1):
        target_s = start_s + index * step_s
        while (
            left_index + 1 < len(records)
            and float(records[left_index + 1]["time"]) < target_s - tolerance
        ):
            left_index += 1

        left = records[left_index]
        left_time = float(left["time"])
        if abs(left_time - target_s) <= tolerance:
            record = {name: float(left[name]) for name in CANONICAL_FIELDS}
            record["time"] = target_s
            result.append(record)
            continue

        if left_index + 1 >= len(records):
            raise SystemExit(f"cannot bracket physics RAW time {target_s}")
        right = records[left_index + 1]
        right_time = float(right["time"])
        if abs(right_time - target_s) <= tolerance:
            record = {name: float(right[name]) for name in CANONICAL_FIELDS}
            record["time"] = target_s
            result.append(record)
            continue
        if not (left_time < target_s < right_time):
            raise SystemExit(
                f"invalid solver bracket for {target_s}: "
                f"{left_time}..{right_time}"
            )

        fraction = (target_s - left_time) / (right_time - left_time)
        record = {"time": target_s}
        for name in CANONICAL_FIELDS[1:]:
            record[name] = float(left[name]) + fraction * (
                float(right[name]) - float(left[name])
            )
        result.append(record)

    return result


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

    solver_rows = len(combined)
    solver_max_output_gap_s = max(
        combined[index]["time"] - combined[index - 1]["time"]
        for index in range(1, len(combined))
    )
    combined = _resample_to_physics_grid(combined, step_s=0.1)
    canonical_max_output_gap_s = max(
        combined[index]["time"] - combined[index - 1]["time"]
        for index in range(1, len(combined))
    )

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
        "physics_raw_step_s": 0.1,
        "solver_rows": solver_rows,
        "solver_max_output_gap_s": solver_max_output_gap_s,
        "canonical_max_output_gap_s": canonical_max_output_gap_s,
        "time_alignment": {
            "method": "linear interpolation between adjacent solver outputs",
            "reason": (
                "OpenModelica event output may replace a requested 0.1 s "
                "sample; the solver integration step remains independently "
                "bounded by the workflow."
            ),
            "scenario_or_alarm_fields_created": False,
        },
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
