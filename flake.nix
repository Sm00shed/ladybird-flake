{
  description = "Ladybird browser development environment";

  inputs = {
    # Standard nixpkgs for Linux — uses binary cache, no rebuilds.
    nixpkgs.url        = "github:NixOS/nixpkgs/nixos-26.05";
    # Fork with darwinMinVersion=15.4; apple-sdk_15 requires MACOSX_DEPLOYMENT_TARGET>=15.4.
    nixpkgs-darwin.url = "github:Sm00shed/nixpkgs/darwin-min-version-15-4";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-darwin, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        isDarwin = builtins.match ".*-darwin" system != null;
        isLinux  = builtins.match ".*-linux"  system != null;

        pkgs = import (if isDarwin then nixpkgs-darwin else nixpkgs) {
          inherit system;
          config = {
            allowDeprecatedx86_64Darwin = true;
          };
          # Use apple-sdk_15 instead of the default 14.4 —
          # NSCursorFrameResizePositionBottomRight requires macOS 15.
          overlays = if isDarwin then [
            (final: prev: {
              apple-sdk = prev.apple-sdk_15;
            })
          ] else [];
        };

        llvm = pkgs.llvmPackages_21;

        mimalloc227 = pkgs.mimalloc.overrideAttrs (_: rec {
          version = "2.2.7";
          src = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo  = "mimalloc";
            rev   = "v${version}";
            hash  = "sha256-z9qMOTcGkURblZChXDGfQ58hrql52lG6EE1NQmxxuj0=";
          };
          patches = [];
        });

        # Apple Clang does not define __STDC_IEC_559__ even on IEEE-754-compliant x86_64,
        # so mp_set_double is compiled out despite being declared in the header.
        # Patch the guard to always true.
        libtommath130 = pkgs.libtommath.overrideAttrs (prev: {
          postPatch = (prev.postPatch or "") + ''
            substituteInPlace bn_mp_set_double.c \
              --replace-fail \
                '#if defined(__STDC_IEC_559__) || defined(__GCC_IEC_559)' \
                '#if 1 /* forced: x86_64 is IEEE754 compliant */'
          '';
        });

        wuffsSinglefile = pkgs.stdenv.mkDerivation {
          name = "wuffs-singlefile-0.3.4";
          src  = pkgs.fetchFromGitHub {
            owner = "google";
            repo  = "wuffs-mirror-release-c";
            rev   = "v0.3.4";
            hash  = "sha256-V7inWJqH7Q4Ac/ZB//7XHrpgfAYUPBxWBerBem6Q/Kk=";
          };
          dontBuild    = true;
          installPhase = ''
            mkdir -p $out/include/wuffs
            install -m444 release/c/wuffs-v0.3.c $out/include/wuffs/wuffs-v0.3.c
          '';
        };

        hstsPreload = pkgs.fetchurl {
          url  = "https://raw.githubusercontent.com/chromium/chromium/main/net/http/transport_security_state_static.json";
          hash = "sha256-YuiotSk0Lf3IHz/UjgCmU/brdB1lszob6DN4DXyjiWU=";
        };

        ladybirdSkia = pkgs.skia.overrideAttrs (prev: {
          version = "148-unstable-2026-06-12";
          src = pkgs.fetchgit {
            url  = "https://skia.googlesource.com/skia.git";
            rev  = "46f2e16555cac1211f4087cf24728fd741ac6495";
            hash = "sha256-vpd/W0C8zT+wzShdJYdd18GmNp/TklqF7bGZxfIaDDM=";
          };
          gnFlags = prev.gnFlags ++ [
            "extra_cflags+=[\"-DSKCMS_API=[[gnu::visibility(\\\"default\\\")]]\"]"
          ];
          patches = [];
        });

        # nixpkgs stable has a broken angle.pc: 'Cflags: -I' and 'Libs: -L' without paths.
        # Fixed in nixpkgs master (PR #528602, merged 2026-06-09) but not backported to 26.05.
        # On Linux, build angle with Clang 20 stdenv: Clang 21 ICEs while parsing
        # rx::vk::ImageHelper::SubresourceUpdate in vk_helpers.h (complex nested union type).
        ladybirdAngle = (if isLinux
          then pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; }
          else pkgs.angle
        ).overrideAttrs (prev: {
          postFixup = (prev.postFixup or "") + ''
            substituteInPlace $out/lib/pkgconfig/angle.pc \
              --replace-fail  'Cflags: -I' 'Cflags: -I''${includedir}' \
              --replace-quiet 'Libs: -L '  'Libs: -L''${libdir} '
          '';
        });

        libPkgs = with pkgs; [
          curlFull ffmpeg.lib fontconfig.lib libavif ladybirdAngle libjxl libwebp libxcrypt
          openssl sdl3 brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzz libjpeg libpng libxml2 sqlite zlib ladybirdSkia
          fmt simdutf simdjson libtommath130 libpsl libedit
        ] ++ pkgs.lib.optionals isLinux (with pkgs; [
          libdrm vulkan-loader vulkan-memory-allocator
          libGL libpulseaudio qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ]);

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzz.dev openssl.dev curlFull.dev sdl3.dev fmt.dev
          fontconfig.dev libavif.dev libjxl.dev libpng.dev libxml2.dev zlib.dev
          woff2.dev ffmpeg.dev libedit.dev libpsl.dev libjpeg.dev sqlite.dev
          mimalloc227.dev
        ] ++ [ libtommath130 ]
          ++ pkgs.lib.optionals isLinux (with pkgs; [
          vulkan-loader.dev vulkan-headers vulkan-memory-allocator
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
        ]);

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

      in {
        devShells.default = pkgs.mkShell {
          name = "ladybird-dev";

          NIX_ENFORCE_NO_NATIVE = "0";

          packages = libPkgs
            ++ [ llvm.clang llvm.lld ]
            ++ [ libtommath130 ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              curlFull.dev fast-float ffmpeg.dev fmt fmt.dev fontconfig.dev
              libavif.dev libjxl.dev openssl.dev sdl3.dev simdutf brotli.dev lcms2.dev
              zstd.dev libidn2.dev woff2.dev icu78.dev simdjson mimalloc227.dev
              wuffsSinglefile libedit libedit.dev libpsl libpsl.dev harfbuzz.dev libjpeg.dev
              libpng.dev libxml2.dev sqlite.dev zlib.dev
              unicode-character-database unicode-emoji unicode-idna publicsuffix-list
              dejavu_fonts liberation_ttf cacert
            ])
            ++ pkgs.lib.optionals isLinux (with pkgs; [
              patchelf
              libdrm.dev vulkan-headers vulkan-loader.dev glslang
              libGL.dev libpulseaudio.dev qt6Packages.qtmultimedia qt6Packages.qtwayland
            ])
            ++ pkgs.lib.optionals isDarwin (with pkgs; [
              apple-sdk_15
            ]);

          shellHook = ''
            export CC=${llvm.clang}/bin/clang
            export CXX=${llvm.clang}/bin/clang++
            export CMAKE_BUILD_TYPE=Release
            export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export ICU_ROOT=${pkgs.icu78.dev}
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${ladybirdAngle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            # CVDisplayLinkRelease is outside its pragma diagnostic block in VSyncScheduler.cpp:177.
            # Reported upstream: https://github.com/LadybirdBrowser/ladybird/issues/10657
            # TabController.mm:1498: BOOL/bool lambda return type mismatch.
            # Reported upstream: https://github.com/LadybirdBrowser/ladybird/issues/10658
            export CXXFLAGS="-Wno-deprecated-declarations -Wno-error=return-type''${CXXFLAGS:+ $CXXFLAGS}"
            export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf ]; }}
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            # Copy CA cert into Caches/CACERT: Landlock sandbox on Linux blocks direct
            # Nix store paths for RequestServer (see SandboxLinux.cpp).
            # Override: set LADYBIRD_CERTIFICATE=/your/cert.crt before launching.
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
            fi
            LADYBIRD_SRC_DIR="$PWD"
            export LADYBIRD_CERTIFICATE="''${LADYBIRD_CERTIFICATE:-$PWD/Caches/CACERT/ca-bundle.crt}"
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            ${if isDarwin then ''
              export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion)"
              export LIBRARY_PATH="${pkgs.fontconfig.lib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              export LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${LDFLAGS:+ $LDFLAGS}"
              export NIX_LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${NIX_LDFLAGS:+ $NIX_LDFLAGS}"
              export CMAKE_EXE_LINKER_FLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics"
              export CMAKE_SHARED_LINKER_FLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics"
              # macOS builds Ladybird.app bundle; sandbox requires codesigning so disable it
              Ladybird() { "$LADYBIRD_SRC_DIR/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" --disable-sandbox "$@"; }
            '' else ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export CMAKE_EXE_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_EXE_LINKER_FLAGS:+ $CMAKE_EXE_LINKER_FLAGS}"
              export CMAKE_SHARED_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_SHARED_LINKER_FLAGS:+ $CMAKE_SHARED_LINKER_FLAGS}"
              Ladybird() { "$LADYBIRD_SRC_DIR/Build/release/bin/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" "$@"; }
            ''}

            ${if isLinux then "ulimit -s unlimited" else "ulimit -s hard"}
            export RUST_MIN_STACK=16777216

            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              if [ ! -f "$PWD/Caches/HSTSPreload/transport_security_state_static.json" ]; then
                mkdir -p "$PWD/Caches/HSTSPreload"
                cp --no-preserve=mode ${hstsPreload} "$PWD/Caches/HSTSPreload/transport_security_state_static.json"
              fi
              if [ ! -f "$PWD/Caches/UCD/version.txt" ]; then
                mkdir -p "$PWD/Caches/UCD"
                cp --no-preserve=mode -r ${pkgs.unicode-character-database}/share/unicode/. "$PWD/Caches/UCD/"
                cp --no-preserve=mode ${pkgs.unicode-emoji}/share/unicode/emoji/emoji-test.txt "$PWD/Caches/UCD/"
                cp --no-preserve=mode ${pkgs.unicode-idna}/share/unicode/idna/IdnaMappingTable.txt "$PWD/Caches/UCD/"
                printf '%s' '${pkgs.unicode-character-database.version}' > "$PWD/Caches/UCD/version.txt"
              fi
              if [ ! -f "$PWD/Caches/PublicSuffix/public_suffix_list.dat" ]; then
                mkdir -p "$PWD/Caches/PublicSuffix"
                cp --no-preserve=mode ${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat \
                   "$PWD/Caches/PublicSuffix/"
              fi
            fi
          '';
        };
      }
    );
}
