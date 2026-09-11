#!/usr/bin/env python3
"""Run the ThermoSysPro 3.1 GT-trip trend through native OPC UA."""

from __future__ import annotations

import argparse
import csv
import json
import math
import time
from dataclasses import dataclass
from pathlib import Path


PROTOCOL = "TRIPLENS-NATIVE-OPCUA/1"


@dataclass(frozen=True)
class Signal:
    field: str
    node_names: tuple[str, ...]
    unit: str


def signal(field: str, node_name: str, unit: str, *fallbacks: str) -> Signal:
    return Signal(field, (node_name, *fallbacks), unit)


SIGNALS = (
    signal("model_gt_trip_command", "vppGTTripCmd", "BOOL", "vppExternalTripCommandNative"),
    signal("gt_trip_latch", "vppGTTripLatch", "BOOL", "vppSTTripLatch"),
    signal("breaker_52gt_trip_command", "vpp52GTTripCmd", "BOOL"),
    signal("breaker_52gt_closed", "vpp52GTClosed", "BOOL"),
    signal("breaker_52st_trip_command", "vpp52STTripCmd", "BOOL"),
    signal("breaker_52st_closed", "vpp52STClosed", "BOOL"),
    signal("gt_power_mw", "vppGTGPowerMW", "MW"),
    signal("gt_speed_rpm", "vppGTGSpeedRPM", "rpm"),
    signal("stg_power_w", "Alternateur.Welec", "W"),
    signal("gt_exhaust_flow_th", "vppGTExhaustMassFlowTH", "t/h"),
    signal("gt_exhaust_temperature_k", "vppGTExhaustTemperatureK", "K"),
    signal("hp_turbine_flow_th", "vppHPTurbineSteamFlowTH", "t/h"),
    signal("ip_turbine_flow_th", "vppIPTurbineSteamFlowTH", "t/h"),
    signal("lp_turbine_flow_th", "vppLPTurbineSteamFlowTH", "t/h"),
    signal("hp_admission_position_pu", "vppHPAdmissionPositionPU", "pu", "vppHPAdmissionPos"),
    signal("ip_admission_position_pu", "vppIPAdmissionPositionPU", "pu", "vppIPAdmissionPos"),
    signal("lp_admission_position_pu", "vppLPAdmissionMultiplierPU", "pu", "vppLPDrumAdmissionMultiplier"),
    signal("hp_bypass_position_pu", "vppHPBypassPositionPU", "pu", "vppHPBypassPos"),
    signal("lp_bypass_position_pu", "vppLPBypassPositionPU", "pu", "vppLPBypassPos"),
    signal("hp_bypass_flow_th", "vppHPBypassMassFlowTH", "t/h"),
    signal("lp_bypass_flow_th", "vppLPBypassMassFlowTH", "t/h"),
    signal("hp_spray_flow_th", "vppHPSprayMassFlowTH", "t/h"),
    signal("lp_spray_flow_th", "vppLPSprayMassFlowTH", "t/h"),
    signal("hp_drum_level_m", "vppHPDrumLevelM", "m", "BallonHP.yLevel.signal"),
    signal("ip_drum_level_m", "vppIPDrumLevelM", "m", "BallonMP.yLevel.signal"),
    signal("lp_drum_level_m", "vppLPDrumLevelM", "m", "BallonBP.yLevel.signal"),
    signal("hp_drum_pressure_pa", "vppHPDrumPressurePa", "Pa", "BallonHP.P"),
    signal("ip_drum_pressure_pa", "vppIPDrumPressurePa", "Pa", "BallonMP.P"),
    signal("lp_drum_pressure_pa", "vppLPDrumPressurePa", "Pa", "BallonBP.P"),
    signal("condenser_pressure_pa", "vppCondenserPressurePa", "Pa", "vppCondenserPressure"),
    signal("condenser_level_m", "vppCondenserLevelM", "m", "vppCondenserLevel"),
)


def connect(endpoint: str, timeout_s: float):
    from opcua import Client

    deadline = time.monotonic() + timeout_s
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        client = Client(endpoint, timeout=5)
        try:
            client.connect()
            return client
        except Exception as exc:
            last_error = exc
            try:
                client.disconnect()
            except Exception:
                pass
            time.sleep(0.25)
    raise TimeoutError(f"native OPC UA server was not ready: {last_error}")


