# CRS_BLD

CRS_BLD is a small build environment for creating MinGW-w64 cross-compilers and Windows dependency packages from Linux.

It is used to build Windows versions of applications such as tindajudoshiai.

This system is based on ideas and build structure from MXE: <https://mxe.cc/>

The generated compiler trees and package installation directories are intentionally not tracked in Git. They are built locally from the scripts, package configuration files and patches in this repository.

## Main scripts

* `make_cross-compiler.sh`
  Builds the MinGW-w64 cross-compilers used to build Windows applications from Linux. It can also build native Windows GCC compilers.

* `make_pkgs.sh`
  Cross-compiles third-party packages from source for use by Windows applications.

* `order_of_compilation.txt`
  Lists the intended package build order.

## Support files

* `etc/common.sh`
  Shared shell functions used by the build scripts.

* `etc/diagnostics.sh`
  Diagnostic helper script for checking the generated CRS build environment.

## Source tree

The repository contains package build recipes and patches under `src/pkg/`.

```text
src/pkg/
├── cfg
│   ├── atk.sh
│   ├── brotli.sh
│   ├── bzip2.sh
│   ├── cairo.sh
│   ├── curl.sh
│   ├── glib.sh
│   ├── gtk3.sh
│   ├── libssh2.sh
│   ├── libwebsockets.sh
│   ├── openssl.sh
│   ├── pango.sh
│   └── ...
└── ptc
    ├── cairo-1-fixes.patch
    ├── glib-1-fixes.patch
    ├── gtk3-1-fixes.patch
    ├── gtk3-2-static-deps.patch
    ├── librsvg-1-fixes.patch
    ├── pango-1-static-deps.patch
    └── ...
```

The `cfg` directory contains one shell configuration file per package.

The `ptc` directory contains package patches applied during the build.

## Generated directories

The following directories are generated locally and should not be committed:

* `build/`
* `install/`
* `src/cpl/`
* `src/pkg/tar/`

Typical generated layout:

```text
.
├── build
├── etc
├── install
└── src
```

The `build/` directory contains temporary build trees.

The `install/` directory contains the generated cross-compilers, native Windows compilers and compiled package outputs.

The `src/cpl/` directory contains compiler sources such as Binutils, GCC and MinGW-w64.

The `src/pkg/tar/` directory contains downloaded package source archives.

## Compiler source setup

The compiler source archives are kept locally under:

```text
src/cpl/
```

This directory is generated/local state and is intentionally not tracked in Git.

Before building the cross-compilers, place the required compiler source archives in `src/cpl/`. The build script expects archives with names like:

```text
src/cpl/binutils-2.46.0.tar.*
src/cpl/gcc-16.1.0.tar.gz
src/cpl/mingw-w64-v14.0.0.tar.*
```

The exact versions may change, but the filename patterns are important:

* `binutils-*.tar.*`
* `gcc-*.tar.gz`
* `mingw-w64-v*.tar.*`

The available GCC versions are detected from the `gcc-*.tar.gz` files in `src/cpl/`.

For example, a prepared `src/cpl/` tree may look like this:

```text
src/cpl/
├── binutils -> binutils-2.46.0
├── binutils-2.46.0
├── binutils-2.46.0.tar.xz
├── gcc -> gcc-16.1.0
├── gcc-16.1.0
├── gcc-16.1.0.tar.gz
├── mingw-w64 -> mingw-w64-v14.0.0
├── mingw-w64-v14.0.0
└── mingw-w64-v14.0.0.tar.bz2
```

The symbolic links are created by `make_cross-compiler.sh`:

* `src/cpl/binutils`
* `src/cpl/gcc`
* `src/cpl/mingw-w64`

They point to the currently selected extracted source directories.

When a new GCC version is selected, or when the `src/cpl/gcc` symbolic link does not match the requested version, the script prepares the compiler sources again:

