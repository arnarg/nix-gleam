{
  stdenv,
  lib,
  fetchHex,
  gleam,
  erlang,
  rebar3,
  elixir,
  beamPackages,
  rsync,
}: let
  inherit (builtins) fromTOML readFile;
in {
  buildGleamApplication = {
    src,
    nativeBuildInputs ? [],
    ...
  } @ attrs: let
    # gleam.toml contains an application name and version.
    gleamToml = fromTOML (readFile (src + "/gleam.toml"));

    # manifest.toml contains a list of required packages including a sha256 checksum
    # that can be used by nix fetchHex fetcher.
    manifestToml = fromTOML (readFile (src + "/manifest.toml"));

    # Generates a packages.toml expected by gleam compiler.
    packagesTOML = with lib;
      concatStringsSep "\n" (
        ["[packages]"]
        ++ (map
          (p: "${p.name} = \"${p.version}\"")
          manifestToml.packages)
      );

    # Fetch all dependencies
    depsDerivs =
      map
      (p: {
        name = p.name;
        derivation = fetchHex {
          inherit (p) version;
          pkg = p.name;
          sha256 = p.outer_checksum;
        };
      })
      manifestToml.packages;

    # Check if elixir is needed in nativeBuildInputs by checking if "mix" is in
    # required build_tools.
    isElixirProject = with lib; p: any (t: t == "mix") p.build_tools;
    needsElixir = with lib; any isElixirProject manifestToml.packages;

    # Handier reference to hex.
    hexpm = beamPackages.hex;
  in
    stdenv.mkDerivation (attrs
      // {
        pname = attrs.pname or gleamToml.name;
        version = attrs.version or gleamToml.version;

        src = lib.cleanSource attrs.src;

        nativeBuildInputs =
          [gleam rebar3 hexpm rsync]
          ++ (lib.optional needsElixir [elixir])
          ++ nativeBuildInputs;

        buildInputs = [erlang];

        # Here we must copy the dependencies into the right spot and
        # create a packages.toml file so the gleam compiler does not
        # attempt to pull the dependencies from the internet.
        configurePhase =
          attrs.configurePhase
          or ''
            runHook preConfigure

            mkdir -p build/packages

            # Write the packages.toml file
            cat <<EOF > build/packages/packages.toml
            ${packagesTOML}
            EOF

            # Copy all the dependencies into place
            ${lib.concatStringsSep "\n" (
              lib.forEach depsDerivs (
                # gleam outputs files inside the dependency's source directory
                # and therefor it needs to have permissive permissions.
                d: ''
                  rsync --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r -r ${d.derivation}/* build/packages/${d.name}/
                ''
              )
            )}

            runHook postConfigure
          '';

        # The gleam compiler has a nice export function for erlang shipment.
        buildPhase =
          attrs.buildPhase
          or ''
            runHook prebuild

            gleam export erlang-shipment

            runHook postBuild
          '';

        # Install all built packages into lib and create an entrypoint script
        # that starts the application.
        installPhase =
          attrs.installPhase
          or ''
            runHook preInstall

            mkdir -p $out/{bin,lib}

            rsync --exclude=entrypoint.sh -r build/erlang-shipment/* $out/lib/

            cat <<EOF > $out/bin/${gleamToml.name}
            #!/usr/bin/env sh
            ${erlang}/bin/erl \
              -pa $out/lib/*/ebin \
              -eval "${gleamToml.name}@@main:run(${gleamToml.name})" \
              -noshell \
              -extra "\$@"
            EOF
            chmod +x $out/bin/${gleamToml.name}

            runHook postInstall
          '';
      });
}
