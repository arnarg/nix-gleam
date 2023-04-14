# nix-gleam

Generic nix builder for gleam applications.

Gleam will create a `manifest.toml` file for every project which acts as a lock file and contains package name, version and a sha256 checksum of the package for every dependency. This is enough info for the builder to fetch all dependencies using `fetchHex` in nix.

## Usage

Currently there is only 1 builder which builds a gleam application that will be run by `erl` (like `gleam export erlang-shipment`).

### buildGleamApplication

In `flake.nix`:

```nix
{
  description = "My gleam application";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nix-gleam.url = "github:arnarg/nix-gleam";

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nix-gleam,
  }: (
    flake-utils.lib.eachDefaultSystem
    (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          nix-gleam.overlays.default
        ];
      };
    in {
      packages.default = pkgs.buildGleamApplication {
        # The pname and version will be read from the `gleam.toml`
        # file generated by gleam.
        # But this can be overwritten here too:
        # pname = "my-app";
        # version = "1.2.3";
        src = ./.;
      };
    })
  );
}
````
