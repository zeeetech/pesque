{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pesque;
  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    types
    optional
    concatStringsSep
    mapAttrsToList
    escapeShellArg
    ;

  confLines =
    [
      "public_url = ${cfg.publicUrl}"
      "mode = ${cfg.mode}"
      "registration = ${cfg.registration}"
      "port = ${toString cfg.port}"
      "data_dir = /data"
    ]
    ++ optional (cfg.handleDomain != null) "handle_domain = ${cfg.handleDomain}"
    ++ optional (cfg.crawler != [ ]) "crawler = ${concatStringsSep "," cfg.crawler}"
    ++ mapAttrsToList (key: value: "${key} = ${value}") cfg.settings;

  confFile = pkgs.writeText "pesque.conf" (concatStringsSep "\n" confLines + "\n");

  deploymentKeys = [
    "public_url"
    "port"
    "data_dir"
    "mode"
    "handle_domain"
    "registration"
    "crawler"
  ];
  collisions = builtins.filter (key: builtins.hasAttr key cfg.settings) deploymentKeys;

  userSpec = "${toString config.users.users.pesque.uid}:${toString config.users.groups.pesque.gid}";
  imageName = lib.last (lib.splitString "/" cfg.image);
  imagePinned = (lib.hasInfix ":" imageName) && !(lib.hasSuffix ":latest" cfg.image);
  requiredMounts = cfg.requiredMounts ++ [
    cfg.dataDir
    cfg.backupDir
  ];

  storageCommands = concatStringsSep "\n" (
    map (path: "  require_mount ${escapeShellArg (toString path)}") cfg.requiredMounts
  );
  storagePreStart = concatStringsSep "\n" (
    map (path: ''
      if ! ${pkgs.util-linux}/bin/mountpoint -q ${escapeShellArg (toString path)}; then
        echo "required mount is not available: ${toString path}" >&2
        exit 1
      fi
    '') cfg.requiredMounts
  );

  operator = pkgs.writeShellApplication {
    name = "pesque";
    runtimeInputs = [
      config.virtualisation.docker.package
      config.systemd.package
      pkgs.util-linux
    ];
    text = lib.replaceStrings
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
        (escapeShellArg cfg.image)
        (escapeShellArg "pesque")
        (escapeShellArg "pesque")
        (escapeShellArg cfg.dataDir)
        (escapeShellArg confFile)
        (escapeShellArg cfg.backupDir)
        (escapeShellArg userSpec)
        storageCommands
      ]
      (builtins.readFile ./operator.sh);
  };
in
{
  options.services.pesque = {
    enable = mkEnableOption "pesque, a self-hostable ATProto PDS";

    image = mkOption {
      type = types.str;
      example = "ghcr.io/zeeetech/pesque:1.14.2";
      description = ''
        The shared Pesque OCI image. Select an explicit release tag or digest;
        `latest` is refused so a NixOS rebuild cannot silently change servers.
      '';
    };

    publicUrl = mkOption {
      type = types.str;
      example = "https://pds.example.com";
      description = ''
        Public origin clients reach this server at: scheme, hostname and the
        advertised port. Drives the DID, DID document and every advertised URL.
        TLS terminates at your proxy; this is the name it answers for.
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
      default = [ ];
      example = [ "https://bsky.network" ];
      description = "Relays to announce this server to at boot.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = ''
        Port the process binds and the container port published on the host.
        Behind a proxy this is the internal port; the advertised port is in
        publicUrl.
      '';
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Host address the container port is published on. Loopback is the safe
        default because a TLS proxy is expected on the same host.
      '';
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        blob_upload_limit = "104857600";
        admin_dids = "did:plc:...,did:plc:...";
      };
      description = ''
        Uncommon application settings, written verbatim to the generated
        pesque.conf. The keys the module owns (public_url, mode,
        handle_domain, registration, crawler, port and data_dir) are refused
        here. See the configuration reference in docs/installation.md.
      '';
    };

    uid = mkOption {
      type = types.int;
      example = 33333;
      description = ''
        Stable host UID shared by the service user and the container. Set this
        to the current data owner when adopting an existing installation. The
        module never changes ownership of existing state.
      '';
    };

    gid = mkOption {
      type = types.int;
      example = 33333;
      description = ''
        Stable host GID shared by the service group and the container. Set this
        to the current data group when adopting an existing installation.
      '';
    };

    requiredMounts = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/var/lib/pesque" ];
      description = ''
        Paths that must already be mountpoints before the service or a one-off
        command uses the data. Set this for datasets that could otherwise be
        hidden by an empty directory, such as a ZFS dataset. No automatic mount
        or ownership changes are performed.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/pesque";
      description = ''
        Host directory holding the entire server state, mounted at /data. This
        is the host storage path; the container's own data_dir is always /data.
      '';
    };

    backupDir = mkOption {
      type = types.path;
      default = "${cfg.dataDir}/backups";
      defaultText = lib.literalExpression ''"''${config.services.pesque.dataDir}/backups"'';
      description = "Host directory for backup archives, mounted at /backups.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = imagePinned;
        message = "services.pesque.image must select an explicit release tag or digest, not latest.";
      }
      {
        assertion = cfg.publicUrl != "";
        message = "services.pesque.publicUrl is required.";
      }
      {
        assertion = collisions == [ ];
        message = "services.pesque.settings must not set module-owned keys: ${concatStringsSep ", " collisions}.";
      }
    ];

    users.users.pesque = {
      isSystemUser = true;
      group = "pesque";
      uid = cfg.uid;
      home = cfg.dataDir;
      description = "pesque ATProto PDS";
    };
    users.groups.pesque.gid = cfg.gid;

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 pesque pesque -"
      "d '${cfg.backupDir}' 0700 pesque pesque -"
    ];

    virtualisation.docker.enable = lib.mkDefault true;
    virtualisation.oci-containers.backend = "docker";
    virtualisation.oci-containers.containers.pesque = {
      image = cfg.image;
      serviceName = "pesque";
      entrypoint = "/app/bin/pesque";
      cmd = [ "start" ];
      user = userSpec;
      workdir = "/data";
      environment = {
        PDS_CONFIG = "/data/pesque.conf";
        HOME = "/data";
      };
      volumes = [
        "${cfg.dataDir}:/data"
        "${confFile}:/data/pesque.conf:ro"
        "${cfg.backupDir}:/backups"
      ];
      ports = [ "${cfg.listenAddress}:${toString cfg.port}:${toString cfg.port}" ];
      log-driver = "journald";
      pull = "missing";
    };

    systemd.services.pesque = {
      unitConfig.RequiresMountsFor = lib.unique requiredMounts;
      preStart = storagePreStart;
    };

    systemd.services.pesque-backup = {
      description = "Pesque backup";
      unitConfig.RequiresMountsFor = lib.unique requiredMounts;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${operator}/bin/pesque backup";
      };
    };

    environment.systemPackages = [ operator ];
  };
}
