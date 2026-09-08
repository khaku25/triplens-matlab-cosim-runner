#!/usr/bin/env python3
"""Render the parameterized ThermoSysPro wrapper and OpenModelica script."""

from __future__ import annotations

import argparse
import math
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def positive_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a positive finite number")
    return number


def nonnegative_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("must be a non-negative finite number")
    return number


def render(template: Path, destination: Path, replacements: dict[str, str]) -> None:
    text = template.read_text(encoding="utf-8")
    for token, value in replacements.items():
        text = text.replace(f"@{token}@", value)
    unresolved = [part for part in text.split("@") if part.isupper() and "_" in part]
    if unresolved:
        raise ValueError(f"unresolved template token(s): {', '.join(unresolved)}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trip-time", type=nonnegative_float, default=600.0)
    parser.add_argument("--trip-ramp-duration", type=positive_float, default=5.0)
    parser.add_argument("--stop-time", type=positive_float, default=1000.0)
    parser.add_argument("--intervals", type=int, default=1000)
    parser.add_argument("--template-dir", type=Path, default=PROJECT_ROOT / "modelica")
    parser.add_argument("--output-dir", type=Path, default=PROJECT_ROOT / "build")
    args = parser.parse_args()

    if args.intervals < 10:
        parser.error("--intervals must be at least 10")
    if args.trip_time >= args.stop_time:
        parser.error("--trip-time must be earlier than --stop-time")
    if args.trip_time + args.trip_ramp_duration > args.stop_time:
        parser.error("trip ramp must end no later than --stop-time")

    output_interval = args.stop_time / args.intervals
    replacements = {
        "TRIP_TIME": f"{args.trip_time:.12g}",
        "TRIP_RAMP_DURATION": f"{args.trip_ramp_duration:.12g}",
        "STOP_TIME": f"{args.stop_time:.12g}",
        "NUMBER_OF_INTERVALS": str(args.intervals),
        "OUTPUT_INTERVAL": f"{output_interval:.12g}",
    }
    render(
        args.template_dir / "TripLens_CombinedCycle_TripTAC.mo.tpl",
        args.output_dir / "TripLens_CombinedCycle_TripTAC.mo",
        replacements,
    )
    render(args.template_dir / "run.mos.tpl", args.output_dir / "run.mos", replacements)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
