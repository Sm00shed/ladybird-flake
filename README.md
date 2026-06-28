# Ladybird Nix Dev Shell

> **Work in progress. Proof of concept stage.**

Cross-distro development environment for [Ladybird](https://github.com/LadybirdBrowser/ladybird) using `nix develop`. Tested on CachyOS and NixOS. macOS and other Linux distributions may work but are untested.

## Install Nix

```bash
curl -L https://nixos.org/nix/install -o install-nix.sh
sh install-nix.sh
```

Restart your shell, then enable flakes:

```bash
exec $SHELL
```

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

## Build Ladybird

**1. Clone Ladybird**

```bash
git clone https://github.com/LadybirdBrowser/ladybird.git 2>/dev/null || true
cd ladybird
git pull
```

**2. Enter the dev shell**

```bash
nix develop github:Sm00shed/ladybird-flake
```

**3. Configure**

```bash
cmake -B Build/release -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DVCPKG_MANIFEST_MODE=OFF \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches
```

**4. Compile**

```bash
ninja -j$(nproc) -C Build/release
```

**5. Run**

```bash
Ladybird
```

> Run using the `Ladybird` alias from within the `nix develop` shell — it passes the correct CA certificate automatically. Override with `LADYBIRD_CERTIFICATE=/your/cert.pem Ladybird`.

## What this flake provides

- Clang 21 (explicit, never system compiler)
- All dependencies pinned via `flake.lock`
- `CMAKE_PREFIX_PATH` set to Nix store paths — cmake never reads `/usr/lib`
- Unicode, Public Suffix List, HSTS Preload and CA certificates pre-populated
- `$CLANGD_PATH` exported for VSCode integration
