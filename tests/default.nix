{
  lib,
  newScope,
  buildGleamApplication,
}:
let
  buildTest = lib.extendMkDerivation {
    constructDrv = buildGleamApplication;

    excludeDrvArgNames = [
      "name"
    ];

    extendDrvArgs =
      finalAttrs:
      {
        name,
        version ? "none",
        src ? ./${name},
        ...
      }:
      {
        pname = name + "-test";
        inherit src version;
      };
  };
in
lib.makeScope newScope (self: {
  basic = buildTest {
    name = "basic";

    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/basic"
    '';
  };

  finalAttrs = buildTest (finalAttrs: {
    name = "finalAttrs-test";
    version = "${finalAttrs.pname}-none";
    src = ./basic;
  });
})