def browse_nodes(client) -> dict[str, object]:
    nodes: dict[str, object] = {}
    for node in client.get_objects_node().get_children():
        try:
            name = node.get_browse_name().Name
        except Exception:
            continue
        if name in nodes:
            raise ValueError(f"duplicate OPC UA browse name: {name}")
        nodes[name] = node
    return nodes


def wait_for_model_nodes(client, command_name: str, timeout_s: float) -> dict[str, object]:
    deadline = time.monotonic() + timeout_s
    nodes: dict[str, object] = {}
    while time.monotonic() < deadline:
        nodes = browse_nodes(client)
        if command_name in nodes and all(
            any(name in nodes for name in item.node_names) for item in SIGNALS
        ):
            return nodes
        time.sleep(0.10)
    missing = [
        "/".join(item.node_names)
        for item in SIGNALS
        if not any(name in nodes for name in item.node_names)
    ]
    if command_name not in nodes:
        missing.insert(0, command_name)
    raise ValueError("native OPC UA nodes missing: " + ", ".join(missing))


def request_step(step_node, time_node, previous: float, ua, timeout_s: float) -> float:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        step_node.set_value(ua.Variant(True, ua.VariantType.Boolean))
        retry_at = min(deadline, time.monotonic() + 0.25)
        while time.monotonic() < retry_at:
            current = float(time_node.get_value())
            if current > previous + 1e-12:
                return current
            time.sleep(0.002)
    raise TimeoutError(f"native solver did not advance beyond {previous:.9f} s")


def as_number(value: object) -> float | int:
    if isinstance(value, bool):
        return int(value)
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("OPC UA returned a non-finite physical value")
    return number


def first_edge(rows: list[dict[str, float | int]], field: str, predicate) -> float | None:
    for row in rows:
        if predicate(row[field]):
            return float(row["time_s"])
    return None


def summarize(rows: list[dict[str, float | int]], field: str, pre_index: int) -> dict[str, float]:
    values = [float(row[field]) for row in rows]
    return {
        "pre_trip": values[pre_index],
        "minimum": min(values),
        "maximum": max(values),
        "final": values[-1],
        "final_delta": values[-1] - values[pre_index],
    }


def validate(rows: list[dict[str, float | int]], command_time_s: float) -> dict[str, object]:
    errors: list[str] = []
    pre_indices = [i for i, row in enumerate(rows) if row["time_s"] < command_time_s]
    post_indices = [i for i, row in enumerate(rows) if row["time_s"] >= command_time_s + 1.0]
    if not pre_indices or not post_indices:
        errors.append("capture lacks the required pre-trip or post-trip trend window")
        changed = 0
        trend_summary: dict[str, object] = {}
    else:
        pre_index = pre_indices[-1]
        post_index = post_indices[-1]
        pre = rows[pre_index]
        post = rows[post_index]
        if pre["gt_trip_command_readback"] != 0:
            errors.append("GT Trip input was true before the ECMS button command")
        if not any(row["gt_trip_command_readback"] == 1 for row in rows[post_indices[0]:]):
            errors.append("ECMS GT Trip command was not read back through OPC UA")
        if not any(row["gt_trip_latch"] == 1 for row in rows[post_indices[0]:]):
            errors.append("Modelica GT Trip latch did not assert")
        if not any(row["breaker_52gt_closed"] == 0 for row in rows[post_indices[0]:]):
            errors.append("Modelica 52GT physical feedback did not open")
        if float(post["hp_admission_position_pu"]) >= float(pre["hp_admission_position_pu"]):
            errors.append("HP admission valve did not close physically")
        if float(post["hp_bypass_position_pu"]) <= float(pre["hp_bypass_position_pu"]):
            errors.append("HP bypass valve did not open physically")
        physical_fields = [signal.field for signal in SIGNALS if signal.unit != "BOOL"]
        changed = sum(
            not math.isclose(
                float(pre[field]), float(post[field]), rel_tol=1e-10, abs_tol=1e-10
            )
            for field in physical_fields
        )
        if changed < 8:
            errors.append("too few OPC-UA-received physical values changed")
        trend_fields = (
            "hp_bypass_position_pu",
            "lp_bypass_position_pu",
            "hp_drum_level_m",
            "ip_drum_level_m",
            "lp_drum_level_m",
            "hp_drum_pressure_pa",
            "ip_drum_pressure_pa",
            "lp_drum_pressure_pa",
        )
        trend_summary = {
            field: summarize(rows, field, pre_index) for field in trend_fields
        }

    command_edge = first_edge(rows, "gt_trip_command_readback", lambda value: value == 1)
    latch_edge = first_edge(rows, "gt_trip_latch", lambda value: value == 1)
    breaker_edge = first_edge(rows, "breaker_52gt_closed", lambda value: value == 0)
    if any(edge is None for edge in (command_edge, latch_edge, breaker_edge)):
        errors.append("direct GT Trip causal-chain edge is missing")
    elif not (command_time_s <= command_edge <= latch_edge <= breaker_edge):
        errors.append("GT Trip button-to-latch-to-52GT causal order is invalid")

    return {
        "status": "PASS" if not errors else "FAIL",
        "proof_type": "ECMS_GT_TRIP_BUTTON_TO_NATIVE_THERMOSYSPRO_OPCUA_TREND",
        "protocol": PROTOCOL,
        "scenario_id": "ECMS_GT_TRIP_BUTTON_TREND_3_1",
        "command_source": "SIMULINK_ECMS_GT_TRIP_REQUEST",
        "command_path": (
            "ECMS GT TRIP button -> GT_TRIP_CMD -> OPC UA write -> "
            "Modelica Trip latch -> Modelica 52GT open feedback"
        ),
        "feedback_path": "native Modelica solved values -> OPC UA read -> MATLAB trend",
        "output_forcing": False,
        "frames_received": len(rows),
        "values_received": len(rows) * len(SIGNALS),
        "button_press_time_s": command_time_s,
        "opcua_command_readback_time_s": command_edge,
        "model_trip_latch_time_s": latch_edge,
        "breaker_52gt_open_feedback_time_s": breaker_edge,
        "changed_physical_fields": changed,
        "trend_summary": trend_summary,
        "errors": errors,
    }


