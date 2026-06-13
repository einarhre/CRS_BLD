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

Build the cross-compilers first:

```bash
./make_cross-compiler.sh
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
