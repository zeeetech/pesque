{
  description = "pesque: a minimal, self-hostable ATProto PDS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    beam-overlay.url = "github:zeeetech/beam-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    beam-overlay,
  }: let
    inherit (nixpkgs.lib) genAttrs;
    inherit (nixpkgs.lib.systems) flakeExposed;

    forAllSystems = f:
      genAttrs flakeExposed (system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [beam-overlay.overlays.default];
        };
      in
        f pkgs);
  in {
    # NixOS runs the same pinned OCI image as Docker Compose. The module owns
    # the generated configuration, state and backup mounts, systemd lifecycle,
    # and the configured `pesque` operator command. See nix/module.nix.
    nixosModules = {
      pesque = ./nix/module.nix;
      default = ./nix/module.nix;
    };

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        name = "pesque-dev";

        # Elixir 1.19+ on OTP 28, which is what mix.exs and .tool-versions pin.
        # mkToolchain selects a compatible Elixir and OTP pair.
        packages = with pkgs; [
          (pkgs.beam-overlay.mkToolchain {
            elixir.version = "1.20.4";
          })
          erlang_28
          sqlite
        ];
      };
    });
  };
}
