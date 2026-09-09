#!/usr/bin/env python3
"""Build the integrated TripLens Plant Model v2 FMI/co-simulation class.

The builder keeps the pinned CombinedCycle_TripTAC equations and replaces only
validated source blocks with external command inputs. It does not invent new
pump physics. FWP-HP/IP/LP map to the three existing ThermoSysPro feedwater
pumps (HP/MP/BP). Condensate/CW pumps are intentionally not synthesized because
they are not present as centrifugal pump components in the current base model.

Validated semantics carried from the R&D main branch:
- GT exhaust flow/temperature are process-boundary commands. The proven
  606.94/893.75 -> 150/550 change is DERATING, not GT Trip.
- ST Trip is a physical secondary shutdown path: stTripCmd closes the actual
  HP/MP turbine admission-valve command sources; ThermoSysPro solves rundown.
- GT Trip itself is defined by breaker CLOSED=0 in ECMS logic. Native GT
  thermodynamic shutdown/rundown remains pending and is not fabricated here.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re

MODEL_NAME = "TripLens_Plant_V2_CoSim"
BASE_CLASS = "CombinedCycle_TripTAC"
NORMAL_GT_FLOW = 606.94
NORMAL_GT_TEMP = 893.75
NORMAL_FWP_RPM = 1400.0


def replace_once(text: str, pattern: re.Pattern[str], replacement: str, label: str) -> str:
    text, count = pattern.subn(replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"{label} replacement count={count}, expected 1")
    return text


def source_ramp_pattern(name: str) -> re.Pattern[str]:
    return re.compile(
        r"ThermoSysPro\.InstrumentationAndControl\.Blocks\.Sources\.Rampe\s+"
        + re.escape(name)
        + r"\(.*?\)\s*annotation\s*\(Placement\(transformation\(.*?\)\)\);",
        re.S,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("legacy_exact/vendor/ThermoSysPro/ThermoSysPro/Examples/CombinedCyclePowerPlant/CombinedCycle_TripTAC.mo"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("plant_v2/build/TripLens_Plant_V2_CoSim.mo"),
    )
    args = parser.parse_args()

    text = args.source.read_text(encoding="utf-8")

    for pump in ("PompeAlimHP", "PompeAlimMP", "PompeAlimBP"):
        count = len(re.findall(r"StaticCentrifugalPump\s+" + re.escape(pump) + r"\(", text))
        if count != 1:
            raise SystemExit(f"expected exactly one {pump}, found {count}")

    old_header = '''within ThermoSysPro.Examples.CombinedCyclePowerPlant;\nmodel CombinedCycle_TripTAC\n  "CCPP model to simulate a load variation from 100% to 50%"'''
    new_header = f'''within ThermoSysPro.Examples.CombinedCyclePowerPlant;\nblock TripLensV2ExternalRealSource\n  parameter Real initialValue;\n  Modelica.Blocks.Interfaces.RealInput u(start=initialValue);\n  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;\nequation\n  y.signal = if initial() then initialValue else u;\nend TripLensV2ExternalRealSource;\n\nblock TripLensV2STTripValveSource\n  parameter Real normalOpening=0.8;\n  Modelica.Blocks.Interfaces.RealInput trip(start=0);\n  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;\nequation\n  y.signal = if initial() then normalOpening else if trip >= 0.5 then 0 else normalOpening;\nend TripLensV2STTripValveSource;\n\nmodel {MODEL_NAME}\n  "TripLens Plant Model v2: GT process boundary, ST trip valve shutdown, and native FWP speed inputs"\n  Modelica.Blocks.Interfaces.RealInput gtExhaustFlowCmd(start={NORMAL_GT_FLOW}, unit="kg/s")\n    "GT process boundary command; 150 kg/s path is DERATING, not Trip";\n  Modelica.Blocks.Interfaces.RealInput gtExhaustTemperatureCmd(start={NORMAL_GT_TEMP}, unit="K")\n    "GT process boundary command; 550 K path is DERATING, not Trip";\n  Modelica.Blocks.Interfaces.RealInput stTripCmd(start=0)\n    "Latched ST Trip request; closes native HP/MP turbine admission commands";\n  Modelica.Blocks.Interfaces.RealInput fwpHpSpeedCmd(start={NORMAL_FWP_RPM}, unit="rpm");\n  Modelica.Blocks.Interfaces.RealInput fwpIpSpeedCmd(start={NORMAL_FWP_RPM}, unit="rpm")\n    "Maps to ThermoSysPro MP feedwater pump";\n  Modelica.Blocks.Interfaces.RealInput fwpLpSpeedCmd(start={NORMAL_FWP_RPM}, unit="rpm")\n    "Maps to ThermoSysPro BP feedwater pump";\n\n  Modelica.Blocks.Interfaces.RealOutput stElectricalPower(unit="W");\n  Modelica.Blocks.Interfaces.RealOutput hpDrumLevel(unit="m");\n  Modelica.Blocks.Interfaces.RealOutput ipDrumLevel(unit="m");\n  Modelica.Blocks.Interfaces.RealOutput lpDrumLevel(unit="m");\n  Modelica.Blocks.Interfaces.RealOutput hpDrumPressure(unit="Pa");\n  Modelica.Blocks.Interfaces.RealOutput ipDrumPressure(unit="Pa");\n  Modelica.Blocks.Interfaces.RealOutput lpDrumPressure(unit="Pa");\n  Modelica.Blocks.Interfaces.RealOutput hpTurbineInletValveOpening;\n  Modelica.Blocks.Interfaces.RealOutput mpTurbineInletValveOpening;\n  Modelica.Blocks.Interfaces.RealOutput fwpHpSpeedApplied(unit="rpm");\n  Modelica.Blocks.Interfaces.RealOutput fwpIpSpeedApplied(unit="rpm");\n  Modelica.Blocks.Interfaces.RealOutput fwpLpSpeedApplied(unit="rpm");\n  Modelica.Blocks.Interfaces.RealOutput fwpHpMassFlow(unit="kg/s");\n  Modelica.Blocks.Interfaces.RealOutput fwpIpMassFlow(unit="kg/s");\n  Modelica.Blocks.Interfaces.RealOutput fwpLpMassFlow(unit="kg/s");'''
    if old_header not in text:
        raise SystemExit("original CombinedCycle_TripTAC class header not found")
    text = text.replace(old_header, new_header, 1)

    pat_debit = re.compile(
        r"InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Debit\(.*?\)\s*"
        r"annotation \(Placement\(transformation\(extent=\{\{-527,-19\},\{-457,\s*55\}\}, rotation=0\)\)\);",
        re.S,
    )
    pat_temp = re.compile(
        r"InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Temperature\(.*?\)\s*"
        r"annotation \(Placement\(transformation\(extent=\{\{-527,-157\},\{\s*-457,-83\}\}, rotation=0\)\)\);",
        re.S,
    )
    text = replace_once(text, pat_debit, f"TripLensV2ExternalRealSource Debit(initialValue={NORMAL_GT_FLOW});", "GT flow source")
    text = replace_once(text, pat_temp, f"TripLensV2ExternalRealSource Temperature(initialValue={NORMAL_GT_TEMP});", "GT temperature source")

    # Carry the already validated ST physical shutdown adapter from R&D main.
    pat_st_hp = re.compile(
        r"ThermoSysPro\.InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps\s*"
        r"ConstantVanneTurbineHP\(.*?\)\s*"
        r"annotation \(Placement\(transformation\(extent=\{\{-241,-216\},\{\s*-171,-142\}\}, rotation=0\)\)\);",
        re.S,
    )
    pat_st_mp = re.compile(
        r"ThermoSysPro\.InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps\s*"
        r"ConstantVanneTurbineMP\(.*?\)\s*"
        r"annotation \(Placement\(transformation\(extent=\{\{-241,-300\},\{\s*-171,-226\}\}, rotation=0\)\)\);",
        re.S,
    )
    text = replace_once(
        text, pat_st_hp,
        "TripLensV2STTripValveSource ConstantVanneTurbineHP(normalOpening=0.8) annotation (Placement(transformation(extent={{-241,-216},{-171,-142}}, rotation=0)));",
        "ST HP admission source",
    )
    text = replace_once(
        text, pat_st_mp,
        "TripLensV2STTripValveSource ConstantVanneTurbineMP(normalOpening=0.8) annotation (Placement(transformation(extent={{-241,-300},{-171,-226}}, rotation=0)));",
        "ST MP admission source",
    )

    for source_name in ("arretPomesHP", "arretPomesMp", "arretPomesBP"):
        text = replace_once(
            text,
            source_ramp_pattern(source_name),
            f"TripLensV2ExternalRealSource {source_name}(initialValue={NORMAL_FWP_RPM});",
            source_name,
        )

    text = text.replace(f"end {BASE_CLASS};", f"end {MODEL_NAME};", 1)

    extra_eq = f'''\nequation\n  Debit.u = gtExhaustFlowCmd;\n  Temperature.u = gtExhaustTemperatureCmd;\n  ConstantVanneTurbineHP.trip = stTripCmd;\n  ConstantVanneTurbineMP.trip = stTripCmd;\n  arretPomesHP.u = fwpHpSpeedCmd;\n  arretPomesMp.u = fwpIpSpeedCmd;\n  arretPomesBP.u = fwpLpSpeedCmd;\n\n  stElectricalPower = Alternateur.Welec;\n  hpDrumLevel = BallonHP.zl;\n  ipDrumLevel = BallonMP.zl;\n  lpDrumLevel = BallonBP.zl;\n  hpDrumPressure = BallonHP.P;\n  ipDrumPressure = BallonMP.P;\n  lpDrumPressure = BallonBP.P;\n  hpTurbineInletValveOpening = ConstantVanneTurbineHP.y.signal;\n  mpTurbineInletValveOpening = ConstantVanneTurbineMP.y.signal;\n\n  fwpHpSpeedApplied = arretPomesHP.y.signal;\n  fwpIpSpeedApplied = arretPomesMp.y.signal;\n  fwpLpSpeedApplied = arretPomesBP.y.signal;\n  fwpHpMassFlow = PompeAlimHP.Q;\n  fwpIpMassFlow = PompeAlimMP.Q;\n  fwpLpMassFlow = PompeAlimBP.Q;\n'''
    helper_boundary = f"end TripLensV2STTripValveSource;\n\nmodel {MODEL_NAME}"
    helper_pos = text.find(helper_boundary)
    if helper_pos < 0:
        raise SystemExit("helper/model boundary not found")
    equation_pos = text.find("\nequation\n", helper_pos + len(helper_boundary))
    if equation_pos < 0:
        raise SystemExit("plant equation section not found")
    text = text[:equation_pos] + extra_eq + text[equation_pos + len("\nequation\n"):]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")
    print(f"WROTE {args.output}")
    print("PLANT_V2_BINDINGS=GT_PROCESS_BOUNDARY,ST_TRIP,FWT_HP,FWT_IP,FWT_LP")
    print("GT_TRIP_THERMODYNAMIC_SHUTDOWN=PENDING_NATIVE_ADAPTER")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
