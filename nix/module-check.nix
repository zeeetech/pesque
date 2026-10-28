{
  nixpkgs,
  module,
}:
let
  system = "x86_64-linux";
  evaluated = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      module
      {
        system.stateVersion = "26.05";
        services.pesque = {
          enable = true;
          image = "ghcr.io/zeeetech/pesque:1.14.2";
          publicUrl = "https://pds.example.com";
          mode = "multi";
          handleDomain = "example.com";
          uid = 33333;
          gid = 33333;
          requiredMounts = [ "/var/lib/pesque" ];
          settings.blob_upload_limit = "104857600";
        };
      }
    ];
  };
  config = evaluated.config;
  container = config.virtualisation.oci-containers.containers.pesque;
in
{
  wrapper =
    nixpkgs.lib.findFirst (package: nixpkgs.lib.getName package == "pesque")
      (throw "the pesque operator wrapper is missing from environment.systemPackages")
      config.environment.systemPackages;
  result =
    assert config.virtualisation.oci-containers.backend == "docker";
    assert config.virtualisation.docker.enable;
    assert container.serviceName == "pesque";
    assert container.entrypoint == "/app/bin/server";
    assert container.cmd == [ ];
    assert container.user == "33333:33333";
    assert container.environment.PDS_CONFIG == "/data/pesque.conf";
    assert container.ports == [ "127.0.0.1:4000:4000" ];
    assert builtins.elem "/var/lib/pesque:/data" container.volumes;
    assert builtins.elem "/var/lib/pesque/backups:/backups" container.volumes;
    assert !(container.environment ? PDS_DATA_DIR);
    assert !(container.environment ? PDS_SERVE);
    assert config.users.users.pesque.uid == 33333;
    assert config.users.groups.pesque.gid == 33333;
    assert config.systemd.services.pesque-backup.serviceConfig.Type == "oneshot";
    assert nixpkgs.lib.hasInfix "mountpoint -q /var/lib/pesque" config.systemd.services.pesque.preStart;
    assert !(config.systemd.services ? pesque-account);
    assert !(config.systemd.services ? pesque-doctor);
    assert !(config.systemd.services ? pesque-migrate);
      "nixos module check passed";
}
