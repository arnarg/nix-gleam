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
  nodejs,
}: let
  inherit (builtins) fromTOML readFile;
in {
  buildGleamApplication = {
    src,
    nativeBuildInputs ? [],
    localPackages ? [],
    erlangPackage ? erlang,
    rebar3Package ? rebar3,
    ...
  } @ attrs: let
    # gleam.toml contains an application name and version.
    gleamToml = fromTOML (readFile (src + "/gleam.toml"));

    # manifest.toml contains a list of required packages including a sha256 checksum
    # that can be used by nix fetchHex fetcher.
    manifestToml = fromTOML (readFile (src + "/manifest.toml"));

    # Specify which target to build for.
    buildTarget = attrs.target or gleamToml.target or "erlang";

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
      (lib.lists.filter (p: p.source == "hex") manifestToml.packages);

    localDerivs = lib.mergeAttrsList (map (
        p: let
          name = (fromTOML (readFile (p + "/gleam.toml"))).name;
        in {
          "${name}" = p;
        }
      )
      localPackages);

    localDeps = map (
      p: {
        inherit (p) name path;
        newPath = localDerivs.${p.name};
      }
    ) (lib.lists.filter (p: p.source == "local") manifestToml.packages);

    # Check if elixir is needed in nativeBuildInputs by checking if "mix" is in
    # required build_tools.
    isElixirProject = with lib; p: any (t: t == "mix") p.build_tools;
    needsElixir = with lib; any isElixirProject manifestToml.packages;

    # nativeBuildInputs needed for both targets.
    defaultNativeBuildInputs = [gleam beamPackages.hex rsync];
  in
    # Base common mkDerivation attributes
    stdenv.mkDerivation (attrs
      // {
        pname = attrs.pname or gleamToml.name;
        version = attrs.version or gleamToml.version;

        src = lib.cleanSource attrs.src;

        postPatch =
          lib.concatMapStringsSep "\n" (
            p: ''
              sed -i -e 's|${p.path}|${p.newPath}|g' manifest.toml
              sed -i -e 's|${p.path}|${p.newPath}|g' gleam.toml
            ''
          )
          localDeps;

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
      }
      # When the build target is erlang
      // lib.optionalAttrs (buildTarget == "erlang") {
        nativeBuildInputs =
          defaultNativeBuildInputs
          ++ [erlangPackage rebar3Package]
          ++ (lib.optional needsElixir [elixir])
          ++ nativeBuildInputs;

        # The gleam compiler has a nice export function for erlang shipment.
        buildPhase =
          attrs.buildPhase
          or ''
            runHook prebuild

            export REBAR_CACHE_DIR="$TMP/.rebar-cache"

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
            ${erlangPackage}/bin/erl \
              -pa $out/lib/*/ebin \
              -eval "${gleamToml.name}@@main:run(${gleamToml.name})" \
              -noshell \
              -extra "\$@"
            EOF
            chmod +x $out/bin/${gleamToml.name}

            runHook postInstall
          '';
      }
      # When the build target is javascript
      // lib.optionalAttrs (buildTarget == "javascript") {
        nativeBuildInputs = defaultNativeBuildInputs ++ nativeBuildInputs;

        # The gleam compiler doesn't provide an export mechanism for javascript target.
        buildPhase =
          attrs.buildPhase
          or ''
            runHook prebuild

            gleam build --target javascript

            runHook postBuild
          '';

        # Install all built packages into lib and create an entrypoint script
        # that starts the application.
        installPhase =
          attrs.installPhase
          or ''
            runHook preInstall

            mkdir -p $out/{bin,lib}

            rsync --exclude=gleam.lock --exclude=gleam_version -r build/dev/javascript/* $out/lib/

            cat <<EOF > $out/lib/${gleamToml.name}/main.mjs
            import { main } from "./${gleamToml.name}.mjs";
            main();
            EOF

            cat <<EOF > $out/bin/${gleamToml.name}
            #!/usr/bin/env sh
            ${nodejs}/bin/node $out/lib/${gleamToml.name}/main.mjs "\$@"
            EOF
            chmod +x $out/bin/${gleamToml.name}

            runHook postInstall
          '';
      });
}
