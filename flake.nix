{
  description = "k6 load testing + Grafana exec dashboard for the MCP Gateway Registry local stack (companion to nix-mcp-gateway)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.05-darwin";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };

      scriptsFor = system:
        import ./modules/scripts.nix { pkgs = pkgsFor system; inherit self; };

      toolset = system:
        (pkgsFor system).buildEnv {
          name = "mcp-gateway-k6-toolset";
          paths = builtins.attrValues (scriptsFor system);
        };
    in
    {
      # ---------- Module (nix-darwin consumers) ----------
      darwinModules.default = import ./modules/darwin.nix { inherit self; };

      # ---------- Library export ----------
      lib.scripts = { pkgs, workDirDefault ? "$HOME/mcp-gateway-registry" }:
        import ./modules/scripts.nix { inherit pkgs self workDirDefault; };

      # ---------- CLI surface ----------
      packages = forAllSystems (system: {
        default = toolset system;
        mcp-gateway-k6-toolset = toolset system;
      });

      # `nix run github:jsandov/nix-mcp-gateway-k6#mcpgw-k6-smoke` (etc.)
      apps = forAllSystems (system:
        let
          scripts = scriptsFor system;
          mkApp = name: { type = "app"; program = "${scripts.${name}}/bin/${name}"; };
        in {
          mcpgw-k6-smoke = mkApp "mcpgw-k6-smoke";
          mcpgw-k6-load = mkApp "mcpgw-k6-load";
          mcpgw-k6-stress = mkApp "mcpgw-k6-stress";
          mcpgw-k6-scale1500 = mkApp "mcpgw-k6-scale1500";
          mcpgw-k6-breakpoint = mkApp "mcpgw-k6-breakpoint";
          default = mkApp "mcpgw-k6-smoke";
        });
    };
}
