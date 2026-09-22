# Read-only Gatus views of the existing public Vigil contracts. No extra probes
# or alerts: each endpoint reads one completed, freshness-checked snapshot.
{ lib }:
{ group, address, directory, port ? 8747 }:
let
  schema = import ./vigil-schema.nix { inherit lib; };
  files = builtins.filter (name: lib.hasSuffix ".toml" name) (builtins.attrNames (builtins.readDir directory));
  contracts = map (name: schema.parse (directory + "/${name}")) files;
  labels = {
    build-volume = "Build volume mounted";
    channel = "Telegram channel";
    choir-host = "Choir reachable";
    choir-tick = "Choir monitoring freshness";
    disk-root = "Root disk capacity";
    galeria = "Gallery HTTP";
    ha-alive = "Home Assistant local HTTP";
    ha-served = "Home Assistant tailnet HTTP";
    membrana = "Membrane listener";
    rpi5-host = "rpi5 reachable";
    rpi5-tick = "rpi5 monitoring freshness";
    soul-mirror = "Soul backup freshness";
    soul-mirror-pull = "Soul backup pull freshness";
    tailscaled = "Tailscale service";
  };
in
lib.listToAttrs (map
  (contract: {
    name = "${group}-vigil-${contract.nume}";
    value = {
      name = "Vigil: ${labels.${contract.nume} or contract.nume}";
      inherit group;
      url = "http://${address}:${toString port}/checks/${contract.nume}";
      interval = "1m";
      # Failed equality conditions retain the resolved diagnostic in Gatus 5.31.
      conditions = [ "[STATUS] == 200" "[BODY].stare == verde" "[BODY].detail == ok" ];
    };
  })
  contracts)
