#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parent
contract = json.loads((root / 'ecms_twin_contract.json').read_text(encoding='utf-8'))

errors = []
notes = []

# 1) Electrical command/state contract completeness.
required_electrical = {
    'CB-52GT','CB-52ST','GRID-154KV','TR-GT','TR-ST','UAT-A','UAT-B','CB-IN-A','CB-IN-B','CB-TIE-AB'
}
found = set(contract['electrical_equipment'])
missing = sorted(required_electrical - found)
if missing:
    errors.append(f'missing electrical equipment contracts: {missing}')

for eq, spec in contract['electrical_equipment'].items():
    if not spec.get('commands'):
        errors.append(f'{eq}: no command list')
    if not spec.get('model_inputs'):
        errors.append(f'{eq}: no model input')
    if not spec.get('feedback_tag'):
        errors.append(f'{eq}: no feedback tag')

# 2) Process equipment must have one electrical location and one physical feedback path.
for eq, spec in contract['process_links'].items():
    for field in ('bus','feeder','voltage_kv','trip_input','feedback_tag','m_link','ecms_tag'):
        if spec.get(field) in (None, ''):
            errors.append(f'{eq}: missing {field}')
    if spec.get('feedback_tag') != spec.get('m_link'):
        errors.append(f"{eq}: command feedback {spec.get('feedback_tag')} != M-link {spec.get('m_link')}")
    if spec.get('voltage_kv') != 6.9:
        errors.append(f"{eq}: expected 6.9 kV mapping, got {spec.get('voltage_kv')}")

# 3) Proof-of-concept FWP-HP end-to-end contract.
hp = contract['process_links']['FWP-HP']
hp_checks = {
    'electrical_bus': hp['bus'] == 'BUS-A',
    'electrical_feeder': hp['feeder'] == 'VCB-A01',
    'electrical_voltage': hp['voltage_kv'] == 6.9,
    'ecms_trip_command': hp['trip_input'] == 'FWP_HP_TRIP',
    'thermo_feedback': hp['feedback_tag'] == 'TSP.DRUM.HP.FW_FLOW',
    'locked_m_link': hp['m_link'] == 'TSP.DRUM.HP.FW_FLOW',
    'ecms_physical_tag': hp['ecms_tag'] == 'ECMS.FWP-HP.PHYS',
}
for name, ok in hp_checks.items():
    if not ok:
        errors.append(f'FWP-HP chain failed: {name}')

# 4) Relay physics is intentionally NOT claimed ready.
relay_ready = bool(contract['known_gap'].get('protection_relay_physics'))
if relay_ready:
    errors.append('contract incorrectly claims protection relay physics is already ready')
else:
    notes.append('Protection relay V/I physics remains the next implementation layer.')

report = {
    'source_commit': contract['source_commit'],
    'electrical_equipment_contracts': len(contract['electrical_equipment']),
    'ecms_state_tags': len(contract['ecms_state_tags']),
    'process_links_checked': len(contract['process_links']),
    'fwp_hp_chain': hp_checks,
    'structural_1to1_ready': not errors,
    'full_protection_closed_loop_ready': False,
    'known_gap': contract['known_gap']['reason'],
    'errors': errors,
    'notes': notes,
}

(root / 'ecms_twin_contract_report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))

if errors:
    raise SystemExit(1)
