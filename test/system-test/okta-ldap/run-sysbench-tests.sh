#!/usr/bin/env bash
#
# Sysbench Performance Test via Okta LDAP Authentication
#
# Runs a short oltp_read_write benchmark through ProxySQL using Okta LDAP
# cleartext auth. Validates that performance exceeds 10 queries/sec.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROXYSQL_HOST="${PROXYSQL_HOST:-proxysql}"
PROXYSQL_ADMIN_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_MYSQL_PORT="${PROXYSQL_MYSQL_PORT:-6033}"

ADMIN_USER="${ADMIN_USER:-radmin}"
ADMIN_PASS="${ADMIN_PASS:-radmin}"

OKTA_USER="${OKTA_USER:-tanapoln+test@lmwn.com}"
OKTA_PASS="${OKTA_PASS:-P@ssw0rd}"

# Sysbench parameters
BENCH_TIME=15
BENCH_THREADS=1
BENCH_TABLES=2
BENCH_TABLE_SIZE=1000
BENCH_REPORT_INTERVAL=5
MIN_QPS=10

# Enable cleartext plugin for LDAP auth
export LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1

# Sysbench workload path
SYSBENCH_LUA="/usr/share/sysbench/oltp_read_write.lua"

# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  PASS: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; }
section() { echo ""; echo "======================================================================"; echo "  $1"; echo "======================================================================"; }

run_admin() {
    local output rc=0
    output=$(mysql -h "$PROXYSQL_HOST" -P "$PROXYSQL_ADMIN_PORT" -u "$ADMIN_USER" -p"$ADMIN_PASS" \
        --connect-timeout=10 -N -B -e "$1" 2>&1) || rc=$?
    echo "$output" | grep -v 'mysql: \[Warning\]' || true
    return ${rc}
}

wait_for_port() {
    local host="$1" port="$2" label="$3" max_wait="${4:-60}"
    echo -n "Waiting for ${label} ..."
    local elapsed=0
    while ! (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; do
        sleep 1; elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $max_wait ]]; then echo " TIMEOUT"; return 1; fi
    done
    echo " ready (${elapsed}s)"
}

# Standard user for prepare/cleanup (avoids LDAP connection count)
SYSBENCH_STDUSER=(
    "$SYSBENCH_LUA"
    --mysql-host="$PROXYSQL_HOST"
    --mysql-port="$PROXYSQL_MYSQL_PORT"
    --mysql-user=testuser
    --mysql-password=testpass
    --mysql-db=testdb
    --tables="$BENCH_TABLES"
    --table-size="$BENCH_TABLE_SIZE"
    --threads=1
    --db-driver=mysql
)

# LDAP user for the actual benchmark run
SYSBENCH_LDAP=(
    "$SYSBENCH_LUA"
    --mysql-host="$PROXYSQL_HOST"
    --mysql-port="$PROXYSQL_MYSQL_PORT"
    --mysql-user="$OKTA_USER"
    --mysql-password="$OKTA_PASS"
    --mysql-db=testdb
    --tables="$BENCH_TABLES"
    --table-size="$BENCH_TABLE_SIZE"
    --threads="$BENCH_THREADS"
    --time="$BENCH_TIME"
    --report-interval="$BENCH_REPORT_INTERVAL"
    --db-driver=mysql
)

# ---------------------------------------------------------------------------
section "Phase 0: Wait for services"
# ---------------------------------------------------------------------------
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_ADMIN_PORT" "ProxySQL admin" 60
wait_for_port "$PROXYSQL_HOST" "$PROXYSQL_MYSQL_PORT" "ProxySQL proxy" 60
sleep 3

# ---------------------------------------------------------------------------
section "Phase 1: Configure LDAP"
# ---------------------------------------------------------------------------
echo "  Configuring LDAP variables..."
run_admin "SET ldap-okta_url='ldaps://trial-1120298.ldap.okta.com'" >/dev/null
run_admin "UPDATE global_variables SET variable_value='dc=trial-1120298,dc=okta,dc=com' WHERE variable_name='ldap-okta_base_dn'" >/dev/null
run_admin "SET ldap-okta_bind_timeout_ms=10000" >/dev/null
run_admin "LOAD LDAP VARIABLES TO RUNTIME" >/dev/null
pass "LDAP configured"