def main() -> int:
    from opcua import ua

    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="opc.tcp://127.0.0.1:4841")
    parser.add_argument("--stop-time", type=float, default=130.0)
    parser.add_argument("--step-size", type=float, default=0.1)
    parser.add_argument("--command-time", type=float, default=10.0)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    count = args.stop_time / args.step_size
    if args.step_size <= 0 or not math.isclose(count, round(count), abs_tol=1e-9):
        parser.error("stop time must be an integer multiple of step size")
    if not 0 < args.command_time < args.stop_time:
        parser.error("command time must be inside the simulation window")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    client = connect(args.endpoint, 180.0)
    rows: list[dict[str, float | int]] = []
    try:
        command_name = "vppExternalTripCommandNative"
        nodes = wait_for_model_nodes(client, command_name, 60.0)
        time_node = client.get_node(ua.NodeId(10004, 0))
        step_node = client.get_node(ua.NodeId(10000, 0))
        command_node = nodes[command_name]
        signal_nodes = [
            nodes[next(name for name in signal.node_names if name in nodes)]
            for signal in SIGNALS
        ]
        current = float(time_node.get_value())
        command_written = float(command_node.get_value()) >= 0.5

        while current < args.stop_time - args.step_size / 2:
            button = current >= args.command_time - 1e-12
            if button and not command_written:
                command_node.set_value(ua.Variant(1.0, ua.VariantType.Double))
                command_written = True
            sent_ns = time.time_ns()
            next_time = request_step(step_node, time_node, current, ua, 30.0)
            readback = float(command_node.get_value()) >= 0.5
            values = client.get_values(signal_nodes)
            row: dict[str, float | int] = {
                "sequence": len(rows),
                "time_s": next_time,
                "ecms_gt_trip_button": int(next_time >= args.command_time - 1e-12),
                "ecms_gt_trip_command_sent": int(button),
                "gt_trip_command_readback": int(readback),
                "round_trip_ms": (time.time_ns() - sent_ns) / 1e6,
            }
            row.update(
                {
                    signal.field: as_number(value)
                    for signal, value in zip(SIGNALS, values)
                }
            )
            rows.append(row)
            current = next_time
        step_node.set_value(ua.Variant(True, ua.VariantType.Boolean))
    finally:
        try:
            client.disconnect()
        except (BrokenPipeError, ConnectionError, TimeoutError):
            pass

    csv_path = args.output_dir / "ECMS-GT-Trip-trend.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    report = validate(rows, args.command_time)
    (args.output_dir / "gt-trip-trend-proof.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    if report["status"] != "PASS":
        raise SystemExit("GT_TRIP_TREND_FAIL: " + "; ".join(report["errors"]))
    print(
        "GT_TRIP_TREND_OPCUA_PASS "
        f"frames={report['frames_received']} values={report['values_received']} "
        f"changed_physical={report['changed_physical_fields']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
