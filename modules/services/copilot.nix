{ config, pkgs, lib, ... }:

{
  # GitHub Copilot CLI MCP Server Configuration
  home-manager.users.root = {
    # MCP configuration file for GitHub Copilot CLI
    home.file.".copilot/mcp-config.json".text = builtins.toJSON {
      mcpServers = {
        context7 = {
          command = "${pkgs.nodejs}/bin/npx";
          args = [ "-y" "@context7/mcp-server" ];
          tools = [ ];
        };
      };
    };
  };
}
