{
  stdenvNoCC,
  lib,
  fetchHex,
  fetchgit,
  git,
  xxhash,
  gleam,
  erlang,
  rebar3,
  elixir,
  beamPackages,
  makeBinaryWrapper,
  rsync,
  nodejs,
}:
let
  # Helper function to filter manifest.toml packages
  filterPackagesBySource = type: packages: lib.lists.filter (p: p.source == type) packages;
in
lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "localPackages"
    "erlangPackage"
    "rebar3Package"
    "target"
    "targetName"
    "gleamToml"
    "manifest"
    "needsElixir"
    "gitHashes"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      pname,
      version,
      src,
      nativeBuildInputs ? [ ],
      localPackages ? [ ],
      erlangPackage ? erlang,
      rebar3Package ? rebar3,
      postPatch ? "",
      target ? "erlang",

      # Various otions to prevent IFD
      targetName ? null,
      gleamToml ? null,
      manifest ? null,
      needsElixir ? null,
      useBuiltinFetchGit ? true,
      gitHashes ? { },
      ...
    }@attrs:
    let
      gleamToml' = lib.importTOML (
        if isNull manifest then (finalAttrs.src + "/gleam.toml") else gleamToml
      );
      manifestToml = lib.importTOML (
        if isNull manifest then (finalAttrs.src + "/manifest.toml") else manifest
      );

      name = if isNull targetName then gleamToml'.name else targetName;

      buildTarget = attrs.target or gleamToml'.target or target;

      # Generate packages.toml in the format expected
      packagesTOML = lib.concatStringsSep "\n" (
        [ "[packages]" ] ++ (map (p: ''${p.name} = "${p.version}"'') manifestToml.packages)
      );

      gitDerivs = map (p: {
        name = p.name;
        derivation = (if useBuiltinFetchGit then fetchGit else fetchgit) {
          name = p.name + "-git";
          url = p.repo;
          rev = p.commit;
          ${if useBuiltinFetchGit then null else "hash"} = gitHashes.${p.name};
        };
      }) (filterPackagesBySource "git" manifestToml.packages);

      # Fetch all dependencies
      depsDerivs = map (p: {
        name = p.name;
        derivation = fetchHex {
          inherit (p) version;
          pkg = p.name;
          sha256 = p.outer_checksum;
        };
      }) (filterPackagesBySource "hex" manifestToml.packages);

      # Find replacement paths for `local` package dependencies
      # from `localPackages` list.
      localDeps =
        let
          # Build a lookup attrset for local packages.
          # If supplied with a attrset, then do not do IFD.
          localDerivs =
            if (lib.isAttrs localPackages) then
              localPackages
            else
              lib.mergeAttrsList (
                map (
                  p:
                  let
                    name = (lib.importTOML (p + "/gleam.toml")).name;
                  in
                  {
                    "${name}" = p;
                  }
                ) localPackages
              );
        in
        map (p: {
          inherit (p) name path;
          newPath =
            if localDerivs ? "${p.name}" then
              localDerivs.${p.name}
            else
              throw "Local dependency \"${p.name}\" not found in `localPackages`.";
        }) (filterPackagesBySource "local" manifestToml.packages);

      needsElixir' =
        if isNull needsElixir then
          lib.any (p: lib.any (t: t == "mix") p.build_tools) manifestToml.packages
        else
          needsElixir;
    in
    {
      strictDeps = true;
      __structuredAttrs = true;

      postPatch =
        lib.concatMapStringsSep "\n" (p: ''
          sed -i -e 's|"${p.path}"|"${p.newPath}"|g' manifest.toml
          sed -i -e 's|"${p.path}"|"${p.newPath}"|g' gleam.toml
        '') localDeps
        + "\n"
        + postPatch;

      # Here we must copy the dependencies into the right spot and
      # create a packages.toml file so the gleam compiler does not
      # attempt to pull the dependencies from the internet.
      inherit packagesTOML;
      configurePhase = ''
        runHook preConfigure

        mkdir -p build/packages

        # Write the packages.toml file
        printf '%s' "$packagesTOML" > "build/packages/packages.toml"

        ${lib.concatStringsSep "\n" (
          lib.forEach gitDerivs (d: ''
            rsync --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r -r ${d.derivation}/* build/packages/${d.name}/
          '')
        )}

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

        runHook postConfigure
      '';

      nativeBuildInputs =
        nativeBuildInputs
        ++ [
          gleam
          beamPackages.hex
          rsync
          git
          xxhash
          makeBinaryWrapper
        ]
        ++ lib.optionals (buildTarget == "erlang") [
          erlangPackage
          rebar3Package
        ]
        ++ lib.optionals needsElixir' [ elixir ];

      buildPhase = lib.concatStringsSep "\n" [
        "runHook preBuild"
        (lib.optionalString (buildTarget == "erlang") ''
          export REBAR_CACHE_DIR="$TMP/.rebar-cache"
          gleam export erlang-shipment
        '')
        (lib.optionalString (buildTarget == "javascript") ''
          gleam build --target javascript
        '')
        "runHook postBuild"
      ];

      installPhase =
        let
          wrapper = lib.toFile "main.mjs" ''
            import { main } from "./${name}.mjs"
            main()
          '';
        in
        lib.concatStringsSep "\n" [
          ''
            runHook preInstall
            mkdir -p "$out"/{bin, lib}
          ''
          (lib.optionalString (buildTarget == "erlang") ''
            rsync --exclude=entrypoint.sh -r build/erlang-shipment/* $out/lib/

            mapfile -d "" ebinPaths < <(find "$out/lib" -type d -path "*/ebin" -print0)

            # Want to be resilient against white space, otherwise what
            # are we doing
            ebinArgs=()
            for path in "''${ebinPaths[@]}"; do
              ebinArgs+=("--add-flag" "$path")
            done

            makeWrapper "${erlangPackage}/bin/erl" "$out/bin/${name}" \
              --add-flag "-pa" \
              "''${ebinArgs[@]}" \
              --add-flag "-eval" \
              --add-flag "${name}@@main:run(${name})" \
              --add-flag "-noshell" \
              --add-flag "-extra"
          '')
          (lib.optionalString (buildTarget == "javascript") ''
            rsync --exclude=gleam.lock --exclude=gleam_version -r build/dev/javascript/* $out/lib/

            cp "${wrapper}" "$out/lib/${name}/main.mjs"

            makeWrapper "${lib.getExe nodejs}" "$out/bin/${name}" \
              --add-flag "$out/lib/${name}/main.mjs"
          '')
          "runHook postInstall"
        ];

      meta = {
        mainProgram = name;
      }
      // attrs.meta or { };
    };
}
