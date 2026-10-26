#!/bin/bash

set -euo pipefail

RUBY="${RUBY:-ruby}"
STAP_FILE="${STAP_FILE:-/usr/share/doc/ruby-doc/ruby-exercise.stp}"
RUBY_OPTS="--disable-gems"
STAP_OPTS="--suppress-handler-errors"

TMPDIR="$(mktemp -d)"
LOG_FILE="${TMPDIR}/ruby.log"
STAP_OUT="${TMPDIR}/stap-out.log"
touch "${LOG_FILE}"

PASS=0
FAIL=0

run() {
    local desc="$1"
    shift
    echo -n "  ${desc} ... "
    if "$@"; then
        echo "PASS"
        (( PASS++ ))
    else
        echo "FAIL"
        (( FAIL++ ))
    fi
}

cleanup() {
    if [[ -n "${STAP_PID:-}" ]]; then
        kill "${STAP_PID}" 2>/dev/null || true
        sleep 1
        kill -s SIGKILL "${STAP_PID}" 2>/dev/null || true
        pkill stapio 2>/dev/null || true
    fi
    rm -rf "${TMPDIR}"
}
trap cleanup EXIT

echo "=== Setup ==="

if [[ ! -f "${STAP_FILE}" ]]; then
    echo "ERROR: ${STAP_FILE} not found."
    exit 1
fi

if ! ${RUBY} ${RUBY_OPTS} -e '' 2>/dev/null; then
    echo "Cannot use ${RUBY_OPTS} as option for ${RUBY}, removing these options."
    RUBY_OPTS=""
fi

stap_version="$(rpm -qf "$(command -v stap)" --qf '%{version}')"
if [[ "$(printf '%s\n' "4.7" "${stap_version}" | sort -V | head -n1)" == "4.7" ]]; then
    echo "Changing stap buffer size."
    STAP_OPTS="${STAP_OPTS} -s 100"
fi

echo "=== Running systemtap in background ==="
{ stap ${STAP_OPTS} -v "${STAP_FILE}" -o "${LOG_FILE}" |& tee "${STAP_OUT}"; } &
STAP_PID=$!
echo "STAP_PID: ${STAP_PID}"

echo "Waiting for systemtap to start ..."
for i in $(seq 1 60); do
    if grep -q 'starting run' "${STAP_OUT}" 2>/dev/null; then
        break
    fi
    if ! kill -0 "${STAP_PID}" 2>/dev/null; then
        echo "ERROR: stap process exited before starting. Output:"
        cat "${STAP_OUT}" 2>/dev/null
        exit 1
    fi
    sleep 1
done
if ! grep -q 'starting run' "${STAP_OUT}" 2>/dev/null; then
    echo "ERROR: systemtap did not start within 60 seconds."
    exit 1
fi

echo "=== Running ruby interpreter ==="
run "Float test"          ${RUBY} ${RUBY_OPTS} -e '1.0 + 9.0'
run "Array test"          ${RUBY} ${RUBY_OPTS} -e '[1, 2, 3].push(4)'
run "Range test"          ${RUBY} ${RUBY_OPTS} -e '(1..10).step(1)'
run "Hash test"           ${RUBY} ${RUBY_OPTS} -e 'TracePoint.new{}.enable; Hash.new()'
run "String test"         ${RUBY} ${RUBY_OPTS} -e '"abc".slice!("c")'
run "Cycle and print test" ${RUBY} ${RUBY_OPTS} -e 'TracePoint.new{}.enable; 5.times { printf "Ruby!\n" }'

echo "Waiting 10 seconds for output ..."
sleep 10

echo "=== Terminating systemtap ==="
kill "${STAP_PID}" 2>/dev/null || true
sleep 1
kill -s SIGKILL "${STAP_PID}" 2>/dev/null || true
pkill stapio 2>/dev/null || true
unset STAP_PID

echo "=== Log file contents ==="
cat "${LOG_FILE}"

echo "=== Checking systemtap log ==="
run "Array test"                            grep -q 'Array::push'      "${LOG_FILE}"
run "Range test"                            grep -q 'Range::step'      "${LOG_FILE}"
run "Hash test"                             grep -q 'Hash::initialize' "${LOG_FILE}"
run "String test"                           grep -q 'String::slice!'   "${LOG_FILE}"
run "Cycle and print test - iteration number" grep -q 'Integer::times' "${LOG_FILE}"
run "Cycle and print test - printf function"  grep -q 'Kernel::printf' "${LOG_FILE}"
run "Cycle and print test - IO write"         grep -q 'IO::write'      "${LOG_FILE}"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
