#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
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

check_forbidden_linkage() {
  local executable=$1 libraries=$2 symbols=$3

  otool -L "$executable" > "$libraries" || fail "cannot inspect Store app libraries"
  if grep -q SystemExtensions.framework "$libraries"; then
    fail "links SystemExtensions.framework"
  fi

  nm -u "$executable" > "$symbols" || fail "cannot inspect Store app symbols"
  if grep -q OSSystemExtension "$symbols"; then
    fail "references OSSystemExtension symbols"
  fi
}

if [ "${1:-}" = --self-test-forbidden-symbol ]; then
  fake_tool="$temporary/fake-tool"
  fake_binary="$temporary/fake-binary"
  : > "$fake_binary"
  chmod +x "$fake_binary"
  cat > "$fake_tool" <<'EOF'
#!/bin/bash
if [ "$(basename "$0")" = otool ]; then
  printf '%s\n' '/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation'
else
  printf '%s\n' '_OBJC_CLASS_$_OSSystemExtensionRequest'
fi
EOF
  chmod +x "$fake_tool"
  mkdir "$temporary/tools"
  ln -s "$fake_tool" "$temporary/tools/otool"
  ln -s "$fake_tool" "$temporary/tools/nm"
  PATH="$temporary/tools:$PATH"
  check_forbidden_linkage "$fake_binary" "$temporary/self-test-libraries.txt" "$temporary/self-test-symbols.txt"
  fail "forbidden-linkage self-test was not rejected"
fi

app=${1:?usage: check_app_store_product.sh /path/to/Flowlight.app}
contents="$app/Contents"
extension="$contents/PlugIns/com.flowlight.app.filter.appex"
app_binary="$contents/MacOS/Flowlight"
extension_binary="$extension/Contents/MacOS/com.flowlight.app.filter"
extension_info="$extension/Contents/Info.plist"

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
plist_true "$temporary/app-entitlements.plist" com.apple.security.device.camera || fail "signed Store app is missing camera status access"
plist_true "$temporary/extension-entitlements.plist" com.apple.security.network.client || fail "signed Store extension is missing network.client"
if plist_true "$temporary/extension-entitlements.plist" com.apple.security.device.camera; then
  fail "signed Store extension declares camera access even though only the app reads device status"
fi
camera_description=$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$contents/Info.plist" 2>/dev/null) ||
  fail "Store app has no camera activity usage description"
[ -n "$camera_description" ] || fail "Store app has an empty camera activity usage description"

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

check_forbidden_linkage "$app_binary" "$temporary/app-libraries.txt" \
  "$temporary/app-undefined-symbols.txt"

printf 'Mac App Store product is structurally valid: Flowlight %s/%s\n' "$app_version" "$app_build"
