/*
flake-parts module for IHP apps
can be imported in a flake inside an IHP app repo
*/

# with ihpFlake we receive arguments from the IHP flake in this repo itself
ihpFlake:

# these arguments on the other hand are from the flake where this module is imported
# i.e. from the flake of any particular IHP app
{ inputs, flake-parts-lib, lib, config, ... }:

{

    imports = [
        inputs.devenv.flakeModule
    ];

    # the app can configure IHP using these options from its flake
    options.perSystem = flake-parts-lib.mkPerSystemOption (
        { config, pkgs, system, ...}: {
            options.ihp = {
                enable = lib.mkEnableOption "Enable IHP support";

                ghcCompiler = lib.mkOption {
                    description = ''
                        The GHC compiler to use for IHP.
                    '';
                    default = pkgs.haskell.packages.ghc94;
                };

                packages = lib.mkOption {
                    description = ''
                        List of packages than should be included in the IHP environment.
                    '';
                    type = lib.types.listOf (lib.types.package);
                    default = [];
                };

                haskellPackages = lib.mkOption {
                    description = ''
                        Function returning a list of Haskell packages to be installed in the IHP environment.
                        The set of Haskell packages is passed to the function.
                    '';
                    default = p: [
                        p.cabal-install
                        p.base
                        p.wai
                        p.text
                        p.hlint
                        p.ihp
                    ];
                };

                projectPath = lib.mkOption {
                    description = ''
                        Path to the IHP project. You likely want to set this to `./.`.
                    '';
                    type = lib.types.path;
                };

                withHoogle = lib.mkOption {
                    description = ''
                        Enable Hoogle support. Adds `hoogle` command to PATH.
                    '';
                    type = lib.types.bool;
                    default = false;
                };

                dontCheckPackages = lib.mkOption {
                    description = ''
                        List of Haskell package names whose tests are skipped during build.
                    '';
                    type = lib.types.listOf (lib.types.str);
                    default = [];
                };

                doJailbreakPackages = lib.mkOption {
                    description = ''
                        List of Haskell package names who are jailbreaked before build.
                    '';
                    type = lib.types.listOf (lib.types.str);
                    default = [];
                };

                dontHaddockPackages = lib.mkOption {
                    description = ''
                        List of Haskell package names whose haddock is not built during app build.
                    '';
                    type = lib.types.listOf (lib.types.str);
                    default = [];
                };
            };
        }
    );

    config = {
        perSystem = { self', lib, pkgs, system, config, ... }: let
            cfg = config.ihp;
            ihp = ihpFlake.inputs.self;
            ghcCompiler = import "${ihp}/NixSupport/mkGhcCompiler.nix" {
                inherit pkgs;
                inherit (cfg) ghcCompiler dontCheckPackages doJailbreakPackages dontHaddockPackages;
                ihp = ihp;
                haskellPackagesDir = cfg.projectPath + "/Config/nix/haskell-packages";
                filter = ihpFlake.inputs.nix-filter.lib;
            };
        in lib.mkIf cfg.enable {
            # release build package
            packages = {
                default = self'.packages.unoptimized-prod-server;

                optimized-prod-server = import "${ihp}/NixSupport/default.nix" {
                    ihp = ihp;
                    haskellDeps = cfg.haskellPackages;
                    otherDeps = p: cfg.packages;
                    projectPath = cfg.projectPath;
                    # Dev tools are not needed in the release build
                    includeDevTools = false;
                    # Set optimized = true to get more optimized binaries, but slower build times
                    optimized = true;
                    ghc = ghcCompiler;
                    pkgs = pkgs;
                };

                unoptimized-prod-server = import "${ihp}/NixSupport/default.nix" {
                    ihp = ihp;
                    haskellDeps = cfg.haskellPackages;
                    otherDeps = p: cfg.packages;
                    projectPath = cfg.projectPath;
                    includeDevTools = false;
                    optimized = false;
                    ghc = ghcCompiler;
                    pkgs = pkgs;
                };

                unoptimized-docker-image = pkgs.dockerTools.buildImage {
                    name = "ihp-app";
                    config = { Cmd = [ "${self'.packages.unoptimized-prod-server}/bin/RunProdServer" ]; };
                };
                
                optimized-docker-image = pkgs.dockerTools.buildImage {
                    name = "ihp-app";
                    config = { Cmd = [ "${self'.packages.optimized-prod-server}/bin/RunProdServer" ]; };
                };


                migrate = pkgs.writeScriptBin "migrate" ''
                    ${ghcCompiler.ihp}/bin/migrate
                '';

                ihp-schema = pkgs.stdenv.mkDerivation {
                    name = "ihp-schema";
                    src = ihp;
                    phases = [ "unpackPhase" "installPhase" ];
                    installPhase = ''
                        mkdir $out
                        cp ${ihp}/lib/IHP/IHPSchema.sql $out/
                    '';
                };
            };

            devenv.shells.default = lib.mkIf cfg.enable {
                packages = [ ghcCompiler.ihp pkgs.postgresql_13 pkgs.gnumake ]
                    ++ cfg.packages
                    ++ [pkgs.mktemp] # Without this 'make build/bin/RunUnoptimizedProdServer' fails on macOS
                    ;

                /*
                we currently don't use devenv containers, and they break nix flake show
                without the proper inputs set
                https://github.com/cachix/devenv/issues/528
                */
                containers = lib.mkForce {};

                languages.haskell.enable = true;
                languages.haskell.package = (if cfg.withHoogle
                                             then ghcCompiler.ghc.withHoogle
                                             else ghcCompiler.ghc.withPackages) cfg.haskellPackages;

                languages.haskell.languageServer = ghcCompiler.haskell-language-server;
                languages.haskell.stack = null; # Stack is not used in IHP

                scripts.start.exec = ''
                    ${ghcCompiler.ihp}/bin/RunDevServer
                '';

                processes.devServer.exec = "start";

                # Disabled for now
                # Can be re-enabled once postgres is provided by devenv instead of IHP
                # env.IHP_DEVENV = "1";
                # env.DATABASE_URL = "postgres:///app?host=${config.env.PGHOST}";

                # Disabled for now
                # As the devenv postgres uses a different location for the socket
                # this would break lots of known commands such as `make db`
                services.postgres.enable = false;
                services.postgres.initialDatabases = [
                    {
                    name = "app";
                    schema = pkgs.runCommand "ihp-schema" {} ''
                        touch $out

                        echo "-- IHPSchema.sql" >> $out
                        echo "" >> $out
                        cat ${./lib/IHP/IHPSchema.sql} | sed -e s'/--.*//' | sed -e s'/$/\\/' >> $out
                        echo "" >> $out
                        echo "-- Application/Schema.sql" >> $out
                        echo "" >> $out
                        cat ${cfg.projectPath + "/Application/Schema.sql"} | sed -e s'/--.*//' | sed -e s'/$/\\/' >> $out
                        echo "" >> $out
                        echo "-- Application/Fixtures.sql" >> $out
                        echo "" >> $out
                        cat ${cfg.projectPath + "/Application/Fixtures.sql"} | sed -e s'/--.*//' | sed -e s'/$/\\/' >> $out
                    '';
                    }
                ];

                env.IHP_LIB = "${ihp}/lib/IHP";
                env.IHP = "${ihp}/lib/IHP"; # Used in the Makefile

                scripts.deploy-to-nixos.exec = ''
                    if [[ $# -eq 0 || $1 == "--help" ]]; then
                        echo "usage: deploy-to-nixos <target-host>"
                        echo "example: deploy-to-nixos staging.example.com"
                        exit 0
                    fi

                    ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch -j auto --use-substitutes --fast --flake .#$1 --target-host $1 --build-host $1 --option substituters https://digitallyinduced.cachix.org --option trusted-public-keys digitallyinduced.cachix.org:digitallyinduced.cachix.org-1:y+wQvrnxQ+PdEsCt91rmvv39qRCYzEgGQaldK26hCKE=
                    ssh $1 systemctl start migrate
                '';
            };
        };

        # Nix requires this to be interactively allowed on first use for security reasons
        # This can be automated by using the --accept-flake-config flag
        # E.g. nix develop --accept-flake-config
        # Or by putting accept-flake-config = true into the system's nix.conf
        flake.nixConfig = {
            extra-substituters = "https://digitallyinduced.cachix.org";
            extra-trusted-public-keys = "digitallyinduced.cachix.org-1:y+wQvrnxQ+PdEsCt91rmvv39qRCYzEgGQaldK26hCKE=";
        };
    };

}
