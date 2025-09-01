# This was mostly copied from gomod2nix :)
final: prev: let
  callPackage = final.callPackage;
in {
  inherit (callPackage ./builder {}) buildGleamApplication;
}
