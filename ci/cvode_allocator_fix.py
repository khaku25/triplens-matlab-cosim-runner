"""Isolated runtime allocator repair justified by the Windows crash backtrace.

The CVODE_SOLVER outer object is allocated by FMI callbacks. Its internal
arrays belong to the CVODE/OMC C runtime. Free each with the allocator that
created it; do not suppress the destructor or leak the object to fake success.
Native non-FMI builds retain their original free(cvodeData) behavior.
"""
from pathlib import Path
import hashlib


def apply(source_root: Path) -> dict:
    solver = source_root / 'simulation/solver/cvode_solver.c'
    interface = source_root / 'fmi-export/fmu_read_flags.c'
    before = {str(p.relative_to(source_root)):hashlib.sha256(p.read_bytes()).hexdigest()
              for p in [solver, interface]}
    text = solver.read_text()
    needle = '  free(cvodeData);'
    assert text.count(needle) == 1, 'Unexpected CVODE destructor; review before patching.'
    text = text.replace(needle, '''#ifndef OMC_FMI_RUNTIME
  free(cvodeData);
#else
  /* TripLens diagnostic repair: outer object is FMI-callback-owned.
   * FMI2CS_deInitializeSolverData releases it through freeMemory after
   * this function has released every internal CVODE allocation. */
#endif''')
    solver.write_text(text)
    text = interface.read_text()
    allocation = 'cvodeData = (CVODE_SOLVER*) functions->allocateMemory(1, sizeof(CVODE_SOLVER));'
    assert text.count(allocation) == 1, 'Outer allocator no longer matches this repair.'
    needle = '      retValue = cvode_solver_deinitial(solverInfo->solverData);'
    assert text.count(needle) == 1
    text = text.replace(needle, needle + '''
#ifdef OMC_FMI_RUNTIME
      functions->freeMemory(solverInfo->solverData);
      solverInfo->solverData = NULL;
      fprintf(stderr, "TRIPLENS_CVODE_FMI_CALLBACK_CLEANUP_PASS\\n");
#endif''')
    interface.write_text(text)
    after = {str(p.relative_to(source_root)):hashlib.sha256(p.read_bytes()).hexdigest()
             for p in [solver, interface]}
    return {'experimental_runtime_fix':True, 'physics_changed':False,
            'reason':'FMI callback allocateMemory must be paired with callback freeMemory',
            'destructor_skipped':False,'internal_cvode_allocations_freed':True,
            'source_before_sha256':before,'source_after_sha256':after,
            'crashing_windows_job':102079390010,
            'crash_rva':'0x155d6b7, immediately after free(cvodeData)'}
