#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "plant_v2" / "plant_model_v2_contract.json"
GENERATED = ROOT / "plant_v2" / "build" / "TripLens_Plant_V2_CoSim.mo"


def fail(msg: str) -> None:
    print(f"PLANT_V2_VALIDATION_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    c = json.loads(CONTRACT.read_text(encoding="utf-8"))
    if c.get("schema_version") != "2.0.0":
        fail("unexpected schema version")

    ids = [m["id"] for m in c["physics_modules"]]
    expected = [
        "GT", "ST", "HRSG", "FWP_HP_DYNAMIC", "FWP_IP_DYNAMIC",
        "FWP_LP_DYNAMIC", "CONDENSATE_PUMP_DYNAMIC", "CW_PUMP_DYNAMIC",
    ]
    if ids != expected:
        fail(f"physics module order mismatch: {ids}")

    state_ids = [s["id"] for s in c["operating_states"]]
    if state_ids != ["NORMAL_100", "NORMAL_75", "NORMAL_50", "COLD_START"]:
        fail(f"operating state contract mismatch: {state_ids}")

    commands = c["command_contract"]["discrete_commands"]
    if commands != ["START", "STOP", "TRIP", "RESET", "BREAKER_OPEN", "BREAKER_CLOSE"]:
        fail(f"discrete command contract mismatch: {commands}")
    if c["command_contract"]["analog_commands"] != ["VALVE_POSITION"]:
        fail("analog command contract mismatch")

    if not GENERATED.is_file():
        fail(f"generated Modelica missing: {GENERATED}")
    text = GENERATED.read_text(encoding="utf-8")

    if "model TripLens_Plant_V2_CoSim" not in text:
        fail("generated class name missing")

    required_inputs = [
        "gtExhaustFlowCmd",
        "gtExhaustTemperatureCmd",
        "fwpHpSpeedCmd",
        "fwpIpSpeedCmd",
        "fwpLpSpeedCmd",
    ]
    for name in required_inputs:
        if len(re.findall(r"RealInput\s+" + re.escape(name) + r"\b", text)) != 1:
            fail(f"missing or duplicated input {name}")

    required_outputs = [
        "stElectricalPower",
        "hpDrumLevel", "ipDrumLevel", "lpDrumLevel",
        "hpDrumPressure", "ipDrumPressure", "lpDrumPressure",
        "fwpHpSpeedApplied", "fwpIpSpeedApplied", "fwpLpSpeedApplied",
        "fwpHpMassFlow", "fwpIpMassFlow", "fwpLpMassFlow",
    ]
    for name in required_outputs:
        if len(re.findall(r"RealOutput\s+" + re.escape(name) + r"\b", text)) != 1:
            fail(f"missing or duplicated output {name}")

    # The internal timed sources must be gone for the externally commandable
    # v2 physical inputs, while the native pumps themselves must remain.
    for source in ["arretPomesHP", "arretPomesMp", "arretPomesBP"]:
        if f"TripLensV2ExternalRealSource {source}" not in text:
            fail(f"external source binding missing for {source}")
        if re.search(r"Blocks\.Sources\.Rampe\s+" + source + r"\(", text):
            fail(f"old timed ramp still active for {source}")

    for pump in ["PompeAlimHP", "PompeAlimMP", "PompeAlimBP"]:
        if not re.search(r"StaticCentrifugalPump\s+" + pump + r"\(", text):
            fail(f"native pump {pump} was removed")

    # Condensate/CW pumps are reserved, not silently fabricated in the current
    # base model.
    fabricated = ["CondensatePump", "CW_Pump", "CirculatingWaterPump"]
    for name in fabricated:
        if re.search(r"\b" + re.escape(name) + r"\b", text):
            fail(f"unvalidated physical component fabricated: {name}")

    print("PLANT_V2_CONTRACT_PASS")
    print("ACTIVE_PHYSICS_INPUTS=" + ",".join(required_inputs))
    print("OPERATING_STATES=" + ",".join(state_ids))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
