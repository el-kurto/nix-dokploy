# Docker stack configuration for Dokploy
{ cfg, lib }:
{
  version = "3.8";

  services = {
    postgres = {
      image = "postgres:16";
      environment = {
        POSTGRES_USER = "dokploy";
        POSTGRES_PASSWORD = "\${POSTGRES_PASSWORD}";
        POSTGRES_DB = "dokploy";
      };
      volumes = [
        "dokploy-postgres-database:/var/lib/postgresql/data"
      ];
      networks = {
        dokploy-network = {
          aliases = ["dokploy-postgres"];
        };
      };
      deploy = {
        placement.constraints = ["node.role == manager"];
        restart_policy.condition = "any";
      };
    };

    redis = {
      image = "redis:7";
      volumes = [
        "redis-data-volume:/data"
      ];
      networks = {
        dokploy-network = {
          aliases = ["dokploy-redis"];
        };
      };
      deploy = {
        placement.constraints = ["node.role == manager"];
        restart_policy.condition = "any";
      };
    };

    dokploy = {
      image = cfg.image;
      environment = {
        ADVERTISE_ADDR = "\${ADVERTISE_ADDR}";
      } // cfg.environment;
      networks = {
        dokploy-network = {
          aliases = ["dokploy-app"];
        };
      };
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "${cfg.dataDir}:/etc/dokploy"
        "dokploy-docker-config:/root/.docker"
      ];
      depends_on = ["postgres" "redis"];
      deploy = {
        replicas = 1;
        placement.constraints = ["node.role == manager"];
        update_config = {
          parallelism = 1;
          order = "stop-first";
        };
        restart_policy.condition = "any";
      };
    } // lib.optionalAttrs (cfg.port != null) {
      ports = [ cfg.port ];
    };
  };

  networks = {
    dokploy-network = {
      name = "dokploy-network";
      driver = "overlay";
      attachable = true;
    };
  };

  volumes = {
    dokploy-postgres-database = {};
    redis-data-volume = {};
    dokploy-docker-config = {};
  };
}