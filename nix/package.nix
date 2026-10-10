# The pesque release, built from source with the beam toolchain nixpkgs ships.
#
# pesque needs Elixir 1.19+ and nixpkgs' default beam scope is 1.18, so the
# scope's elixir is swapped for elixir_1_20, which is built against the same
# OTP. Everything else in the scope (hex, rebar3, mixRelease, fetchMixDeps)
# stays consistent because they all read `elixir` from the same scope.
{
  lib,
  beamPackages,
  openssl,
  sqlite,
  pkg-config,
}:

let
  packages = beamPackages.overrideScope (
    _final: prev: {
      # 1.20 is the newest the scope carries; 1.19 satisfies mix.exs too, so
      # fall back to it on a nixpkgs that predates 1.20.
      elixir = if prev ? elixir_1_20 then prev.elixir_1_20 else prev.elixir_1_19;
    }
  );

  # Read the version from mix.exs so release-please's bump is the only place it
  # lives. A miss falls back to 0.0.0 rather than failing the eval.
  version =
    let
      line = lib.findFirst (l: lib.hasInfix "version:" l) "" (lib.splitString "\n" (builtins.readFile ../mix.exs));
      matched = builtins.match ".*\"([^\"]+)\".*" line;
    in
    if matched == null then "0.0.0" else builtins.head matched;

  # Only what mix needs to build: the flake's own source, minus the state and
  # build directories a working checkout carries.
  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: _type:
      let
        base = baseNameOf (toString path);
      in
      !(builtins.elem base [
        "_build"
        "deps"
        "data"
        "tmp"
        ".git"
        ".expert"
      ]);
  };
in
packages.mixRelease {
  pname = "pesque";
  inherit version src;

  # One fixed-output derivation for the hex deps, pinned by hash. Bumping
  # mix.lock changes the hash; rebuild and copy the one the mismatch prints.
  mixFodDeps = packages.fetchMixDeps {
    pname = "pesque-deps";
    inherit version src;
    hash = "sha256-Mh7mjLCgod1I8jfG2L1xo614eGwFEwNhtDDmr0NKXww=";
  };

  nativeBuildInputs = [ pkg-config ];
  # exqlite and argon2_elixir compile their C in-tree, so they need a compiler
  # (from stdenv) and the headers these two provide.
  buildInputs = [
    openssl
    sqlite
  ];

  # nixpkgs strips releases/COOKIE from the store, which the release script
  # still reads unconditionally, so RELEASE_COOKIE has to come from somewhere.
  # pesque is a single node and never joins a cluster, so distribution is turned
  # off and the cookie is inert: it only satisfies the script.
  postInstall = ''
    for env in "$out"/releases/*/env.sh; do
      cat >> "$env" <<'EOF'

# Set by the Nix build. pesque is a single node, so distribution is off and the
# cookie exists only because the release script reads it unconditionally.
export RELEASE_DISTRIBUTION="none"
export RELEASE_COOKIE="pesque"
EOF
    done
  '';

  meta = {
    description = "A Personal Data Server for ATProto, written in Elixir";
    homepage = "https://github.com/zeeetech/pesque";
    license = lib.licenses.wtfpl;
    platforms = lib.platforms.unix;
  };
}
