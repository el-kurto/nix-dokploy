{
  nixpkgs,
  module,
  pkgs,
}: let
  inherit (nixpkgs) lib;

  evalPort = port: hostPortMode: let
    sys = lib.nixosSystem {
      modules = [
        module
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          virtualisation.docker.enable = true;
          services.dokploy = {
            enable = true;
            inherit port hostPortMode;
          };
          system.stateVersion = "25.05";
        }
      ];
    };
    cfg = sys.config.services.dokploy;
    rejected = lib.any (a: !a.assertion && lib.hasPrefix "services.dokploy.port" a.message) sys.config.assertions;
  in
    if rejected
    then "rejected"
    else (import ../dokploy-stack.nix {inherit cfg lib;}).services.dokploy.ports or null;

  cases = [
    {
      port = "3000:3000";
      hostPortMode = false;
      expected = ["3000:3000"];
    }
    {
      port = "8080:3000";
      hostPortMode = true;
      expected = [
        {
          mode = "host";
          published = 8080;
          target = 3000;
        }
      ];
    }
    {
      port = null;
      hostPortMode = false;
      expected = null;
    }
    {
      port = "3000";
      hostPortMode = false;
      expected = "rejected";
    }
    {
      port = "127.0.0.1:3000:3000";
      hostPortMode = false;
      expected = "rejected";
    }
    {
      port = "127.0.0.1:3000:3000";
      hostPortMode = true;
      expected = "rejected";
    }
    {
      port = "3000:3000/udp";
      hostPortMode = true;
      expected = "rejected";
    }
  ];

  failures =
    builtins.filter (c: c.actual != c.expected)
    (map (c: c // {actual = evalPort c.port c.hostPortMode;}) cases);
in
  if failures == []
  then pkgs.runCommand "port-check" {} ''mkdir -p "$out"''
  else throw "port check failed: ${builtins.toJSON failures}"
