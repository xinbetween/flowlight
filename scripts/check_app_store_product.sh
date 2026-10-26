#!/bin/bash
set -euo pipefail

app=${1:?usage: check_app_store_product.sh /path/to/Flowlight.app}
repo=$(cd "$(dirname "$0")/.." && pwd)
contents="$app/Contents"
extension="$contents/PlugIns/com.flowlight.app.filter.appex"
app_binary="$contents/MacOS/Flowlight"
extension_binary="$extension/Contents/MacOS/com.flowlight.app.filter"
extension_info="$extension/Contents/Info.plist"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/flowlight-store-product.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

fail() {
  echo "App Store product check failed: $*" >&2
  exit 1
}

plist_true() {
  [ "$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null)" = true ]
}

extract_entitlements() {
  local executable=$1 destination=$2 label=$3
  codesign -d --entitlements :- "$executable" > "$destination" 2>/dev/null ||
    fail "cannot read entitlements from signed Store $label"
  plutil -lint "$destination" >/dev/null || fail "Store $label has no readable signed entitlements"
}

[ -x "$app_binary" ] || fail "missing app executable"
[ -x "$extension_binary" ] || fail "missing embedded content-filter executable"
extract_entitlements "$app_binary" "$temporary/app-entitlements.plist" app
extract_entitlements "$extension_binary" "$temporary/extension-entitlements.plist" extension

# The Store build disables HTTPS inspection: it neither installs a root certificate nor starts the local proxy.
# Nothing in this product listens for inbound connections, so a server entitlement on either signed executable is a
# least-privilege regression and will also stop automated App Review before the submission can proceed.
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$temporary/app-entitlements.plist" >/dev/null 2>&1; then
  fail "signed Store app declares network.server even though Store inspection is disabled"
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$temporary/extension-entitlements.plist" >/dev/null 2>&1; then
  fail "signed Store extension declares network.server but has no inbound listener"
fi
plist_true "$temporary/app-entitlements.plist" com.apple.security.network.client || fail "signed Store app is missing network.client"
plist_true "$temporary/extension-entitlements.plist" com.apple.security.network.client || fail "signed Store extension is missing network.client"

ruby -ryaml -e '
  project = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  expected = {
    "FlowlightAppStore" => "Flowlight/Flowlight-AppStore.entitlements",
    "FlowlightStoreExtension" => "FlowlightExtension/FlowlightExtension-AppStore.entitlements"
  }
  expected.each do |target, path|
    actual = project.dig("targets", target, "settings", "base", "CODE_SIGN_ENTITLEMENTS")
    abort "#{target} uses #{actual.inspect}, expected #{path}" unless actual == path
  end
' "$repo/project.yml" || fail "Store targets use the wrong entitlement files"

[ -d "$extension" ] || fail "missing embedded content-filter app extension"
[ ! -d "$contents/Library/SystemExtensions" ] || fail "contains a direct-distribution system extension"
[ ! -e "$contents/Library/Helpers/FlowlightResponseScriptHelper" ] || fail "contains the response-script helper"
[ ! -e "$contents/Resources/bpf-access.sh" ] || fail "contains the privileged packet-capture installer"

point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$extension_info")
[ "$point" = "com.apple.networkextension.filter-data" ] || fail "wrong extension point: $point"

app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$contents/Info.plist")
extension_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_info")
[ "$app_version" = "$extension_version" ] || fail "app and extension versions differ"

app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$contents/Info.plist")
extension_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extension_info")
[ "$app_build" = "$extension_build" ] || fail "app and extension builds differ"

if otool -L "$app_binary" | grep -q SystemExtensions.framework; then
  fail "links SystemExtensions.framework"
fi
if nm -u "$app_binary" | grep -q OSSystemExtension; then
  fail "references OSSystemExtension symbols"
fi

printf 'Mac App Store product is structurally valid: Flowlight %s/%s\n' "$app_version" "$app_build"
