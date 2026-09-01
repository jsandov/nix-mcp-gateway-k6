# nix-mcp-gateway-k6

k6 load testing and a Grafana executive dashboard for the MCP Gateway
Registry local stack (deployed by the companion flake,
[nix-mcp-gateway](https://github.com/jsandov/nix-mcp-gateway)).

k6 runs as containers on the stack's compose network, streams metrics into
the stack's own Prometheus (remote write, enabled via a compose override),
and results render live on the auto-provisioned **MCP Gateway · Load &
Reliability** dashboard (`http://localhost:3000/d/mcpgw-exec-load`):
availability, throughput, p95/p99, error rate, and per-journey SLO tiles.

| Command | Profile |
|---|---|
| `mcpgw-k6-smoke` | ~1 min, 3 VUs — pipeline sanity check |
| `mcpgw-k6-load` | ~4.5 min, 12 VUs — sustained realistic traffic |
| `mcpgw-k6-stress` | ~9 min, ramp to 60 VUs — find the local knee |
| `mcpgw-k6-scale1500` | ~12 min — modeled 1,500-user peak hour + 3× burst (open model; `MCPGW_K6_USERS=<n>` rescales) |
| `mcpgw-k6-breakpoint` | ≤8 min — aggregate MCP-call ramp 15→120 req/s, auto-stops at SLO breach |

Traffic model: four journeys tagged as k6 scenarios — dashboard browsing,
agent logins (real OAuth client-credentials against Keycloak), authenticated
registry API reads, and MCP `initialize` + `tools/list` through the gateway
data plane. Open-model profiles run as 4 parallel shard containers because
the gateway's nginx edge-limits 50 r/s per client IP — real user populations
arrive from many IPs. Runs also sample per-container CPU/memory and print the
peaks (the cloud-sizing signal: which service saturates first).

## Use from nix-darwin

```nix
{
  inputs.nix-mcp-gateway-k6.url = "github:jsandov/nix-mcp-gateway-k6";
  inputs.nix-mcp-gateway-k6.inputs.nixpkgs.follows = "nixpkgs";

  imports = [ inputs.nix-mcp-gateway-k6.darwinModules.default ];
  services.mcp-gateway-k6.enable = true;
}
```

## Use from the CLI

```sh
nix run github:jsandov/nix-mcp-gateway-k6#mcpgw-k6-smoke
```

Requires a running stack (`mcpgw-up`, bootstrapped) and docker pointing at
its compose project.
