#!/usr/bin/env python3
"""Build zimg's arm64 source set without requiring system Autotools."""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess

root = pathlib.Path.cwd()
source = root / '.build/vendor/zimg-release-3.0.6/src/zimg'
objects = root / '.build/vendor/zimg-objects'
prefix = root / '.build/media'
objects.mkdir(parents=True, exist_ok=True)
clang = subprocess.check_output(['xcrun', '--find', 'clang++'], text=True).strip()
sdk = os.environ['SDKROOT']
files = [p for p in source.rglob('*.cpp') if 'x86' not in p.parts]
def compile_one(path):
    obj = objects / (str(path.relative_to(source)).replace('/', '_') + '.o')
    subprocess.run([clang, '-std=c++11', '-O2', '-DNDEBUG', '-DZIMG_ARM', '-fPIC',
                    '-mmacosx-version-min=14.0', '-isysroot', sdk, '-I'+str(source),
                    '-c', str(path), '-o', str(obj)], check=True)
    return str(obj)
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    built = list(pool.map(compile_one, files))
subprocess.run([clang, '-dynamiclib', '-mmacosx-version-min=14.0', '-isysroot', sdk,
                '-install_name', str(prefix/'lib/libzimg.2.dylib'),
                '-compatibility_version', '3.0.0', '-current_version', '3.0.6',
                '-o', str(prefix/'lib/libzimg.2.dylib'), *built], check=True)
link = prefix/'lib/libzimg.dylib'
link.unlink(missing_ok=True)
link.symlink_to('libzimg.2.dylib')
for name in ['zimg.h', 'zimg++.hpp']:
    shutil.copy2(source/'api'/name, prefix/'include'/name)
