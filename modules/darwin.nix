{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mcp-gateway-k6;

  scripts = import ./scripts.nix {
    inherit pkgs self;
    workDirDefault = cfg.workDir;
  };
in
{
  options.services.mcp-gateway-k6 = {
    enable = lib.mkEnableOption "k6 load testing tooling for the MCP Gateway Registry local stack (mcpgw-k6-* scripts)";

    workDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/mcp-gateway-registry";
      description = ''
        The gateway stack's working clone (as deployed by nix-mcp-gateway's
        mcpgw-install). Shell-expanded at runtime; override per-invocation
        with MCPGW_WORKDIR. Keep it in sync with services.mcp-gateway.workDir.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = builtins.attrValues scripts;
  };
}
