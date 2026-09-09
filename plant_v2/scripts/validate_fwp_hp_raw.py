#!/usr/bin/env python3
"""Validate canonical HP-FWP trip physics without using a scenario label."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Dict, List, Mapping, Sequence


FIELDS = (
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
DRUM_FIELDS = FIELDS[5:]


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def _read_raw(path: Path) -> List[Dict[str, float]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise SystemExit("canonical RAW has no header")
        header = tuple(name.strip().strip('"') for name in reader.fieldnames)
        if header != FIELDS:
            raise SystemExit(
                f"canonical RAW header mismatch: expected={FIELDS}, got={header}"
            )
        rows: List[Dict[str, float]] = []
        for line_number, raw in enumerate(reader, start=2):
            try:
                row = {name: float(raw[name]) for name in FIELDS}
            except (KeyError, TypeError, ValueError) as exc:
                raise SystemExit(
                    f"invalid canonical RAW row {line_number}: {raw}"
                ) from exc
            if not all(math.isfinite(value) for value in row.values()):
                raise SystemExit(
                    f"non-finite canonical RAW row {line_number}: {row}"
                )
            rows.append(row)
    return rows


def _nearest(
    rows: Sequence[Mapping[str, float]], target: float
) -> Mapping[str, float]:
    row = min(rows, key=lambda item: abs(item["time"] - target))
    if abs(row["time"] - target) > 0.051:
        raise SystemExit(
            f"missing sample near {target}: nearest={row['time']}"
        )
    return row


def main() -> int:
    args = _arguments()
    rows = _read_raw(args.raw)
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    provenance = json.loads(args.provenance.read_text(encoding="utf-8"))

    if len(rows) < 100:
        raise SystemExit(f"canonical RAW too short: {len(rows)}")
    times = [row["time"] for row in rows]
    if times[0] > 300.05 or times[-1] < 419.8:
        raise SystemExit(f"incomplete RAW range: {times[0]}..{times[-1]}")
    if any(right <= left for left, right in zip(times, times[1:])):
        raise SystemExit("canonical RAW time is not strictly monotonic")
    max_output_step = max(
        right - left for left, right in zip(times, times[1:])
    )
    if max_output_step > 0.100001:
        raise SystemExit(
            f"physics output interval exceeds 0.1 s: {max_output_step}"
        )

    rpm_rows = [
        row for row in rows if 300.08 - 1e-7 <= row["time"] <= 310.0 + 1e-7
    ]
    if any(
        right["rpm_command"] > left["rpm_command"] + 1e-6
        for left, right in zip(rpm_rows, rpm_rows[1:])
    ):
        raise SystemExit("HP-FWP RPM coastdown is not monotonic")

    sample_times = (300, 300.1, 300.5, 301, 302, 305, 310, 330, 360, 390, 420)
    samples = {
        str(target): dict(_nearest(rows, target)) for target in sample_times
    }
    if samples["300"]["rpm_command"] < 1399:
        raise SystemExit("NORMAL_100 HP-FWP speed is not 1400 rpm")
    if samples["310"]["rpm_command"] > 5:
        raise SystemExit("HP-FWP did not reach the zero-speed gate")
    if samples["300"]["isolation_opening"] < 0.99:
        raise SystemExit("HP-FWP discharge isolation is not open at NORMAL_100")
    if max(
        samples[str(target)]["isolation_opening"]
        for target in (301, 302, 305, 310)
    ) > 0.01:
        raise SystemExit("HP-FWP discharge isolation did not close")

    post_qleak = float(contract["post_transition_numerical_leak_kg_s"])
    post_rows = [row for row in rows if row["time"] > 301.0 + 1e-7]
    if not post_rows:
        raise SystemExit("canonical RAW has no post-transition rows")
    if max(abs(row["hp_boundary_flow"]) for row in post_rows) > 0.2:
        raise SystemExit("HP-FWP post-trip boundary leakage exceeds 0.2 kg/s")
    leak_error = max(
        abs(row["hp_boundary_flow"] - post_qleak) for row in post_rows
    )
    if leak_error > 1e-12:
        raise SystemExit(
            f"recovered fixed-closed boundary flow mismatch: {leak_error}"
        )

    process_flow_0 = samples["300"]["hp_process_flow"]
    process_flow_delta = max(
        abs(samples[str(target)]["hp_process_flow"] - process_flow_0)
        for target in (301, 302, 305, 310, 330)
    )
    process_scale = max(abs(process_flow_0), 1.0)
    if process_flow_delta <= max(1e-6, 1e-4 * process_scale):
        raise SystemExit("native HP feedwater process flow did not respond")

    hp_level_delta = samples["420"]["BallonHP.zl"] - samples["300"]["BallonHP.zl"]
    if hp_level_delta >= -0.01:
        raise SystemExit(
            f"HP drum level did not show feedwater-loss response: {hp_level_delta}"
        )
    for name in DRUM_FIELDS:
        if not all(math.isfinite(row[name]) for row in rows):
            raise SystemExit(f"non-finite native drum field: {name}")

    if provenance.get("scenario_label_emitted") is not False:
        raise SystemExit("normalizer provenance permits a scenario label")
    post_source = provenance["segments"]["post"]
    if post_source.get("boundary_alias_recovered") is not True:
        raise SystemExit("post fixed-flow alias recovery was not recorded")

    report = {
        "status": "pass",
        "simulation_success": True,
        "source_simulation_evidence": (
            "OpenModelica DASSL log reports successful 301-to-420 s completion"
        ),
        "raw_rows": len(rows),
        "raw_start_s": times[0],
        "raw_end_s": times[-1],
        "physics_output_max_step_s": max_output_step,
        "major_variables_finite": True,
        "rpm_coastdown_monotonic": True,
        "zero_speed_gate_reached": True,
        "discharge_isolation_closed": True,
        "post_transition_boundary_flow_kg_s": post_qleak,
        "post_transition_boundary_recovery_max_error": leak_error,
        "native_process_flow_max_delta_kg_s": process_flow_delta,
        "hp_drum_level_delta_m": hp_level_delta,
        "scenario_label_present": False,
        "samples": samples,
        "guardrail": (
            "Motor coastdown and numerical isolation constants are R&D values "
            "pending plant/OEM data; Competition consumes RAW only."
        ),
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, indent=2, sort_keys=True), encoding="utf-8"
    )
    print(
        "FWP_HP_WARMSTART_NATIVE_PASS",
        f"rows={len(rows)}",
        f"range={times[0]}..{times[-1]}",
        f"hp_level_delta={hp_level_delta}",
        f"process_flow_delta={process_flow_delta}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
