{
  stdenv,
  lib,
  git,
  xxhash,
  fetchHex,
  gleam,
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
    erlangPackage ? beamPackages.erlang,
    rebar3Package ? beamPackages.rebar3,
    ...
  } @ attrs: let
    # gleam.toml contains an application name and version.
    gleamToml = lib.importTOML (src + "/gleam.toml");

    # manifest.toml contains a list of required packages including a sha256 checksum
    # that can be used by nix fetchHex fetcher.
    manifestToml = lib.importTOML (src + "/manifest.toml");

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

    # Gleam records a git dependency twice over: once in `[packages]` with its
    # version, and once in a `[git.<name>]` table naming the commit it was taken
    # from. Without the second, Gleam finds no record of where the package came
    # from, decides it was never downloaded, and downloads it -- which cannot
    # work in the sandbox. The commits are in the manifest, so write them out.
    gitRecordsTOML = with lib;
      concatMapStringsSep "\n" (
        p: ''
          [git.${p.name}]
          commit = "${p.commit}"
        ''
      ) (filterPackagesBySource "git" manifestToml.packages);

    # Helper function to filter manifest.toml packages
    filterPackagesBySource = type: packages: lib.lists.filter (p: p.source == type) packages;

    gitDerivs =
      map
      (p: {
        name = p.name;
        derivation = fetchGit {
          url = p.repo;
          rev = p.commit;
        };
      })
      (filterPackagesBySource "git" manifestToml.packages);

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
      (filterPackagesBySource "hex" manifestToml.packages);

    # Find replacement paths for `local` package dependencies
    # from `localPackages` list.
    localDeps = let
      # Build a lookup attrset for local packages.
      localDerivs = lib.mergeAttrsList (map (
          p: let
            localSrc = p;
            name = (fromTOML (readFile (localSrc + "/gleam.toml"))).name;
          in {
            "${name}" = localSrc;
          }
        )
        localPackages);
    in
      map (
        p: {
          inherit (p) name path;
          localSrc =
            if localDerivs ? "${p.name}"
            then localDerivs.${p.name}
            else builtins.throw "Local dependency \"${p.name}\" not found in `localPackages`.";
          # Keep local packages in a writable location during build.
          newPath = p.path;
        }
      ) (filterPackagesBySource "local" manifestToml.packages);

    # Check if elixir is needed in nativeBuildInputs by checking if "mix" is in
    # required build_tools.
    isElixirProject = with lib; p: any (t: t == "mix") p.build_tools;
    needsElixir = with lib; any isElixirProject manifestToml.packages;

    # nativeBuildInputs needed for both targets.
    defaultNativeBuildInputs = [gleam beamPackages.hex rsync git xxhash];
  in
    # Base common mkDerivation attributes
    stdenv.mkDerivation (attrs
      // {
        pname = attrs.pname or gleamToml.name;
        version = attrs.version or gleamToml.version;

        src = lib.cleanSource attrs.src;

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

            # Record which commit each git dependency was taken from. This has to
            # happen before the local package caches are primed below, since those
            # are copies of this file.
            ${lib.optionalString (gitRecordsTOML != "") ''
              cat <<EOF >> build/packages/packages.toml
              ${gitRecordsTOML}
              EOF
            ''}

            ${
              lib.concatStringsSep "\n" (
                lib.forEach localDeps (
                  d: ''
                    # Gleam writes build output into the dependency's own source
                    # directory, so it cannot be left pointing at the read-only
                    # store path. Stage it somewhere writable first, keeping the
                    # relative path the manifest recorded so that the paths in
                    # gleam.toml still resolve.
                    mkdir -p "$(dirname "${d.newPath}")"
                    mkdir -p "${d.newPath}"
                    rsync --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r -r ${d.localSrc}/* "${d.newPath}/"
                  ''
                )
              )
            }

            ${
              lib.concatStringsSep "\n" (
                lib.forEach gitDerivs (
                  d: ''
                    rsync --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r -r ${d.derivation}/* build/packages/${d.name}/
                  ''
                )
              )
            }

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

# To prevent dependency resolution in Gleam 1.15+, local packages
            # need to have their fingerprint up-to-date.
            ${lib.concatStringsSep "\n" (
              lib.forEach localDeps (d: ''
                printf "%u" 0x$(xxhsum -H3 ${d.newPath}/gleam.toml | cut -d' ' -f1 | cut -d '_' -f2) > build/packages/${d.name}.config_fingerprint
              '')
            )}

            # Prime local package dependency caches so they do not try to fetch.
            #
            # Gleam compiles a path dependency inside that dependency's own
            # directory, using the package cache found there. Left empty, that
            # cache makes Gleam re-resolve -- and re-download -- every one of the
            # dependency's own dependencies. Seed it from the cache prepared above
            # instead, which is also how the local packages get the git records.
            ${
              lib.concatStringsSep "\n" (
                lib.forEach localDeps (
                  d: ''
                    mkdir -p "${d.newPath}/build/packages"
                    cp build/packages/packages.toml "${d.newPath}/build/packages/packages.toml"
                    rsync --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r -r build/packages/* "${d.newPath}/build/packages/"
                  ''
                )
              )
            }

            runHook postConfigure
          '';
      }
      # When the build target is erlang
      // lib.optionalAttrs (buildTarget == "erlang") {
        nativeBuildInputs =
          defaultNativeBuildInputs
          ++ [erlangPackage rebar3Package]
          ++ (lib.optional needsElixir [beamPackages.elixir])
          ++ nativeBuildInputs;

        # The gleam compiler has a nice export function for erlang shipment.
        buildPhase =
          attrs.buildPhase
          or ''
            runHook preBuild

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
