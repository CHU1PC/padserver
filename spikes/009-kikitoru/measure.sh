#!/bin/sh
# usage: measure.sh <compose dir> <起動の繰り返し回数> <要求の回数>   (guest の中で実行する)
# compose.yaml と seed.sql が <compose dir> にある. 時刻は /proc/uptime (秒, 小数2桁) で測る.
set -eu
DIR=$1
RUNS=$2
REQS=$3
cd "$DIR"
P=$(basename "$DIR")
now() { cut -d' ' -f1 /proc/uptime; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }
mem() { free -m | awk '/^Mem:/ { print "used=" $3 "MiB free=" $4 "MiB buff/cache=" $6 "MiB available=" $7 "MiB" }'; }

# pass: 起動の測定を1回行う. db と backend が先に上がる順に, 各段階の経過秒を出す.
cold_start() {
  docker compose down -v >/dev/null 2>&1
  sleep 5
  echo "mem idle (stack down): $(mem)"
  t0=$(now)
  docker compose up -d >/dev/null 2>&1 &
  upid=$!
  db_t=""; mig_t=""; be_t=""; wk_t=""
  while :; do
    [ -z "$db_t" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$P-db-1" 2>/dev/null)" = healthy ] && db_t=$(since "$t0")
    [ -z "$mig_t" ] && [ "$(docker inspect -f '{{.State.Status}}/{{.State.ExitCode}}' "$P-migrate-1" 2>/dev/null)" = exited/0 ] && mig_t=$(since "$t0")
    if [ -z "$be_t" ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8000/api/v1/summaries 2>/dev/null || true)
      [ "$code" = 401 ] && be_t=$(since "$t0")
    fi
    [ -z "$wk_t" ] && [ "$(docker inspect -f '{{.State.Status}}' "$P-worker-1" 2>/dev/null)" = running ] && wk_t=$(since "$t0")
    [ -n "$be_t" ] && [ -n "$wk_t" ] && [ -n "$db_t" ] && [ -n "$mig_t" ] && break
    [ "$(awk -v a="$t0" -v b="$(now)" 'BEGIN { print (b - a > 900) }')" = 1 ] && { echo "timeout"; break; }
    sleep 0.5
  done
  wait "$upid" || true
  echo "db_healthy=${db_t}s migrate_done=${mig_t}s backend_first_401=${be_t}s worker_running=${wk_t}s"
}

i=1
while [ "$i" -le "$RUNS" ]; do
  echo "== cold start #$i"
  cold_start
  i=$((i + 1))
done

echo "== state after the last start"
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'
echo "mem after start: $(mem)"

echo "== seed"
docker compose exec -T db psql -U postgres -d kikitoru -q < seed.sql

echo "== requests ($REQS each, sequential, from inside the guest)"
req() { # $1 label, rest curl args
  label=$1; shift
  out=$(j=0; while [ "$j" -lt "$REQS" ]; do curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$@"; j=$((j + 1)); done)
  echo "$label first: $(echo "$out" | head -1)"
  echo "$out" | awk '{ print $1 }' | sort | uniq -c | awk -v l="$label" 'BEGIN { printf "%s codes:", l } { printf " %s x%s", $2, $1 } END { printf "\n" }'
  echo "$out" | awk '{ print $2 }' | sort -n | awk -v l="$label" '{ t[NR] = $1 } END { printf "%s time_total min=%.3f median=%.3f max=%.3f (n=%d)\n", l, t[1], t[int((NR + 1) / 2)], t[NR], NR }'
}
req "no-db  GET /api/v1/summaries (no cookie)" http://127.0.0.1:8000/api/v1/summaries
req "db     GET /auth/me (cookie)" -H 'Cookie: session_token=spike-token' http://127.0.0.1:8000/auth/me
req "db     GET /api/v1/summaries (cookie)" -H 'Cookie: session_token=spike-token' http://127.0.0.1:8000/api/v1/summaries
echo "mem after requests: $(mem)"

echo "== docker stats"
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
