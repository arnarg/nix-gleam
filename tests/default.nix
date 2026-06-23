{
  lib,
  newScope,
  buildGleamApplication,
}:
lib.makeScope newScope (self: {
  basic = buildGleamApplication {
    pname = "basic-test";
    version = "none";
    src = ./basic;

    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/basic"
    '';
  };
})
