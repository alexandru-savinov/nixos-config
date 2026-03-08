{ pkgs, ... }:

{
  # GitHub Copilot CLI MCP Server Configuration
  home-manager.users.root = {
    home.file.".copilot/mcp-config.json".text = builtins.toJSON {
      mcpServers = {
        context7 = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [ "-y" "@upstash/context7-mcp" ];
          tools = [ "resolve-library-id" "get-library-docs" ];
        };
      };
    };
  };
}
