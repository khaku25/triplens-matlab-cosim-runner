"""Invoke the proven CVODE builder with a validated current seed artifact.

The original builder remains unchanged and hash-pinned for the legacy tested
artifact.  This adapter accepts only a native-seed manifest produced by the
strict current-3input profile, verifies its recorded provenance and SHA-256,
then injects that exact seed SHA into the same proven CVODE build path.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

EXPECTED_PROFILE = 'current-3input'
EXPECTED_SOURCE_RUN = 34308733698
EXPECTED_NATIVE_CAPTURE_RUN = 34220970632
EXPECTED_ENV = ['TRIPLENS_USE_NATIVE_SEED=1', 'TRIPLENS_RETAIN_VALIDATED_NLS_GUESS=1']


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--seed-fmu', type=Path, required=True)
    parser.add_argument('--seed-manifest', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--platform', choices=['linux64', 'win64'], required=True)
    args = parser.parse_args()

    manifest = json.loads(args.seed_manifest.read_text())
    actual_sha = sha256(args.seed_fmu)
    assert manifest['profile'] == EXPECTED_PROFILE, manifest.get('profile')
    assert manifest['source_fmu_run'] == EXPECTED_SOURCE_RUN, manifest.get('source_fmu_run')
    assert manifest['source_capture_run'] == EXPECTED_NATIVE_CAPTURE_RUN, manifest.get('source_capture_run')
    assert manifest['seeded_fmu_sha256'] == actual_sha, 'seed FMU SHA does not match its manifest'
    assert manifest['required_environment'] == EXPECTED_ENV, manifest.get('required_environment')
    assert manifest['physics_equations_modified'] is False
    assert manifest['physical_assertions_retained'] is True
    assert manifest['symbolic_initialization_retained'] is True
    assert manifest['real_variable_seeds'] >= 8400
    assert manifest['calculated_parameter_seeds'] == 61

    builder_path = Path(__file__).with_name('build_cvode_fmu.py')
    spec = importlib.util.spec_from_file_location('triplens_proven_cvode_builder', builder_path)
    assert spec and spec.loader
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)

    # Reuse the exact proven implementation, changing only the expected seed
    # identity to the manifest-verified current 3-input source.
    builder.SEED_SHA = actual_sha
    old_argv = sys.argv
    try:
        sys.argv = [
            str(builder_path),
            '--seed-fmu', str(args.seed_fmu),
            '--work', str(args.work),
            '--out', str(args.out),
            '--platform', args.platform,
        ]
        builder.main()
    finally:
        sys.argv = old_argv

    print('CURRENT_3INPUT_NATIVE_SEED_CVODE_BUILD_COMPLETE_SIMULATION_NOT_YET_VERIFIED', flush=True)


if __name__ == '__main__':
    main()
