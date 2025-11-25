{ pkgs ? import <nixpkgs> { }
,
}:

pkgs.testers.nixosTest {
  name = "open-webui-tavily-test";
  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ ../modules/services/open-webui.nix ];

      # Mock secrets
      environment.etc."tavily-key".text = "mock-tavily-key";

      # Enable the module
      services.open-webui-tailscale = {
        enable = true;
        host = "0.0.0.0";
        tavilySearch = {
          enable = true;
          apiKeyFile = "/etc/tavily-key";
        };
        # Disable tailscale integration for this test
        tailscaleServe.enable = false;
        oidc.enable = false;
      };

      networking.firewall.allowedTCPPorts = [ 8080 ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("open-webui.service")

    # Wait a bit for the process to fully start and load envs
    machine.sleep(5)

    # Get the MainPID
    pid = machine.succeed("systemctl show --property MainPID --value open-webui.service").strip()

    # Debug: print the environment
    print(machine.succeed(f"cat /proc/{pid}/environ | tr '\\0' '\\n'"))

    # Check RAG env vars
    machine.succeed(f"grep -z 'ENABLE_RAG_WEB_SEARCH=True' /proc/{pid}/environ")
    machine.succeed(f"grep -z 'RAG_WEB_SEARCH_ENGINE=tavily' /proc/{pid}/environ")

    # Check that TAVILY_API_KEY is loaded
    machine.succeed(f"grep -z 'TAVILY_API_KEY=mock-tavily-key' /proc/{pid}/environ")
  '';
}
