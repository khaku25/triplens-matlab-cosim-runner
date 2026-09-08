"""Build isolated native-seeded CVODE FMUs; physics is not modified.

CVODE source comes from pinned OMC. An explicitly recorded allocator repair
pairs the FMI-owned outer CVODE structure with the importer's freeMemory.
Build success alone never establishes a simulation result.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import tarfile
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile

MODEL = 'TripLens_CombinedCycle_TripTAC_CoSim'
SEED_SHA = 'b14e9b4fc7269f324b35c2ab79a8bbb048ccad44b5ca359d6e2f58118795ed6c'
SUNDIALS_COMMIT = '84c029fe0b4b3c3bbf5cf8835f5828a6bb98b7a2'
OMC_FILES = {'cvode_solver.c':'e3c773f6c2db6f9473417652cbea903e32243bbb',
             'sundials_error.c':'e1a9db20cdfde55770cfcf2359efcded1f0c6684'}

def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()

def run(args: list[str], log: Path) -> None:
    print('RUN:', ' '.join(map(str,args)), flush=True)
    with log.open('w') as out:
        result = subprocess.run(args, stdout=out, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text(errors='replace')[-20000:], flush=True)
        raise RuntimeError(f'{args[0]} failed ({result.returncode}); see {log}')

def download(url: str, out: Path) -> None:
    req = urllib.request.Request(url, headers={'User-Agent':'TripLens-CVODE-Probe'})
    with urllib.request.urlopen(req, timeout=120) as response:
        out.write_bytes(response.read())

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed-fmu',type=Path,required=True)
    ap.add_argument('--work',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--platform',choices=['linux64','win64'],required=True)
    a = ap.parse_args()
    assert sha(a.seed_fmu)==SEED_SHA, 'Not the tested initializing seed artifact.'
    work=a.work.resolve(); out=a.out.resolve()
    work.mkdir(parents=True,exist_ok=True); out.mkdir(parents=True,exist_ok=True)
    root=work/'fmu'; root.mkdir()
    with zipfile.ZipFile(a.seed_fmu) as z:
        assert all((root/n).resolve().is_relative_to(root) for n in z.namelist())
        z.extractall(root)
    if (root/'binaries').exists(): shutil.rmtree(root/'binaries')
    src=root/'sources'
    generated={p.name:sha(p) for p in src.glob('*.c')}
    preserved={p:sha(src/p) for p in ['tl_native_seed.h','simulation/solver/nonlinearSolverHomotopy.c']}
    for name, blob in OMC_FILES.items():
        p=src/'simulation/solver'/name
        download('https://raw.githubusercontent.com/OpenModelica/OpenModelica/v1.27.0/OMCompiler/SimulationRuntime/c/simulation/solver/'+name,p)
        b=p.read_bytes()
        assert hashlib.sha1(b'blob '+str(len(b)).encode()+b'\0'+b).hexdigest()==blob, 'OMC runtime revision mismatch'
    allocator_fix=runpy.run_path(str(Path(__file__).resolve().parents[1]/'cvode_allocator_fix.py'))['apply'](src)
    (out/'allocator_fix.json').write_text(json.dumps(allocator_fix,indent=2))
    # Prove which solver was selected at runtime, not only linked into the DLL.
    p=src/'fmi-export/fmu_read_flags.c'; text=p.read_text()
    needle='  comp->solverInfo = solverInfo;'
    assert text.count(needle)==1
    p.write_text(text.replace(needle,'  fprintf(stderr, "TRIPLENS_FMI_INTERNAL_SOLVER=%s\\n", SOLVER_METHOD_NAME[solverInfo->solverMethod]);\n'+needle))
    (root/'resources'/f'{MODEL}_flags.json').write_text(json.dumps({'s':'cvode'},indent=2)+'\n')
    p=root/'modelDescription.xml'; text=p.read_text(); old=ET.fromstring(text).get('guid')
    new='{'+str(uuid.uuid5(uuid.NAMESPACE_URL,SEED_SHA+'-cvode-v2-callback-free'))+'}'
    p.write_text(text.replace(old,new))
    for p in src.rglob('*'):
        if p.is_file() and p.suffix in {'.c','.h'}:
            b=p.read_bytes()
            if old.encode() in b: p.write_bytes(b.replace(old.encode(),new.encode()))
    with zipfile.ZipFile(a.seed_fmu) as z:
        for name in generated:
            assert (src/name).read_bytes().replace(new.encode(),old.encode())==z.read('sources/'+name)
    for name,value in preserved.items(): assert sha(src/name)==value
    archive=work/'sundials.tar.gz'
    download(f'https://codeload.github.com/LLNL/sundials/tar.gz/{SUNDIALS_COMMIT}',archive)
    with tarfile.open(archive) as tar: tar.extractall(work,filter='data')
    sundials=work/f'sundials-{SUNDIALS_COMMIT}'
    prefix=work/'sundials-install'; sb=work/'sundials-build'
    cross=[]
    if a.platform=='win64':
        cross=['-DCMAKE_SYSTEM_NAME=Windows','-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc','-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++']
    config=['cmake','-S',str(sundials),'-B',str(sb),'-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
        '-DCMAKE_INSTALL_PREFIX='+str(prefix),'-DBUILD_SHARED_LIBS=OFF','-DBUILD_STATIC_LIBS=ON',
        '-DBUILD_ARKODE=OFF','-DBUILD_CVODE=ON','-DBUILD_CVODES=OFF','-DBUILD_IDA=OFF',
        '-DBUILD_IDAS=OFF','-DBUILD_KINSOL=OFF','-DEXAMPLES_ENABLE_C=OFF',
        '-DEXAMPLES_ENABLE_CXX=OFF','-DEXAMPLES_INSTALL=OFF']+cross
    run(config,out/'sundials-configure.log')
    run(['cmake','--build',str(sb),'--parallel','4'],out/'sundials-build.log')
    run(['cmake','--install',str(sb)],out/'sundials-install.log')
    libs=list((prefix/'lib').glob('libsundials*.a'))+list((prefix/'lib64').glob('libsundials*.a'))
    assert any('cvode' in p.name for p in libs) and any('nvecserial' in p.name for p in libs)
    project=work/'compile'; project.mkdir()
    cmake='''cmake_minimum_required(VERSION 3.16)
project(TripLensCVODE C)
set(CMAKE_C_STANDARD 99)
file(GLOB_RECURSE MODEL_SOURCES "${FMU_SOURCE}/*.c")
file(GLOB INCLUDE_ONLY "${FMU_SOURCE}/*_info.c")
if(INCLUDE_ONLY)
  list(REMOVE_ITEM MODEL_SOURCES ${INCLUDE_ONLY})
endif()
add_library(triplens_cvode SHARED ${MODEL_SOURCES})
set_target_properties(triplens_cvode PROPERTIES PREFIX "" OUTPUT_NAME "TripLens_CombinedCycle_TripTAC_CoSim")
target_compile_definitions(triplens_cvode PRIVATE OMC_MINIMAL_RUNTIME=1 OMC_FMI_RUNTIME=1 CMINPACK_NO_DLL WITH_SUNDIALS LINK_SUNDIALS_STATIC FMI2_OVERRIDE_FUNCTION_PREFIX)
target_include_directories(triplens_cvode PRIVATE "${FMU_SOURCE}" "${FMU_SOURCE}/fmi" "${SUNDIALS_PREFIX}/include")
foreach(source ${MODEL_SOURCES})
  get_filename_component(folder "${source}" DIRECTORY)
  target_include_directories(triplens_cvode PRIVATE "${folder}")
endforeach()
file(GLOB SD_LIBS "${SUNDIALS_PREFIX}/lib/libsundials*.a" "${SUNDIALS_PREFIX}/lib64/libsundials*.a")
target_link_libraries(triplens_cvode PRIVATE "-Wl,--start-group" ${SD_LIBS} "-Wl,--end-group" m)
target_link_options(triplens_cvode PRIVATE "-Wl,--no-undefined")
if(WIN32)
  target_link_options(triplens_cvode PRIVATE -static -static-libgcc)
else()
  find_package(Threads REQUIRED)
  target_compile_definitions(triplens_cvode PRIVATE OM_HAVE_PTHREADS)
  target_link_libraries(triplens_cvode PRIVATE Threads::Threads)
endif()
'''
    (project/'CMakeLists.txt').write_text(cmake)
    mb=work/'model-build'
    run(['cmake','-S',str(project),'-B',str(mb),'-DCMAKE_BUILD_TYPE=Release',
         '-DFMU_SOURCE='+str(src),'-DSUNDIALS_PREFIX='+str(prefix)]+cross,out/'fmu-configure.log')
    run(['cmake','--build',str(mb),'--parallel','4'],out/'fmu-build.log')
    ext='.dll' if a.platform=='win64' else '.so'
    binary=mb/(MODEL+ext); assert binary.is_file()
    bindir=root/'binaries'/a.platform; bindir.mkdir(parents=True)
    shutil.copy2(binary,bindir/binary.name)
    if a.platform=='win64':
        run(['x86_64-w64-mingw32-objdump','-p',str(binary)],out/'binary-imports.log')
        imports=(out/'binary-imports.log').read_text()
        assert 'cvode' not in '\n'.join(x for x in imports.splitlines() if 'DLL Name:' in x).lower()
    else:
        run(['ldd',str(binary)],out/'binary-imports.log')
    manifest={'diagnostic_only':True,'platform':a.platform,'seed_sha256':SEED_SHA,
        'native_state_capture_run':34220970632,'native_seed_source_run':34226155354,
        'guid':new,'integrator':'CVODE','sundials_version':'5.4.0','sundials_commit':SUNDIALS_COMMIT,
        'omc_runtime_version':'1.27.0','added_omc_source_blobs':OMC_FILES,
        'sundials_static_linked':True,'generated_equations_unchanged':True,
        'native_seed_and_previous_runtime_correction_unchanged':True,
        'physical_assertions_retained':True,'simulation_pass':False,
        'allocator_fix':allocator_fix,'binary_sha256':sha(binary),'required_environment':
        ['TRIPLENS_USE_NATIVE_SEED=1','TRIPLENS_RETAIN_VALIDATED_NLS_GUESS=1']}
    (root/'resources'/'cvode_build_manifest.json').write_text(json.dumps(manifest,indent=2))
    fmu=out/(MODEL+'_'+a.platform+'.fmu')
    with zipfile.ZipFile(fmu,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(root.rglob('*')):
            if p.is_file(): z.write(p,p.relative_to(root).as_posix())
    manifest['fmu_sha256']=sha(fmu)
    (out/'cvode_build_manifest.json').write_text(json.dumps(manifest,indent=2))
    print(json.dumps(manifest,indent=2),flush=True)
    print('CVODE_BINARY_BUILT_SIMULATION_NOT_YET_VERIFIED',flush=True)

if __name__=='__main__': main()