# ---------------------------------------------------------------------------
section "Phase 2: Sysbench prepare (create tables via standard auth)"
# ---------------------------------------------------------------------------
echo "  Running sysbench prepare..."
echo "  Config: tables=$BENCH_TABLES, table_size=$BENCH_TABLE_SIZE"
prepare_output=$(sysbench "${SYSBENCH_STDUSER[@]}" prepare 2>&1) || true
if echo "$prepare_output" | grep -q "Creating table\|already exists"; then
    pass "Sysbench tables prepared"
    echo "$prepare_output" | grep -E "Creating|already" | head -5 | sed 's/^/    /'
else
    fail "Sysbench prepare failed" "$prepare_output"
    echo ""; echo "ABORTING: Cannot prepare benchmark tables"; exit 1
fi

# ---------------------------------------------------------------------------
section "Phase 3: Sysbench run via LDAP auth (oltp_read_write, ${BENCH_TIME}s)"
# ---------------------------------------------------------------------------
echo "  Running benchmark: threads=$BENCH_THREADS, time=${BENCH_TIME}s"
echo ""

run_output=$(sysbench "${SYSBENCH_LDAP[@]}" run 2>&1)
echo "$run_output"
echo ""

# ---------------------------------------------------------------------------
section "Phase 4: Parse and validate results"
# ---------------------------------------------------------------------------

# Extract QPS (queries per second)
qps=$(echo "$run_output" | grep -oP 'queries:\s+\d+\s+\(\K[0-9.]+' || echo "0")
if [[ -z "$qps" ]] || [[ "$qps" == "0" ]]; then
    # Try alternative format
    qps=$(echo "$run_output" | grep -oP 'queries per sec\):\s+\K[0-9.]+' || echo "0")
fi
if [[ -z "$qps" ]] || [[ "$qps" == "0" ]]; then
    # Fallback: compute from total queries / time
    total_queries=$(echo "$run_output" | grep -oP 'queries:\s+\K\d+' || echo "0")
    if [[ "$total_queries" -gt 0 ]]; then
        qps=$(echo "scale=2; $total_queries / $BENCH_TIME" | bc 2>/dev/null || echo "0")
    fi
fi

# Extract transactions per second
tps=$(echo "$run_output" | grep -oP 'transactions:\s+\d+\s+\(\K[0-9.]+' || echo "0")

# Extract latency
lat_avg=$(echo "$run_output" | grep -oP 'avg:\s+\K[0-9.]+' || echo "N/A")
lat_p95=$(echo "$run_output" | grep -oP '95th percentile:\s+\K[0-9.]+' || echo "N/A")

echo "  Performance Summary:"
echo "    Queries/sec (QPS):    $qps"
echo "    Transactions/sec:     $tps"
echo "    Avg latency (ms):     $lat_avg"
echo "    P95 latency (ms):     $lat_p95"
echo ""

# Validate QPS threshold
qps_int=$(echo "$qps" | cut -d. -f1)
if [[ -n "$qps_int" ]] && [[ "$qps_int" -ge "$MIN_QPS" ]]; then
    pass "QPS ($qps) exceeds minimum threshold ($MIN_QPS)"
else
    fail "QPS ($qps) is below minimum threshold ($MIN_QPS)" "Expected >= $MIN_QPS queries/sec"
fi

# Validate benchmark actually ran (had transactions)
tps_int=$(echo "$tps" | cut -d. -f1)
if [[ -n "$tps_int" ]] && [[ "$tps_int" -gt 0 ]]; then
    pass "Benchmark completed with $tps TPS"
else
    fail "Benchmark produced zero transactions"
fi

# ---------------------------------------------------------------------------
section "Phase 5: Sysbench cleanup"
# ---------------------------------------------------------------------------
echo "  Cleaning up benchmark tables..."
cleanup_output=$(sysbench "${SYSBENCH_STDUSER[@]}" cleanup 2>&1) || true
if echo "$cleanup_output" | grep -q "Dropping table\|table doesn"; then
    pass "Sysbench tables cleaned up"
else
    echo "  (cleanup output: $cleanup_output)"
fi

# ---------------------------------------------------------------------------
section "Results"
# ---------------------------------------------------------------------------
echo ""
echo "  Total:  $TESTS_RUN"
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
