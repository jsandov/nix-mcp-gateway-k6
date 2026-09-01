# Shared script derivations used by both:
#   - the darwin module (installed into environment.systemPackages)
#   - the flake's apps + packages outputs (for `nix run` / `nix shell`)
#
# k6 load testing for a running MCP Gateway Registry local stack (deployed by
# the companion flake, nix-mcp-gateway). k6 runs as a container on the compose
# network (no host install, and the nix store isn't visible inside the Colima
# VM — the script is fed on stdin). Metrics stream into the stack's own
# Prometheus via remote write and render on the auto-provisioned
# "MCP Gateway · Load & Reliability" Grafana dashboard.

{ pkgs
, self
, workDirDefault ? "$HOME/mcp-gateway-registry"
}:

let
  k6Script = "${self}/assets/k6-gateway.js";
  k6Dashboard = "${self}/assets/exec-load-dashboard.json";
  k6PromOverride = "${self}/assets/k6-prometheus-override.yml";
  # Superset override for hosts where nix-mcp-gateway's mcpgw-up installed
  # its SVE mitigation (Apple M4/M5 under vz): Prometheus remote-write PLUS
  # the mcpgw-sve env vars, so layering k6 in never drops them.
  k6PromSveOverride = "${self}/assets/k6-prometheus-sve-override.yml";
  k6Image = "grafana/k6:1.4.0";

  mkScript = name: text: pkgs.writeShellApplication {
    inherit name text;
    runtimeInputs = with pkgs; [ docker curl jq coreutils gnused gnugrep gawk ];
  };

  # Open-model profiles run as N parallel k6 containers: nginx edge-limits
  # 50r/s per client IP, and real user populations arrive from many IPs.
  # Each shard gets its own container IP and carries 1/N of the traffic.
  k6ShardsFor = profile:
    if profile == "scale1500" || profile == "breakpoint" then 4 else 1;

  mkK6Runner = profile: ''
    WORKDIR="''${MCPGW_WORKDIR:-${workDirDefault}}"
    cd "$WORKDIR"

    if ! curl -fsS -o /dev/null --max-time 5 http://localhost/health; then
      echo "Gateway is not responding at http://localhost — run mcpgw-up first." >&2
      exit 1
    fi

    # Provision/refresh the exec dashboard. The dashboards dir is
    # bind-mounted into Grafana, which rescans it every 10s.
    install -m 644 ${k6Dashboard} config/grafana/dashboards/mcpgw-exec-load.json

    # Prometheus must accept remote writes from k6. Upstream doesn't enable
    # the receiver, so layer it in via compose override (a supported
    # extension point — build_and_run.sh picks the file up on later runs).
    rw_enabled() {
      curl -s http://localhost:9090/api/v1/status/flags \
        | grep -q '"web.enable-remote-write-receiver": *"true"'
    }
    if ! rw_enabled; then
      # Files carrying an mcpgw marker are ours to manage (mcpgw-k6: this
      # flake; mcpgw-sve: nix-mcp-gateway's SVE mitigation) — anything else
      # is user-authored and must not be clobbered.
      if [ -f docker-compose.override.yml ] && ! grep -qE 'mcpgw-(k6|sve)' docker-compose.override.yml; then
        echo "A docker-compose.override.yml exists that mcpgw-k6 didn't create." >&2
        echo "Add '--web.enable-remote-write-receiver' to its prometheus command, then re-run." >&2
        exit 1
      fi
      echo "==> Enabling Prometheus remote-write receiver (one-time stack tweak)"
      # Preserve nix-mcp-gateway's SVE mitigation if mcpgw-up installed it:
      # both flakes manage this file, so pick the superset asset whenever
      # the existing override carries the mcpgw-sve marker.
      if [ -f docker-compose.override.yml ] && grep -q 'mcpgw-sve' docker-compose.override.yml; then
        install -m 644 ${k6PromSveOverride} docker-compose.override.yml
      else
        install -m 644 ${k6PromOverride} docker-compose.override.yml
      fi
      docker compose -f docker-compose.prebuilt.yml -f docker-compose.override.yml up -d prometheus
      for _ in $(seq 1 30); do
        rw_enabled && break
        sleep 2
      done
      rw_enabled || { echo "Prometheus did not come back with the receiver enabled." >&2; exit 1; }
    fi

    CLIENT_SECRET="$(grep '^KEYCLOAK_M2M_CLIENT_SECRET=' .env | cut -d= -f2-)"
    TESTID="$(date +%Y%m%d-%H%M%S)-${profile}"
    NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' \
      "$(docker compose -f docker-compose.prebuilt.yml ps -q registry)")"

    echo "==> k6 '${profile}' run starting (testid: $TESTID)"
    echo "    Watch live: http://localhost:3000/d/mcpgw-exec-load"
    echo

    # Sample per-container CPU/memory during the run: which service
    # saturates first is the signal that drives cloud sizing decisions.
    STATS_FILE="$(mktemp -t mcpgw-k6-stats.XXXXXX)"
    (
      while :; do
        docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' >> "$STATS_FILE" 2>/dev/null
        sleep 15
      done
    ) &
    SAMPLER=$!
    trap 'kill "$SAMPLER" 2>/dev/null || true' EXIT

    # Launch the shard containers in parallel (SHARDS=1 degrades to a single
    # foreground-equivalent run). All shards share one testid so Prometheus
    # and the dashboard aggregate them as a single test.
    SHARDS=${toString (k6ShardsFor profile)}
    SHARD_DIR="$(mktemp -d -t mcpgw-k6-shards.XXXXXX)"
    SHARD_PIDS=()
    for i in $(seq 1 "$SHARDS"); do
      (
        docker run --rm -i --network "$NET" \
          -e BASE_URL=http://registry:8080 \
          -e KEYCLOAK_URL=http://keycloak:8080 \
          -e CLIENT_SECRET="$CLIENT_SECRET" \
          -e PROFILE=${profile} \
          -e USERS="''${MCPGW_K6_USERS:-1500}" \
          -e SHARDS="$SHARDS" \
          -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write \
          -e K6_PROMETHEUS_RW_TREND_STATS='p(50),p(95),p(99)' \
          ${k6Image} run --tag testid="$TESTID" -o experimental-prometheus-rw - \
          < ${k6Script} > "$SHARD_DIR/shard-$i.log" 2>&1
        echo $? > "$SHARD_DIR/shard-$i.rc"
      ) &
      SHARD_PIDS+=("$!")
    done
    # Wait for the shard subshells only — a bare `wait` would also block on
    # the stats-sampler loop forever. Subshells always exit 0 (the k6 exit
    # code lands in the .rc file), so set -e is safe here.
    for pid in "''${SHARD_PIDS[@]}"; do
      wait "$pid"
    done

    FAILED_SHARDS=0
    for i in $(seq 1 "$SHARDS"); do
      rc="$(cat "$SHARD_DIR/shard-$i.rc" 2>/dev/null || echo 1)"
      [ "$rc" = "0" ] || FAILED_SHARDS=$((FAILED_SHARDS + 1))
    done
    # Show one shard's k6 summary (they are structurally identical slices).
    sed -n '/TOTAL RESULTS/,$p' "$SHARD_DIR/shard-1.log" | head -40 || true
    rm -rf "$SHARD_DIR"

    if [ "$FAILED_SHARDS" = "0" ]; then
      echo
      echo "✓ '${profile}' run passed all thresholds ($SHARDS shard(s))."
    else
      echo
      echo "⚠ '${profile}' run: $FAILED_SHARDS of $SHARDS shard(s) reported threshold breaches or errors."
    fi

    # Aggregate summary across all shards, straight from Prometheus.
    echo
    echo "  Aggregate results (all shards, testid $TESTID):"
    promq() {
      curl -s --get http://localhost:9090/api/v1/query --data-urlencode "query=$1" \
        | jq -r '.data.result[] | ((.metric.scenario // "total") + " " + .value[1])'
    }
    promq "sum(k6_http_reqs_total{testid=\"$TESTID\"})" \
      | awk '{printf "    requests total:    %d\n", $2}'
    promq "sum(k6_http_reqs_total{testid=\"$TESTID\",expected_response=\"false\"}) or vector(0)" \
      | awk '{printf "    requests failed:   %d\n", $2}'
    promq "max by (scenario)(k6_http_req_duration_p95{testid=\"$TESTID\"})" \
      | awk '{printf "    p95 %-18s %.0f ms\n", $1 ":", $2 * 1000}'

    kill "$SAMPLER" 2>/dev/null || true
    if [ -s "$STATS_FILE" ]; then
      echo
      echo "  Peak container usage during the run (sizing signal):"
      awk -F, '
        { pct = $2; gsub(/%/, "", pct);
          if (pct + 0 > peak[$1] + 0) { peak[$1] = pct; mem[$1] = $3 } }
        END { for (c in peak) printf "%8.1f%%  %-44s %s\n", peak[c], c, mem[c] }
      ' "$STATS_FILE" | sort -rn | head -8
    fi
    rm -f "$STATS_FILE"

    echo
    echo "  Dashboard: http://localhost:3000/d/mcpgw-exec-load  (Test run filter: $TESTID)"
    echo "  Grafana login: admin / GRAFANA_ADMIN_PASSWORD in ~/.config/secrets/mcp-gateway-credentials"
  '';
