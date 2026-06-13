#!/usr/bin/env bash
#
# Runs every test_*.sh in this directory, each in its own process (so no shell
# state leaks between them) against the shared ProxySQL + OpenLDAP stack. Each
# test resets ProxySQL to a known baseline in setup/teardown, so order does not
# matter. Exits non-zero if any test script fails.
#
# Run the whole suite:   bash run-all.sh
# Run one test directly: bash test_05_conn_counter.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "Waiting for the ProxySQL stack ..."
okta_wait_for_services 180 || { echo "FATAL: ProxySQL not reachable"; exit 1; }
sleep 3

total=0; failed=0; failed_list=""
for t in "$SCRIPT_DIR"/test_*.sh; do
    name="$(basename "$t")"
    echo
    echo "######################## RUN  $name ########################"
    if bash "$t"; then
        echo "######################## PASS $name ########################"
    else
        echo "######################## FAIL $name ########################"
        failed=$((failed+1)); failed_list="$failed_list $name"
    fi
    total=$((total+1))
done

echo
echo "===================================================================="
echo "  SUITE SUMMARY: $((total-failed))/$total test scripts passed"
echo "===================================================================="
if [[ $failed -eq 0 ]]; then
    echo "ALL TEST SCRIPTS PASSED"
    exit 0
else
    echo "FAILED TEST SCRIPTS:$failed_list"
    exit 1
fi
