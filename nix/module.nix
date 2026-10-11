# A NixOS module that runs pesque as a plain systemd service from a release
# built in Nix, with no container runtime. The configuration is written to a
# pesque.conf in the store and pointed at with PDS_CONFIG, the same file the
# server reads in every other deployment.
#
# The one-off operator tasks (doctor, account, migrate, backup) are declared
# as oneshot units that run the release verbs against the same data directory:
#
#   systemctl start pesque-doctor
#   systemctl start pesque-account    # reads /var/lib/pesque/account.env
#   systemctl start pesque-migrate    # reads /var/lib/pesque/migrate.env
#   systemctl start pesque-backup     # writes pesque-backup-<stamp>.tar.gz
#                                     # into the data directory
#
# The account and migrate env files keep the password out of the Nix store;
# create them with `install -m600 /dev/null /var/lib/pesque/account.env` and
# fill in ACCOUNT_HANDLE, ACCOUNT_EMAIL and ACCOUNT_PASSWORD (or the
# MIGRATE_OLD_PDS, MIGRATE_HANDLE, MIGRATE_EMAIL, MIGRATE_PASSWORD set).
#
# The move stops at the PLC step for a code the account holder gets by email.
# A oneshot has no terminal to prompt on, so pesque-migrate is run twice: the
# first start asks the old PDS to email the code, then MIGRATE_PLC_TOKEN is set
# in migrate.env and the second start completes the move.
#
# There is deliberately no pesque-restore unit: a restore swaps the data
# directory in place, so it wants the server stopped and an archive path, not
# a unit. Stop pesque and run the verb by hand as the pesque user, pointing
# PDS_CONFIG at the same conf the service runs (`systemctl cat pesque` shows
# both store paths).
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
    ;

  confLines =
    [
      "hostname = ${cfg.hostname}"
      "mode = ${cfg.mode}"
      "registration = ${cfg.registration}"
      "port = ${toString cfg.port}"
      "data_dir = ${cfg.dataDir}"
    ]
    ++ optional (cfg.identity != null) "identity = ${cfg.identity}"
    ++ optional (cfg.handleDomain != null) "handle_domain = ${cfg.handleDomain}"
    ++ optional (cfg.handle != null) "handle = ${cfg.handle}"
    ++ optional (cfg.crawler != [ ]) "crawler = ${concatStringsSep "," cfg.crawler}"
    ++ optional (cfg.urlScheme != null) "url_scheme = ${cfg.urlScheme}"
    ++ optional (cfg.urlPort != null) "url_port = ${toString cfg.urlPort}"
    ++ optional (cfg.plcDirectory != null) "plc_directory = ${cfg.plcDirectory}"
    ++ optional (cfg.blobUploadLimit != null) "blob_upload_limit = ${toString cfg.blobUploadLimit}"
    ++ optional (cfg.repoImportLimit != null) "repo_import_limit = ${toString cfg.repoImportLimit}"
    ++ optional (cfg.adminDids != [ ]) "admin_dids = ${concatStringsSep "," cfg.adminDids}"
    ++ optional (cfg.privacyPolicyUrl != null) "privacy_policy_url = ${cfg.privacyPolicyUrl}"
    ++ optional (cfg.termsOfServiceUrl != null) "terms_of_service_url = ${cfg.termsOfServiceUrl}"
    ++ mapAttrsToList (key: value: "${key} = ${value}") cfg.settings;

  confFile = pkgs.writeText "pesque.conf" (concatStringsSep "\n" confLines + "\n");

  # A one-off task: the same release, the same config and data directory, the
  # endpoint off so it does not fight the running server for the port. The
  # verbs read their input from the environment, so an env file is all the
  # wiring a headless run needs.
  taskService =
    { exec, environmentFiles ? [ ] }:
    {
      description = "pesque one-off task";
      # The data directory is often its own mount (a ZFS dataset, a separate
      # disk); wait for it rather than writing to the empty mountpoint on root.
      unitConfig.RequiresMountsFor = [ cfg.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "pesque";
        Group = "pesque";
        WorkingDirectory = cfg.dataDir;
        Environment = [
          "PDS_CONFIG=${confFile}"
          "PDS_SERVE=false"
        ];
        EnvironmentFile = environmentFiles;
        ExecStart = "${cfg.package}/bin/pesque ${exec}";
        ReadWritePaths = [ cfg.dataDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
in
{
  options.services.pesque = {
    enable = mkEnableOption "pesque, a self-hostable ATProto PDS";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The pesque release to run.";
    };

    hostname = mkOption {
      type = types.str;
      example = "pds.example.com";
      description = ''
        Public hostname. Drives the DID, the DID document and every advertised
        URL, so it must be the name clients reach the server at, TLS included.
      '';
    };

    mode = mkOption {
      type = types.enum [
        "conformant_single"
        "path_multi"
      ];
      default = "conformant_single";
      description = ''
        conformant_single serves one account as the server itself. path_multi
        gives every account its own handle and DID.
      '';
    };

    identity = mkOption {
      type = types.nullOr (
        types.enum [
          "web"
          "plc"
        ]
      );
      default = null;
      description = ''
        The DID method. Derived from the mode when unset: plc under path_multi,
        web under conformant_single.
      '';
    };

    handleDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "example.com";
      description = "The domain accounts get handles under. Defaults to the hostname.";
    };

    handle = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The handle the server publishes under conformant_single. Defaults to the hostname.";
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
      description = "Port the process binds. Behind a proxy, this is the internal port.";
    };

    urlScheme = mkOption {
      type = types.nullOr (
        types.enum [
          "http"
          "https"
        ]
      );
      default = null;
      description = "What the server tells the world to fetch. Defaults to https.";
    };

    urlPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "The advertised port. Defaults to 443 for https.";
    };

    plcDirectory = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://plc.directory";
      description = "PLC directory, read only when identity = plc.";
    };

    blobUploadLimit = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Largest blob uploadBlob accepts, in bytes.";
    };

    repoImportLimit = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Largest importRepo body, in bytes.";
    };

    adminDids = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra DIDs allowed to call createInviteCodes under path_multi.";
    };

    privacyPolicyUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Advertised by describeServer as the privacy policy.";
    };

    termsOfServiceUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Advertised by describeServer as the terms of service.";
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { proxy_timeout = "30000"; };
      description = ''
        Extra pesque.conf keys, written verbatim. The key is the variable
        without the PDS_ prefix, lowercased; an unknown key fails boot.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/pesque";
      description = "Directory holding the entire server state: database, keys, blobs.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the port in the firewall. Off by default: a federating server sits
        behind a TLS proxy, so the only thing that should reach this port is the
        proxy on the loopback or the private interface.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.pesque = {
      isSystemUser = true;
      group = "pesque";
      home = cfg.dataDir;
      description = "pesque ATProto PDS";
    };
    users.groups.pesque = { };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 pesque pesque -"
    ];

    systemd.services.pesque = {
      description = "pesque ATProto PDS";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # The data directory is often its own mount (a ZFS dataset, a separate
      # disk); wait for it rather than writing to the empty mountpoint on root.
      unitConfig.RequiresMountsFor = [ cfg.dataDir ];

      environment.PDS_CONFIG = confFile;

      serviceConfig = {
        Type = "exec";
        User = "pesque";
        Group = "pesque";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/bin/pesque start";
        Restart = "on-failure";
        RestartSec = 5;
        # bin/pesque start is a clean SIGTERM: the endpoint drains and the
        # in-flight commit finishes, so give it room before SIGKILL.
        KillSignal = "SIGTERM";
        TimeoutStopSec = 30;

        # The firehose holds a socket per subscriber; the default soft limit is
        # low for a server whose whole job is long-lived connections.
        LimitNOFILE = 65536;

        # Hardening. MemoryDenyWriteExecute is left off: the BEAM's JIT needs
        # writable and executable memory.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    systemd.services.pesque-doctor = taskService { exec = "doctor"; };

    systemd.services.pesque-account = taskService {
      exec = "account create";
      environmentFiles = [ "-${cfg.dataDir}/account.env" ];
    };

    systemd.services.pesque-migrate = taskService {
      exec = "migrate";
      environmentFiles = [ "-${cfg.dataDir}/migrate.env" ];
    };

    systemd.services.pesque-backup = taskService { exec = "backup"; };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
