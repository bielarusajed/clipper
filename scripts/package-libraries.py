#!/usr/bin/env python3
"""Bundle the transitive dylib graph and remove all build-machine load paths."""
import pathlib
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
frameworks = app / 'Contents/Frameworks'
roots = [app / 'Contents/MacOS/Clipper', app / 'Contents/Helpers/ffmpeg', app / 'Contents/Helpers/ffprobe']
source_lib = pathlib.Path.cwd() / '.build/media/lib'
queue = list(roots)
visited = set()
def output(*args):
    return subprocess.check_output(args, text=True)
while queue:
    binary = queue.pop(0)
    if binary in visited:
        continue
    visited.add(binary)
    subprocess.run(['chmod', 'u+w', str(binary)], check=True)
    dependencies = [line.strip().split(' (')[0] for line in output('otool', '-L', str(binary)).splitlines()[1:]]
    for dependency in dependencies:
        if dependency.startswith(('/System/', '/usr/lib/')):
            continue
        name = pathlib.Path(dependency).name
        if dependency.startswith('@rpath/'):
            source = source_lib / name
            if not source.exists():
                source = frameworks / name
        elif dependency.startswith('@loader_path/'):
            source = binary.parent / dependency.removeprefix('@loader_path/')
        elif dependency.startswith('@executable_path/'):
            continue
        else:
            source = pathlib.Path(dependency)
        destination = frameworks / name
        if not destination.exists():
            if not source.exists():
                raise SystemExit(f'Cannot resolve {dependency} needed by {binary}')
            shutil.copy2(source.resolve(), destination)
            queue.append(destination)
        replacement = '@loader_path/' + name if binary.parent == frameworks else '@loader_path/../Frameworks/' + name
        subprocess.run(['install_name_tool', '-change', dependency, replacement, str(binary)], check=True)
    if binary.parent == frameworks:
        subprocess.run(['install_name_tool', '-id', '@rpath/' + binary.name, str(binary)], check=True)
    # Strip the absolute build-tree rpath, keeping only bundle-relative dependencies.
    lines = output('otool', '-l', str(binary)).splitlines()
    for n,line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            path = lines[n+2].strip().split('path ',1)[1].split(' (offset')[0]
            if path.startswith('/'):
                subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
