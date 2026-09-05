#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/tests
swiftc -warnings-as-errors src/PipeCore.swift tests/main.swift -o .build/tests/profiles
.build/tests/profiles
swiftc -warnings-as-errors src/PipeCore.swift src/SSHController.swift tests/ssh/main.swift -o .build/tests/ssh
.build/tests/ssh
./build.sh
if [ "${1:-}" = "--live" ]; then
    swiftc -warnings-as-errors src/PipeCore.swift src/PipeController.swift src/SSHController.swift \
        tests/runtime/main.swift -o .build/tests/runtime
    PIPEDESK_RUNTIME_TEST_BIN="$PWD/.build/tests/runtime" python3 tests/live-pipe.py
fi
