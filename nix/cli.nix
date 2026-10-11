# The host-side CLI, built from cli/ with the Zig the caller passes. nixpkgs'
# own zig moves with the channel and lags the CLI's minimum_zig_version, so the
# flake takes the toolchain from the zig overlay and hands it in.
{
  lib,
  stdenv,
  zig,
}:
let
  version =
    let
      line = lib.findFirst (l: lib.hasInfix ".version" l) "" (
        lib.splitString "\n" (builtins.readFile ../cli/build.zig.zon)
      );
      matched = builtins.match ".*\"([^\"]+)\".*" line;
    in
    if matched == null then "0.0.0" else builtins.head matched;
in
stdenv.mkDerivation {
  pname = "pesque-cli";
  inherit version;

  src = ../cli;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    zig build --prefix "$out" -Doptimize=ReleaseSafe
    runHook postBuild
  '';

  # zig build already installed to $out/bin.
  installPhase = ":";

  meta = {
    description = "The pesque host-side CLI";
    homepage = "https://github.com/zeeetech/pesque";
    license = lib.licenses.wtfpl;
    mainProgram = "pesque";
    platforms = lib.platforms.unix;
  };
}