in
{
  # Closed-model profiles (VU envelopes):
  # smoke  ~1 min, 3 VUs      — sanity check that the pipeline works
  # load   ~4.5 min, 12 VUs   — sustained realistic traffic
  # stress ~9 min, up to 60   — find the local knee (one 8GB VM; not a DDoS)
  mcpgw-k6-smoke = mkScript "mcpgw-k6-smoke" (mkK6Runner "smoke");
  mcpgw-k6-load = mkScript "mcpgw-k6-load" (mkK6Runner "load");
  mcpgw-k6-stress = mkScript "mcpgw-k6-stress" (mkK6Runner "stress");

  # Open-model (arrival-rate) profiles for capacity planning, sharded across
  # 4 containers (nginx edge-limits 50r/s per client IP):
  # scale1500  ~12 min — simulates a 1,500-user production peak hour
  #            (150 active: 120 agents + 30 humans) with a 3x burst phase;
  #            MCPGW_K6_USERS=<n> rescales the model linearly.
  # breakpoint ~8 min max — climbs aggregate MCP tool-call rate 15→120 req/s
  #            until the SLO breaks, then stops; the last healthy step is
  #            this hardware's per-instance data-plane capacity.
  mcpgw-k6-scale1500 = mkScript "mcpgw-k6-scale1500" (mkK6Runner "scale1500");
  mcpgw-k6-breakpoint = mkScript "mcpgw-k6-breakpoint" (mkK6Runner "breakpoint");
}
