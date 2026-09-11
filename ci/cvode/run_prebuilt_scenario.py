"""Run a JSON scenario against an already-built TripLens FMI 2.0 Co-Simulation FMU.

This runner deliberately has no OpenModelica dependency.  Model compilation is
owned by a separate build workflow; scenario changes only alter FMI inputs.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import shutil
import time
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from fmpy.fmi2 import FMU2Slave


SUPPORTED_TYPES = {"Real", "Integer", "Boolean", "Enumeration"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{label} must be numeric, not Boolean")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"{label} must be finite")
    return number


def load_scenario(path: Path) -> dict[str, Any]:
    scenario = json.loads(path.read_text(encoding="utf-8"))
    name = scenario.get("name")
    if not isinstance(name, str) or not name.strip():
        raise ValueError("scenario.name must be a non-empty string")

    stop = finite_number(scenario.get("stop_time_s"), "stop_time_s")
    step = finite_number(scenario.get("step_s"), "step_s")
    if stop <= 0 or step <= 0:
        raise ValueError("stop_time_s and step_s must be positive")
    interval_count = round(stop / step)
    if not math.isclose(interval_count * step, stop, rel_tol=0, abs_tol=1e-9):
        raise ValueError("stop_time_s must be an integer multiple of step_s")

    initial = scenario.get("initial_inputs")
    if not isinstance(initial, dict) or not initial:
        raise ValueError("initial_inputs must be a non-empty object")

    events = scenario.get("events", [])
    if not isinstance(events, list):
        raise ValueError("events must be an array")
    previous = -1.0
    for index, event in enumerate(events):
        if not isinstance(event, dict) or not isinstance(event.get("set"), dict) or not event["set"]:
            raise ValueError(f"events[{index}] must contain a non-empty set object")
        event_time = finite_number(event.get("time_s"), f"events[{index}].time_s")
        if event_time < 0 or event_time > stop:
            raise ValueError(f"events[{index}].time_s is outside the simulation window")
        if event_time < previous:
            raise ValueError("events must be sorted by time_s")
        if not math.isclose(round(event_time / step) * step, event_time, rel_tol=0, abs_tol=1e-9):
            raise ValueError(f"events[{index}].time_s must align with step_s")
        previous = event_time

    outputs = scenario.get("outputs")
    if not isinstance(outputs, list) or not outputs or not all(isinstance(x, str) and x for x in outputs):
        raise ValueError("outputs must be a non-empty array of FMI variable names")
    if len(outputs) != len(set(outputs)):
        raise ValueError("outputs must not contain duplicates")

    scenario["stop_time_s"] = stop
    scenario["step_s"] = step
    scenario["interval_count"] = interval_count
    return scenario


def variable_type(variable: Any) -> str:
    value = variable.type
    if value not in SUPPORTED_TYPES:
        raise ValueError(f"unsupported FMI type for {variable.name}: {value}")
    return value


def cast_value(value: Any, kind: str, label: str) -> Any:
    if kind == "Real":
        return finite_number(value, label)
    if kind in {"Integer", "Enumeration"}:
        if isinstance(value, bool) or int(value) != float(value):
            raise ValueError(f"{label} must be an integer")
        return int(value)
    if kind == "Boolean":
        if value not in {True, False, 0, 1}:
            raise ValueError(f"{label} must be Boolean or 0/1")
        return bool(value)
    raise AssertionError(kind)


def set_values(fmu: "FMU2Slave", entries: list[tuple[Any, Any]]) -> None:
    grouped: dict[str, list[tuple[int, Any]]] = {kind: [] for kind in SUPPORTED_TYPES}
    for variable, value in entries:
        kind = variable_type(variable)
        grouped[kind].append((variable.valueReference, cast_value(value, kind, variable.name)))
    if grouped["Real"]:
        fmu.setReal([x[0] for x in grouped["Real"]], [x[1] for x in grouped["Real"]])
    if grouped["Integer"]:
        fmu.setInteger([x[0] for x in grouped["Integer"]], [x[1] for x in grouped["Integer"]])
    if grouped["Enumeration"]:
        fmu.setInteger([x[0] for x in grouped["Enumeration"]], [x[1] for x in grouped["Enumeration"]])
    if grouped["Boolean"]:
        fmu.setBoolean([x[0] for x in grouped["Boolean"]], [x[1] for x in grouped["Boolean"]])


def get_values(fmu: "FMU2Slave", variables: list[Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for kind in SUPPORTED_TYPES:
        selected = [v for v in variables if variable_type(v) == kind]
        if not selected:
            continue
        refs = [v.valueReference for v in selected]
        if kind == "Real":
            values = fmu.getReal(refs)
        elif kind in {"Integer", "Enumeration"}:
            values = fmu.getInteger(refs)
        else:
            values = fmu.getBoolean(refs)
        result.update((variable.name, value) for variable, value in zip(selected, values))
    return result


def main() -> None:
    from fmpy import extract, read_model_description
    from fmpy.fmi2 import FMU2Slave

    parser = argparse.ArgumentParser()
    parser.add_argument("--fmu", type=Path, required=True)
    parser.add_argument("--scenario", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    scenario = load_scenario(args.scenario)
    model_description = read_model_description(str(args.fmu), validate=False)
    variables = {variable.name: variable for variable in model_description.modelVariables}

    input_names = set(scenario["initial_inputs"])
    for event in scenario["events"]:
        input_names.update(event["set"])
    missing_inputs = sorted(input_names - variables.keys())
    if missing_inputs:
        raise ValueError(f"scenario references missing FMI inputs: {missing_inputs}")
    invalid_inputs = sorted(name for name in input_names if variables[name].causality != "input")
    if invalid_inputs:
        raise ValueError(f"scenario attempts to drive non-input variables: {invalid_inputs}")
    unset_inputs = sorted(input_names - scenario["initial_inputs"].keys())
    if unset_inputs:
        raise ValueError(f"every driven input requires an initial value: {unset_inputs}")

    missing_outputs = sorted(set(scenario["outputs"]) - variables.keys())
    if missing_outputs:
        raise ValueError(f"scenario references missing FMI outputs: {missing_outputs}")
    output_variables = [variables[name] for name in scenario["outputs"]]

    args.out.mkdir(parents=True, exist_ok=True)
    csv_path = args.out / "physical-output.csv"
    report_path = args.out / "scenario-report.json"
    current_inputs = dict(scenario["initial_inputs"])
    input_order = sorted(current_inputs)
    applied_events: list[dict[str, Any]] = []
    temp_dir: str | None = None
    fmu: FMU2Slave | None = None
    initialized = False
    started = time.perf_counter()
    rows = 0
    report: dict[str, Any] = {
        "status": "not_started",
        "scenario": scenario["name"],
        "scenario_sha256": sha256(args.scenario),
        "fmu_sha256": sha256(args.fmu),
        "model_name": model_description.modelName,
        "stop_time_s": scenario["stop_time_s"],
        "step_s": scenario["step_s"],
        "openmodelica_installed_or_invoked": False,
        "actual_fmi_cosimulation": True,
        "csv_replay": False,
    }

    try:
        temp_dir = extract(str(args.fmu))
        fmu = FMU2Slave(
            guid=model_description.guid,
            unzipDirectory=temp_dir,
            modelIdentifier=model_description.coSimulation.modelIdentifier,
            instanceName="TripLens_Precompiled_Scenario",
        )
        fmu.instantiate(loggingOn=False)
        fmu.setupExperiment(startTime=0.0, tolerance=1e-6)
        fmu.enterInitializationMode()
        set_values(fmu, [(variables[name], value) for name, value in current_inputs.items()])
        fmu.exitInitializationMode()
        initialized = True

        events_by_step: dict[int, list[dict[str, Any]]] = {}
        for event in scenario["events"]:
            events_by_step.setdefault(round(event["time_s"] / scenario["step_s"]), []).append(event)

        with csv_path.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=["time_s", *input_order, *scenario["outputs"]])
            writer.writeheader()
            for sample in range(scenario["interval_count"] + 1):
                current_time = sample * scenario["step_s"]
                for event in events_by_step.get(sample, []):
                    set_values(fmu, [(variables[name], value) for name, value in event["set"].items()])
                    current_inputs.update(event["set"])
                    applied_events.append({"time_s": current_time, "set": event["set"]})

                output_values = get_values(fmu, output_variables)
                nonfinite = [
                    name for name, value in output_values.items()
                    if isinstance(value, float) and not math.isfinite(value)
                ]
                if nonfinite:
                    raise AssertionError(f"non-finite outputs at t={current_time}: {nonfinite}")
                writer.writerow({"time_s": current_time, **current_inputs, **output_values})
                rows += 1

                if sample < scenario["interval_count"]:
                    fmu.doStep(
                        currentCommunicationPoint=current_time,
                        communicationStepSize=scenario["step_s"],
                    )

        report.update(
            status="pass",
            samples=rows,
            applied_events=applied_events,
            output_file=csv_path.name,
            output_bytes=csv_path.stat().st_size,
        )
        print("PREBUILT_FMU_SCENARIO_PASS")
    except Exception as error:
        report.update(status="failure", error=repr(error), initialization_passed=initialized)
        print(f"PREBUILT_FMU_SCENARIO_FAILURE {error!r}")
        raise
    finally:
        report["wall_seconds"] = time.perf_counter() - started
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if fmu is not None:
            try:
                if initialized:
                    fmu.terminate()
                fmu.freeInstance()
            except Exception as cleanup_error:
                print(f"FMI_CLEANUP_WARNING {cleanup_error!r}")
        if temp_dir:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
