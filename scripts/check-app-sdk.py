#!/usr/bin/env python3
"""Reject a binary whose linked SDK would opt AppKit into an older appearance."""
import re
import subprocess
import sys


def version(value):
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


binary, expected, minimum = sys.argv[1:]
metadata = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
sdks = re.findall(r'^\s+sdk\s+([0-9.]+)\s*$', metadata, re.MULTILINE)
if not sdks or any(version(sdk) != version(expected) for sdk in sdks):
    sys.exit(f'Linked SDK mismatch in {binary}: expected {expected}, found {sdks}. '
             'Check the SwiftPM build engine; do not ship an older AppKit appearance.')
print(f'Linked SDK verified: {expected}')
minimums = re.findall(r'^\s+minos\s+([0-9.]+)\s*$', metadata, re.MULTILINE)
if len(minimums) != len(sdks) or any(version(value) != version(minimum) for value in minimums):
    sys.exit(f'Deployment target mismatch in {binary}: expected {minimum}, found {minimums}.')
print(f'Deployment target verified: {minimum}')
