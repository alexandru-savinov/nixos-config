# sancta-choir: the two walls around n8n (studio slice 1, sq085).
#
# The shared module (modules/services/n8n.nix) stays neutral on purpose:
# rpi5-full really does hand n8n model keys. On choir n8n is only the
# conductor of the production chain (trigger, DAG, history) and must never
# call a model or hold a model key, and it must never listen anywhere but
# loopback (reached from the tailnet through `tailscale serve`).
#
# Both walls are evaluation-time assertions, UNCONDITIONAL — they hold
# whether or not sancta.studio.n8n.enable is on, so the rule is already in
# force before n8n ever runs here. Each has a negative arm pinned in
# tests/module-eval.nix (studio-n8n-*): adding a model key, a public port or
# a non-loopback listen address makes evaluation fail with the messages below.
{ config, lib, ... }:
let
  cfg = config.services.n8n-tailscale;
  unit = config.systemd.services.n8n or { };
  unitEnv = unit.environment or { };
  serviceConfig = unit.serviceConfig or { };
  fw = config.networking.firewall;

  # Environment variable names that carry a model-provider credential.
  # Matched on whole underscore-separated words, case-insensitively.
  modelVendors = "OPENROUTER|OPENAI|ANTHROPIC|CLAUDE|GEMINI|GOOGLE|VERTEX|MISTRAL|GROQ|COHERE|DEEPSEEK|XAI|GROK|PERPLEXITY|TOGETHER|FIREWORKS|HUGGINGFACE|HF|REPLICATE|OLLAMA|AZURE_OPENAI|BEDROCK|JEV";
  # Fail closed for vendors not in the list: any credential-shaped name is
  # refused too. n8n's own secret (N8N_ENCRYPTION_KEY) never passes through
  # these attrsets; the wrapper writes it into /run/n8n/env from the file.
  credentialShaped = ".*(API_?KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS?)";
  isModelKeyName = name:
    let upper = lib.toUpper name; in
    builtins.match "(.*_)?(${modelVendors})(_.*)?" upper != null
    || builtins.match credentialShaped upper != null;

  envNames = builtins.attrNames cfg.extraEnvironment ++ builtins.attrNames unitEnv;
  modelKeyEnvNames = builtins.filter isModelKeyName envNames;

  # The wrapper's only EnvironmentFile is the one its root ExecStartPre
  # writes from the typed options above; anything else is a side door.
  envFiles = lib.toList (serviceConfig.EnvironmentFile or [ ]);
  extraEnvFiles = builtins.filter (f: f != "-/run/n8n/env") envFiles;
  credentialKeys = builtins.filter (k: serviceConfig ? ${k})
    [ "LoadCredential" "LoadCredentialEncrypted" "SetCredential" "SetCredentialEncrypted" ];

  # Ports that would put n8n (or its serve front) on a non-tailnet interface.
  n8nPorts = lib.unique [ cfg.port cfg.tailscaleServe.httpsPort ];
  inRanges = ranges: port: lib.any (r: r.from <= port && port <= r.to) ranges;
  opensPort = rules: port:
    builtins.elem port (rules.allowedTCPPorts or [ ])
    || inRanges (rules.allowedTCPPortRanges or [ ]) port;
  untrustedInterfaces = lib.filterAttrs
    (name: _: !(builtins.elem name ([ "lo" "tailscale0" ] ++ fw.trustedInterfaces)))
    fw.interfaces;
  openedPorts = builtins.filter
    (port: opensPort fw port || lib.any (rules: opensPort rules port) (builtins.attrValues untrustedInterfaces))
    n8nPorts;

  loopback = "127.0.0.1";
  listenAddresses = lib.filter (a: a != null) [
    (unitEnv.N8N_LISTEN_ADDRESS or null)
    (cfg.extraEnvironment.N8N_LISTEN_ADDRESS or null)
    (config.services.n8n.environment.N8N_LISTEN_ADDRESS or null)
  ];
  nonLoopbackListen = builtins.filter (a: a != loopback) listenAddresses;
in
{
  imports = [ ../../modules/services/n8n.nix ];

  assertions = [
    {
      assertion = cfg.openrouterApiKeyFile == null
        && cfg.openaiApiKeyFile == null
        && cfg.credentialsFile == null
        && modelKeyEnvNames == [ ]
        && extraEnvFiles == [ ]
        && credentialKeys == [ ];
      message = ''
        choir-n8n: n8n on sancta-choir may not hold any model key (sq085, capability #11).
          openrouterApiKeyFile = ${toString cfg.openrouterApiKeyFile}
          openaiApiKeyFile     = ${toString cfg.openaiApiKeyFile}
          credentialsFile      = ${toString cfg.credentialsFile}
          model-key or credential-shaped env names = ${builtins.toJSON modelKeyEnvNames}
          extra EnvironmentFile = ${builtins.toJSON extraEnvFiles}
          systemd credentials  = ${builtins.toJSON credentialKeys}
        n8n is the conductor, never a model caller; see hosts/sancta-choir/n8n-guard.nix.
      '';
    }
    {
      assertion = !config.services.n8n.openFirewall
        && openedPorts == [ ]
        && nonLoopbackListen == [ ]
        # The native module binds every interface by default; only the
        # wrapper pins N8N_LISTEN_ADDRESS to loopback.
        && (!config.services.n8n.enable || cfg.enable);
      message = ''
        choir-n8n: n8n on sancta-choir must listen on 127.0.0.1 only and be reached through tailscale serve.
          services.n8n.openFirewall = ${lib.boolToString config.services.n8n.openFirewall}
          n8n ports opened outside tailscale0/lo = ${builtins.toJSON openedPorts}
          non-loopback N8N_LISTEN_ADDRESS = ${builtins.toJSON nonLoopbackListen}
          native services.n8n without the services.n8n-tailscale wrapper = ${lib.boolToString (config.services.n8n.enable && !cfg.enable)}
      '';
    }
  ];
}
