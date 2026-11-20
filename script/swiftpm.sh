#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Some Command Line Tools installs have a stale private PackageDescription
# interface alongside a working public interface and matching library.
swiftc_path="$(xcrun --find swiftc)"
pm_root="$(dirname "$swiftc_path")/../lib/swift/pm"
manifest="$pm_root/ManifestAPI"
interfaces="$manifest/PackageDescription.swiftmodule"
architecture="$(uname -m)"
public="$interfaces/$architecture-apple-macos.swiftinterface"
private="$interfaces/$architecture-apple-macos.private.swiftinterface"
if [[ -z "${SWIFTPM_CUSTOM_LIBS_DIR:-}" && -f "$private" && -f "$public" ]] &&
   /usr/bin/grep -q 'swiftLanguageModes: \[' "$public" &&
   ! /usr/bin/grep -q 'swiftLanguageModes: \[' "$private"; then
  overlay="$PWD/.build/local-toolchain"
  mkdir -p "$overlay/ManifestAPI/PackageDescription.swiftmodule"
  ln -sfn "$manifest/libPackageDescription.dylib" "$overlay/ManifestAPI/libPackageDescription.dylib"
  ln -sfn "$manifest/CompilerPluginSupport.swiftmodule" "$overlay/ManifestAPI/CompilerPluginSupport.swiftmodule"
  ln -sfn "$pm_root/PluginAPI" "$overlay/PluginAPI"
  for module in "$interfaces/"*; do
    case "$module" in *.private.swiftinterface) continue ;; esac
    ln -sfn "$module" "$overlay/ManifestAPI/PackageDescription.swiftmodule/${module##*/}"
  done
  export SWIFTPM_CUSTOM_LIBS_DIR="$overlay"
fi

testing_plugin="$pm_root/../host/plugins/testing/libTestingMacros.dylib"
if [[ "${1:-}" == test && -f "$testing_plugin" && "$swiftc_path" == /Library/Developer/CommandLineTools/* ]]; then
  set -- "$@" -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" --disable-xctest
fi

exec xcrun swift "$@"
