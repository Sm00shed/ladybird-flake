{
  description = "Ladybird browser development environment";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/89570f24e97e614aa34aa9ab1c927b6578a43775";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        isDarwin = builtins.match ".*-darwin" system != null;
        isLinux  = builtins.match ".*-linux"  system != null;

        pkgs = import nixpkgs {
          inherit system;
          # macOS: apple-sdk_15 statt Standard 14.4 verwenden.
          # NSCursorFrameResizePositionBottomRight wurde erst in macOS 15 eingefuehrt.
          overlays = if isDarwin then [
            (final: prev: { apple-sdk = prev.apple-sdk_15; })
          ] else [];
        };

        llvm = pkgs.llvmPackages_21;

        mimalloc227 = pkgs.mimalloc.overrideAttrs (_: rec {
          version = "2.2.7";
          src = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo  = "mimalloc";
            rev   = "v${version}";
            hash  = "sha256:0gdsf5n44kad22x53nkrm6p237s3kwqmr8chjmdl94866wwqrnng";
          };
          patches = [];
        });

        # libtommath mit mp_set_double-Fix fuer macOS:
        # Apple Clang definiert __STDC_IEC_559__ nicht, obwohl Intel-Macs
        # vollstaendig IEEE-754-konform sind. Dadurch wird mp_set_double
        # nicht in die .dylib kompiliert, obwohl es im Header deklariert ist.
        # Fix: Quelldatei direkt patchen damit der Guard immer true ist.
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
            hash  = "sha256:1agwj1p7mhga0mb1qg0l0ry61fhyszzgyhgnfc00xvc7k9cagf2p";
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
          gnFlags = prev.gnFlags ++ [
            "extra_cflags+=[\"-DSKCMS_API=[[gnu::visibility(\\\"default\\\")]]\"]"
          ];
          patches = (prev.patches or []) ++ [
            (pkgs.fetchpatch {
              url  = "https://github.com/microsoft/vcpkg/raw/64e1fbee7d9f40eab5d112aaff648c4dcffe9e47/ports/skia/skpath-enable-edit-methods.patch";
              hash = "sha256-r5+HqSjACINn8igXqBANQsq0K+fn+Ut8L2VRs40FkTM=";
            })
          ];
        });

        libPkgs = with pkgs; [
          curlFull ffmpeg.lib fontconfig.lib libavif angle libjxl libwebp libxcrypt
          openssl sdl3 brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzz libjpeg libpng libxml2 sqlite zlib ladybirdSkia
          fmt simdutf simdjson libtommath130 libpsl libedit
        ] ++ pkgs.lib.optionals isLinux (with pkgs; [
          libdrm vulkan-loader
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
          vulkan-loader.dev vulkan-headers
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
        ]);

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

      in {
        devShells.default = pkgs.mkShell {
          name = "ladybird-dev";

          packages = libPkgs
            ++ [ llvm.clang llvm.clang-unwrapped ]
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
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${pkgs.angle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf ]; }}
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export LADYBIRD_CERTIFICATE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            alias Ladybird="./Build/release/bin/Ladybird --certificate=$LADYBIRD_CERTIFICATE"
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            ${if isDarwin then ''
              export LIBRARY_PATH="${pkgs.fontconfig.lib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              export LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${LDFLAGS:+ $LDFLAGS}"
              export NIX_LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${NIX_LDFLAGS:+ $NIX_LDFLAGS}"
              export CMAKE_EXE_LINKER_FLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics"
              export CMAKE_SHARED_LINKER_FLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics"
              # WORKAROUND: OpenGLContext.cpp defines EGL_EGLEXT_PROTOTYPES after eglext.h
              # which internally already includes eglext_angle.h at line 1500 before the
              # define is set → eglWaitUntilWorkScheduledANGLE never declared.
              # Upstream bug reported: https://github.com/LadybirdBrowser/ladybird/issues/XXXX
              # Remove once upstream fix is merged (move #define before #include <EGL/egl.h>).
              export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE} -DEGL_EGLEXT_PROTOTYPES=1"
            '' else ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export NIX_LDFLAGS="''${NIX_LDFLAGS} -lGL -lfontconfig"
            ''}

            ulimit -s unlimited
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
