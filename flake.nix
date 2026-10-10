{
  description = "pesque: a minimal, self-hostable ATProto PDS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    elixir-overlay.url = "github:zoedsoupe/elixir-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    elixir-overlay,
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
  in {
    # The release, built from source. `nix build .#pesque` produces a runnable
    # bin/pesque; `services.pesque` below uses the same derivation.
    packages = forAllSystems (pkgs: {
      pesque = pkgs.callPackage ./nix/package.nix {};
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.pesque;
    });

    # Runs it as a systemd service, no container runtime, plus the doctor,
    # account and migrate oneshots. See nix/module.nix.
    nixosModules = {
      pesque = import ./nix/module.nix;
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
        ];
      };
    });
  };
}
