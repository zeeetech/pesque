{
  description = "pesque: a minimal, self-hostable ATProto PDS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    elixir-overlay.url = "github:zoedsoupe/elixir-overlay";
    # Pinned Zig toolchains. nixpkgs' zig tracks the channel and can lag the
    # CLI's minimum_zig_version, so the CLI build takes its zig from here.
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    elixir-overlay,
    zig-overlay,
  }: let
    inherit (nixpkgs.lib) genAttrs;
    inherit (nixpkgs.lib.systems) flakeExposed;

    forAllSystems = f:
      genAttrs flakeExposed (system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [elixir-overlay.overlays.default];
        };
      in
        f pkgs);

    # The zig the CLI is built with. Bump it when cli/.zig-version moves.
    zig = system: zig-overlay.packages.${system}."0.17.0";
  in {
    # The release, built from source. `nix build .#pesque` produces a runnable
    # bin/pesque; `services.pesque` below uses the same derivation.
    #
    # `pesque-cli` is the host-side operator CLI, the same binary the releases
    # publish. `services.pesque` puts it on PATH when the module is enabled.
    packages = forAllSystems (pkgs: {
      pesque = pkgs.callPackage ./nix/package.nix {};
      pesque-cli = pkgs.callPackage ./nix/cli.nix {
        zig = zig pkgs.stdenv.hostPlatform.system;
      };
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.pesque;
    });

    # Runs it as a systemd service, no container runtime, plus the doctor,
    # account, migrate and backup oneshots and the host-side CLI on PATH. See
    # nix/module.nix.
    nixosModules = {
      pesque = {
        pkgs,
        lib,
        ...
      }: {
        imports = [ ./nix/module.nix ];
        services.pesque.cli = {
          enable = lib.mkDefault true;
          package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.pesque-cli;
        };
      };
      default = self.nixosModules.pesque;
    };

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "pesque-dev";

        # Elixir 1.19+ on OTP 28, which is what mix.exs and .tool-versions pin.
        # elixir-with-otp pairs the two so the Elixir build targets this OTP.
        packages = with pkgs; [
          (elixir-with-otp erlang_28).latest
          erlang_28
          sqlite
          (zig pkgs.stdenv.hostPlatform.system)
        ];
      };
    });
  };
}