1. It removes old extracted Binutils, GCC and MinGW-w64 source directories.
2. It extracts the newest available `mingw-w64-v*.tar.*` archive.
3. It extracts the newest available `binutils-*.tar.*` archive.
4. It extracts the selected `gcc-<version>.tar.*` archive.
5. It recreates the `binutils`, `gcc` and `mingw-w64` symbolic links.
6. It runs `contrib/download_prerequisites --force` inside the GCC source tree.
7. It removes the old generated `build/cross`, `build/native`, `install/cross` and `install/native` trees.
8. It recreates the required build and install directories.

The special GCC version `git` may also be used, but then `src/cpl/gcc-git` must already exist as a Git checkout. In that case the script runs `git pull` in `src/cpl/gcc-git` and then points `src/cpl/gcc` to that directory.

## Building the cross and native compilers

The cross-compiler build is run from the repository root.

Show available GCC versions:

```bash
./make_cross-compiler.sh
```

Build using a specific GCC version, for example:

```bash
./make_cross-compiler.sh 16.1.0
```

The script builds both supported MinGW-w64 targets:

```text
i686-w64-mingw32
x86_64-w64-mingw32
```

For each target, the script first builds a Linux-hosted cross-compiler. This compiler runs on Linux and produces Windows binaries.

The generated cross-compilers are installed below:

```text
install/cross/i686-w64-mingw32/
install/cross/x86_64-w64-mingw32/
```

The build sequence for each cross-compiler target is:

1. Build cross Binutils.
2. Install MinGW-w64 headers into the Windows target sysroot.
3. Build the core GCC cross-compiler.
4. Build and install the MinGW-w64 CRT.
5. Finish the full GCC cross-compiler.
6. Build and install Winpthreads.

After the Linux-hosted cross-compiler has been built, the script also builds a Windows-native compiler for the same target. This compiler runs on Windows and produces Windows binaries.

The generated Windows-native compilers are installed below:

```text
install/native/i686-w64-mingw32/
install/native/x86_64-w64-mingw32/
```

The native compiler build sequence is:

1. Build Windows-native Binutils.
2. Build Windows-native GCC.
3. Move the required GCC runtime DLL into the native compiler `bin/` directory.
4. Build and install MinGW-w64 headers and libraries, including Winpthreads.
5. Package the native compiler directory as a ZIP file.

The native compiler ZIP files are written below:

```text
install/native/
```

## Checking the generated compilers

After the build has completed, check the generated cross-compilers:

```bash
install/cross/i686-w64-mingw32/bin/i686-w64-mingw32-gcc --version
install/cross/x86_64-w64-mingw32/bin/x86_64-w64-mingw32-gcc --version
```

The diagnostic helper can also be used:

```bash
./etc/diagnostics.sh
```

## Compiler targets

The main supported MinGW-w64 targets are:

* `i686-w64-mingw32`
* `x86_64-w64-mingw32`

Generated cross-compilers are installed below:

```text
install/cross/
├── i686-w64-mingw32
└── x86_64-w64-mingw32
```

Generated native Windows compilers, if built, are installed below:

```text
install/native/
├── i686-w64-mingw32
└── x86_64-w64-mingw32
```

## Package outputs

Compiled package outputs are installed below:

```text
install/pkg/
├── i686-w64-mingw32
│   ├── shared
│   └── static
└── x86_64-w64-mingw32
    ├── shared
    └── static
```

Each package target may provide headers, libraries, binaries and shared data files, depending on the package.

## Typical usage

Prepare compiler source archives under `src/cpl/`, then build the cross and native compiler trees:

```bash
./make_cross-compiler.sh 16.1.0
```

Then build packages in the required order. For example:

```bash
./make_pkgs.sh zlib
./make_pkgs.sh libpng
./make_pkgs.sh glib
./make_pkgs.sh gtk3
```

The complete intended package order is listed in:

```text
order_of_compilation.txt
```

## Notes

This repository is not intended to contain the generated compiler or package outputs.

The generated `install/` tree may be large and is machine-local.

For reproducibility, keep the build scripts, package configuration files, patches and package order under version control, but keep downloaded sources and generated build outputs out of Git.

## Warranty disclaimer

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
