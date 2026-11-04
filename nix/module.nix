{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pesque;
  container = config.services.beam.containers.pesque;
  inherit
    (lib)
    mkIf
    mkOption
    types
    optional
    concatStringsSep
    mapAttrsToList
    escapeShellArg
    ;

  confLines =
    [
      "url_scheme = ${cfg.scheme}"
      "hostname = ${cfg.hostname}"
      "port = ${toString container.port}"
      "data_dir = /data"
      "mode = ${cfg.mode}"
      "registration = ${cfg.registration}"
    ]
    ++ optional (cfg.handleDomain != null) "handle_domain = ${cfg.handleDomain}"
    ++ optional (cfg.crawler != []) "crawler = ${concatStringsSep "," cfg.crawler}"
    ++ mapAttrsToList (key: value: "${key} = ${value}") cfg.settings;

  confFile = pkgs.writeText "pesque.conf" (concatStringsSep "\n" confLines + "\n");

  deploymentKeys = [
    "url_scheme"
    "hostname"
    "port"
    "data_dir"
    "mode"
    "handle_domain"
    "registration"
    "crawler"
  ];
  collisions = builtins.filter (key: builtins.hasAttr key cfg.settings) deploymentKeys;

  userSpec = "${toString container.uid}:${toString container.gid}";
  requiredMounts =
    container.requiredMounts
    ++ [
      container.dataDir
      cfg.backupDir
    ];

  storageCommands = concatStringsSep "\n" (
    map (path: "  require_mount ${escapeShellArg (toString path)}") container.requiredMounts
  );

  operator = pkgs.writeShellApplication {
    name = "pesque";
    runtimeInputs = [
      config.virtualisation.docker.package
      config.systemd.package
      pkgs.util-linux
    ];
    text =
      lib.replaceStrings
      [
        "@IMAGE@"
        "@CONTAINER@"
        "@SERVICE@"
        "@DATA_DIR@"
        "@CONFIG_FILE@"
        "@BACKUP_DIR@"
        "@USER_SPEC@"
        "@STORAGE_CHECKS@"
      ]
      [
        (escapeShellArg container.image)
        (escapeShellArg "pesque")
        (escapeShellArg "pesque")
        (escapeShellArg container.dataDir)
        (escapeShellArg confFile)
        (escapeShellArg cfg.backupDir)
        (escapeShellArg userSpec)
        storageCommands
      ]
      (builtins.readFile ./operator.sh);
  };
in {
  options.services.pesque = {
    hostname = mkOption {
      type = types.str;
      example = "pds.example.com";
      description = ''
        Public origin clients reach this server at. Drives the DID, DID document and every advertised URL.
        TLS terminates at your proxy; this is the name it answers for.
      '';
    };

    scheme = mkOption {
      type = types.enum ["http" "https"];
      example = "https";
      description = ''
        The desired URL scheme
      '';
    };

    mode = mkOption {
      type = types.enum [
        "single"
        "multi"
      ];
      default = "single";
      description = ''
        single serves one account as the server itself. multi gives every
        account its own handle and DID.
      '';
    };

    handleDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = "The domain accounts get handles under. Defaults to the public hostname.";
    };

    registration = mkOption {
      type = types.enum [
        "open"
        "closed"
      ];
      default = "closed";
      description = "open lets anyone create an account; closed needs an invite code.";
    };

    crawler = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["https://bsky.network"];
      description = "Relays to announce this server to at boot.";
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {
        blob_upload_limit = "104857600";
        admin_dids = "did:plc:...,did:plc:...";
      };
      description = ''
        Uncommon application settings, written verbatim to the generated
        pesque.conf. The keys the module owns (url_scheme, hostname, port,
        data_dir, mode, handle_domain, registration and crawler) are refused
        here. See the configuration reference in docs/installation.md.
      '';
    };

    backupDir = mkOption {
      type = types.path;
      default = "${container.dataDir}/backups";
      defaultText = lib.literalExpression ''"''${config.services.beam.containers.pesque.dataDir}/backups"'';
      description = "Host directory for backup archives, mounted at /backups.";
    };
  };

  config = lib.mkMerge [
    {
      services.beam.containers.pesque = {
        entrypoint = "/app/bin/server";
        cmd = [];
        environment.PDS_CONFIG = "/data/pesque.conf";
        volumes = [
          "${confFile}:/data/pesque.conf:ro"
          "${cfg.backupDir}:/backups"
        ];
      };
    }
    (mkIf container.enable {
      assertions = [
        {
          assertion = container.port != null;
          message = "services.beam.containers.pesque.port must be set.";
        }
        {
          assertion = collisions == [];
          message = "services.pesque.settings must not set module-owned keys: ${concatStringsSep ", " collisions}.";
        }
      ];

      systemd.tmpfiles.rules = [
        "d '${cfg.backupDir}' 0700 pesque pesque -"
      ];

      systemd.services.pesque-backup = {
        description = "Pesque backup";
        unitConfig.RequiresMountsFor = lib.unique requiredMounts;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${operator}/bin/pesque backup";
        };
      };

      environment.systemPackages = [operator];
    })
  ];
}
