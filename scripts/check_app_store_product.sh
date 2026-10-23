#!/bin/bash
set -euo pipefail

app=${1:?usage: check_app_store_product.sh /path/to/Flowlight.app}
contents="$app/Contents"
extension="$contents/PlugIns/com.flowlight.app.filter.appex"
app_binary="$contents/MacOS/Flowlight"
extension_info="$extension/Contents/Info.plist"

fail() {
  echo "App Store product check failed: $*" >&2
  exit 1
}

[ -x "$app_binary" ] || fail "missing app executable"
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
