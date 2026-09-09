#!/usr/bin/env python3
"""Build the TripLens Plant Model v2 FMI/co-simulation Modelica class.

The builder keeps the pinned CombinedCycle_TripTAC equations and replaces only
validated source blocks with external command inputs. It does not invent new
pump physics. FWP-HP/IP/LP map to the three existing ThermoSysPro feedwater
pumps (HP/MP/BP). Condensate/CW pumps are intentionally not synthesized because
they are not present as centrifugal pump components in the current base model.
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
    # Match one named ThermoSysPro Rampe declaration through its Placement
    # annotation. The name is followed by '(' so arretPomesHP does not match
    # arretPomesHP1.
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

    # Fail closed if the pinned plant no longer contains exactly the three
    # feedwater pump instances that this v2 binding knows about.
    for pump in ("PompeAlimHP", "PompeAlimMP", "PompeAlimBP"):
        count = len(re.findall(r"StaticCentrifugalPump\s+" + re.escape(pump) + r"\(", text))
        if count != 1:
            raise SystemExit(f"expected exactly one {pump}, found {count}")

    old_header = '''within ThermoSysPro.Examples.CombinedCyclePowerPlant;\nmodel CombinedCycle_TripTAC\n  "CCPP model to simulate a load variation from 100% to 50%"'''
    new_header = f'''within ThermoSysPro.Examples.CombinedCyclePowerPlant;\nblock TripLensV2ExternalRealSource\n  parameter Real initialValue;\n  Modelica.Blocks.Interfaces.RealInput u(start=initialValue);\n  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;\nequation\n  // During FMI initialization keep the validated nominal source value.\n  y.signal = if initial() then initialValue else u;\nend TripLensV2ExternalRealSource;\n\nmodel {MODEL_NAME}\n  "TripLens Plant Model v2: commandable GT boundary and three native feedwater pump speed inputs"\n  Modelica.Blocks.Interfaces.RealInput gtExhaustFlowCmd(start={NORMAL_GT_FLOW}, unit="kg/s");\n  Modelica.Blocks.Interfaces.RealInput gtExhaustTemperatureCmd(start={NORMAL_GT_TEMP}, unit="K");\n  Modelica.Blocks.Interfaces.RealInput fwpHpSpeedCmd(start={NORMAL_FWP_RPM}, unit="rpm");\n  Modelica.Blocks.Interfaces.RealInput fwpIpSpeedCmd(start={NORMAL_FWP_RPM}, unit="rpm")\n    "Maps to ThermoSysPro MP feedwater pump";\n  Modelica.Blocks.Interfaces.RealInput fwpLpSpeedCmd(start={NORMAL_FWP_RPM}, unit="rpm")\n    "Maps to ThermoSysPro BP feedwater pump";\n\n  Modelica.Blocks.Interfaces.RealOutput stElectricalPower(unit="W");\n  Modelica.Blocks.Interfaces.RealOutput hpDrumLevel(unit="m");\n  Modelica.Blocks.Interfaces.RealOutput ipDrumLevel(unit="m");\n  Modelica.Blocks.Interfaces.RealOutput lpDrumLevel(unit="m");\n  Modelica.Blocks.Interfaces.RealOutput hpDrumPressure(unit="Pa");\n  Modelica.Blocks.Interfaces.RealOutput ipDrumPressure(unit="Pa");\n  Modelica.Blocks.Interfaces.RealOutput lpDrumPressure(unit="Pa");\n  Modelica.Blocks.Interfaces.RealOutput fwpHpSpeedApplied(unit="rpm");\n  Modelica.Blocks.Interfaces.RealOutput fwpIpSpeedApplied(unit="rpm");\n  Modelica.Blocks.Interfaces.RealOutput fwpLpSpeedApplied(unit="rpm");\n  Modelica.Blocks.Interfaces.RealOutput fwpHpMassFlow(unit="kg/s");\n  Modelica.Blocks.Interfaces.RealOutput fwpIpMassFlow(unit="kg/s");\n  Modelica.Blocks.Interfaces.RealOutput fwpLpMassFlow(unit="kg/s");'''
    if old_header not in text:
        raise SystemExit("original CombinedCycle_TripTAC class header not found")
    text = text.replace(old_header, new_header, 1)

    # GT process boundary: same validated nominal values as the existing
    # normal-hold / 420 s baseline, now externally commandable.
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
    text = replace_once(
        text,
        pat_debit,
        f"TripLensV2ExternalRealSource Debit(initialValue={NORMAL_GT_FLOW});",
        "GT flow source",
    )
    text = replace_once(
        text,
        pat_temp,
        f"TripLensV2ExternalRealSource Temperature(initialValue={NORMAL_GT_TEMP});",
        "GT temperature source",
    )

    # Existing native feedwater pumps are already connected to these three
    # speed/rpm source blocks. Replacing only those sources preserves the pump,
    # piping, drum, HRSG and controller equations.
    for source_name in ("arretPomesHP", "arretPomesMp", "arretPomesBP"):
        text = replace_once(
            text,
            source_ramp_pattern(source_name),
            f"TripLensV2ExternalRealSource {source_name}(initialValue={NORMAL_FWP_RPM});",
            source_name,
        )

    text = text.replace(f"end {BASE_CLASS};", f"end {MODEL_NAME};", 1)

    extra_eq = f'''\nequation\n  Debit.u = gtExhaustFlowCmd;\n  Temperature.u = gtExhaustTemperatureCmd;\n  arretPomesHP.u = fwpHpSpeedCmd;\n  arretPomesMp.u = fwpIpSpeedCmd;\n  arretPomesBP.u = fwpLpSpeedCmd;\n\n  stElectricalPower = Alternateur.Welec;\n  hpDrumLevel = BallonHP.zl;\n  ipDrumLevel = BallonMP.zl;\n  lpDrumLevel = BallonBP.zl;\n  hpDrumPressure = BallonHP.P;\n  ipDrumPressure = BallonMP.P;\n  lpDrumPressure = BallonBP.P;\n\n  fwpHpSpeedApplied = arretPomesHP.y.signal;\n  fwpIpSpeedApplied = arretPomesMp.y.signal;\n  fwpLpSpeedApplied = arretPomesBP.y.signal;\n  fwpHpMassFlow = PompeAlimHP.Q;\n  fwpIpMassFlow = PompeAlimMP.Q;\n  fwpLpMassFlow = PompeAlimBP.Q;\n'''
    helper_boundary = f"end TripLensV2ExternalRealSource;\n\nmodel {MODEL_NAME}"
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
    print("PLANT_V2_BINDINGS=GT,FWT_HP,FWT_IP,FWT_LP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
