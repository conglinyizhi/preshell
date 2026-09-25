#!/usr/bin/env python3
"""Run the repository's CI engine locally.

The check workflow delegates all orchestration to tools/ci/check.mbtx. This
wrapper keeps the old convenient command and forwards optional step filters to
the same mbtx script instead of maintaining a second YAML interpreter.
"""
import subprocess
import sys


def main():
    wanted = sys.argv[1:]
    command = [
        "moon",
        "run",
        "--target",
        "native",
        "tools/ci/check.mbtx",
        "--",
        *wanted,
    ]
    result = subprocess.run(command)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
