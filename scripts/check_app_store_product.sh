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

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

require_absent() {
  local plist=$1 key=$2 label=$3
  if plist_value "$plist" "$key" >/dev/null; then
    fail "$label unexpectedly declares $key"
  fi
}

single_array_value() {
  local plist=$1 key=$2 label=$3 value
  value=$(/usr/libexec/PlistBuddy -c "Print :$key:0" "$plist" 2>/dev/null) ||
    fail "$label is missing $key or it is not a one-value array"
  if /usr/libexec/PlistBuddy -c "Print :$key:1" "$plist" >/dev/null 2>&1; then
    fail "$label declares more than one $key value"
  fi
  printf '%s' "$value"
}

extract_entitlements() {
  local executable=$1 destination=$2 label=$3
  codesign -d --entitlements :- "$executable" > "$destination" 2>/dev/null ||
    fail "cannot read entitlements from signed Store $label"
  plutil -lint "$destination" >/dev/null || fail "Store $label has no readable signed entitlements"
}

check_user_selected_write_access() {
  local entitlements=$1
  plist_true "$entitlements" com.apple.security.files.user-selected.read-write ||
    fail "signed Store app cannot write reports or plugin packages to a user-selected location"
  if plist_true "$entitlements" com.apple.security.files.user-selected.read-only; then
    fail "signed Store app declares redundant read-only user-selected access"
  fi
}

check_inspection_entitlements() {
  local app_entitlements=$1 extension_entitlements=$2
  plist_true "$app_entitlements" com.apple.security.network.server ||
    fail "signed Store app is missing network.server for its loopback inspection proxy"
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$extension_entitlements" >/dev/null 2>&1; then
    fail "signed Store extension declares network.server but never accepts inbound connections"
  fi
}

check_store_entitlements() {
  local app_entitlements=$1 extension_entitlements=$2 allow_unexpanded_group=${3:-false}
  local app_network extension_network app_group extension_group app_identifier extension_identifier prefix

  plist_true "$app_entitlements" com.apple.security.app-sandbox ||
    fail "signed Store app is missing App Sandbox"
  plist_true "$extension_entitlements" com.apple.security.app-sandbox ||
    fail "signed Store extension is missing App Sandbox"

  app_network=$(single_array_value "$app_entitlements" \
    com.apple.developer.networking.networkextension "signed Store app")
  extension_network=$(single_array_value "$extension_entitlements" \
    com.apple.developer.networking.networkextension "signed Store extension")
  [ "$app_network" = content-filter-provider ] ||
    fail "signed Store app has unexpected Network Extension capability: $app_network"
  [ "$extension_network" = content-filter-provider ] ||
    fail "signed Store extension has unexpected Network Extension capability: $extension_network"

  app_group=$(single_array_value "$app_entitlements" \
    com.apple.security.application-groups "signed Store app")
  extension_group=$(single_array_value "$extension_entitlements" \
    com.apple.security.application-groups "signed Store extension")
  [ "$app_group" = "$extension_group" ] ||
    fail "signed Store app and extension use different App Groups"

  app_identifier=$(plist_value "$app_entitlements" com.apple.application-identifier || true)
  extension_identifier=$(plist_value "$extension_entitlements" com.apple.application-identifier || true)
  if [ -n "$app_identifier" ] || [ -n "$extension_identifier" ]; then
    [ -n "$app_identifier" ] && [ -n "$extension_identifier" ] ||
      fail "signed Store app and extension must both declare application identifiers"
    case "$app_identifier" in
      *com.flowlight.app) prefix=${app_identifier%com.flowlight.app} ;;
      *) fail "signed Store app has unexpected application identifier: $app_identifier" ;;
    esac
    [ -n "$prefix" ] || fail "signed Store app application identifier has no team prefix"
    [ "$extension_identifier" = "${prefix}com.flowlight.app.filter" ] ||
      fail "signed Store extension application identifier does not share the app's team prefix"
    [ "$app_group" = "${prefix}com.flowlight.shared" ] ||
      fail "signed Store App Group does not match the signed application-identifier prefix"
  else
    [ "$allow_unexpanded_group" = true ] ||
      fail "signed Store products have no application identifiers to validate the App Group prefix"
    [ "$app_group" = '$(TeamIdentifierPrefix)com.flowlight.shared' ] ||
      fail "ad-hoc Store product has unexpected unexpanded App Group: $app_group"
  fi

  plist_true "$app_entitlements" com.apple.security.network.client ||
    fail "signed Store app is missing network.client"
  plist_true "$app_entitlements" com.apple.security.network.server ||
    fail "signed Store app is missing network.server for its loopback inspection proxy"
  plist_true "$app_entitlements" com.apple.security.device.camera ||
    fail "signed Store app is missing camera status access"
  check_user_selected_write_access "$app_entitlements"

  plist_true "$extension_entitlements" com.apple.security.network.client ||
    fail "signed Store extension is missing network.client"
  require_absent "$extension_entitlements" com.apple.security.network.server "signed Store extension"
  require_absent "$extension_entitlements" com.apple.security.device.camera "signed Store extension"
  require_absent "$extension_entitlements" com.apple.security.files.user-selected.read-write "signed Store extension"
  require_absent "$extension_entitlements" com.apple.security.files.user-selected.read-only "signed Store extension"
}

project_value() {
  local key=$1
  sed -n "s/^[[:space:]]*$key:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$repo/project.yml"
}

check_product_identity() {
  local app_info=$1 extension_info=$2
  local expected_version expected_build app_version extension_version app_build extension_build app_id extension_id
  expected_version=$(project_value MARKETING_VERSION)
  expected_build=$(project_value CURRENT_PROJECT_VERSION)
  [ -n "$expected_version" ] && [ -n "$expected_build" ] ||
    fail "cannot read expected Store version and build from project.yml"

  app_id=$(plist_value "$app_info" CFBundleIdentifier) || fail "Store app has no bundle identifier"
  extension_id=$(plist_value "$extension_info" CFBundleIdentifier) || fail "Store extension has no bundle identifier"
  [ "$app_id" = com.flowlight.app ] || fail "wrong Store app bundle identifier: $app_id"
  [ "$extension_id" = com.flowlight.app.filter ] || fail "wrong Store extension bundle identifier: $extension_id"

  app_version=$(plist_value "$app_info" CFBundleShortVersionString) || fail "Store app has no version"
  extension_version=$(plist_value "$extension_info" CFBundleShortVersionString) || fail "Store extension has no version"
  [ "$app_version" = "$extension_version" ] || fail "app and extension versions differ"
  [ "$app_version" = "$expected_version" ] ||
    fail "Store archive version is $app_version, expected $expected_version"

  app_build=$(plist_value "$app_info" CFBundleVersion) || fail "Store app has no build number"
  extension_build=$(plist_value "$extension_info" CFBundleVersion) || fail "Store extension has no build number"
  [ "$app_build" = "$extension_build" ] || fail "app and extension builds differ"
  [ "$app_build" = "$expected_build" ] ||
    fail "Store archive build is $app_build, expected $expected_build"
}

is_ad_hoc_signature() {
  local executable=$1 details
  details=$(codesign -d --verbose=4 "$executable" 2>&1) || fail "cannot inspect Store code signature"
  [[ "$details" == *"Signature=adhoc"* ]]
}

make_entitlement_fixture() {
  local app_entitlements=$1 extension_entitlements=$2 prefix=${3:-TESTTEAM.}
  plutil -create xml1 "$app_entitlements"
  plutil -create xml1 "$extension_entitlements"
  for plist in "$app_entitlements" "$extension_entitlements"; do
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.networking.networkextension array' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.networking.networkextension:0 string content-filter-provider' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string ${prefix}com.flowlight.shared" "$plist"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' "$plist"
  done
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${prefix}com.flowlight.app" "$app_entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${prefix}com.flowlight.app.filter" "$extension_entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.server bool true' "$app_entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.camera bool true' "$app_entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.files.user-selected.read-write bool true' "$app_entitlements"
}

make_info_fixture() {
  local plist=$1 bundle_id=$2 version=${3:-$(project_value MARKETING_VERSION)} build=${4:-$(project_value CURRENT_PROJECT_VERSION)}
  plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build" "$plist"
}

check_forbidden_automation() {
  local executable=$1 output=$2
  strings "$executable" > "$output" || fail "cannot inspect Store app strings"
  if grep -Eq '/usr/bin/(openssl|security)|/usr/sbin/networksetup' "$output"; then
    fail "contains Developer-only certificate or proxy automation"
  fi
}

check_proxy_attribution_surface() {
  local executable=$1 output=$2
  strings "$executable" > "$output" || fail "cannot inspect Store extension strings"
  grep -q 'setInspectionProxyPort:withReply:' "$output" ||
    fail "Store extension is missing proxy-port publication"
  grep -q 'inspectionProxyClientWithClientAddress:clientPort:proxyPort:withReply:' "$output" ||
    fail "Store extension is missing exact-flow proxy attribution"
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

case "${1:-}" in
  --self-test-valid-store-entitlements)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    exit 0
    ;;
  --self-test-valid-ad-hoc-entitlements)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements" '$(TeamIdentifierPrefix)'
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$app_entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements" true
    exit 0
    ;;
  --self-test-missing-application-identifiers)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$app_entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "missing application identifiers self-test was not rejected"
    ;;
  --self-test-missing-app-sandbox)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$app_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "missing app-sandbox self-test was not rejected"
    ;;
  --self-test-missing-extension-sandbox)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "missing extension sandbox self-test was not rejected"
    ;;
  --self-test-wrong-network-extension)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Set :com.apple.developer.networking.networkextension:0 packet-tunnel-provider' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "wrong Network Extension capability self-test was not rejected"
    ;;
  --self-test-extra-app-group)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups:1 string TESTTEAM.com.flowlight.extra' "$app_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "extra App Group self-test was not rejected"
    ;;
  --self-test-mismatched-app-group)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.application-groups:0 OTHERTEAM.com.flowlight.shared' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "mismatched App Group self-test was not rejected"
    ;;
  --self-test-wrong-app-group-prefix)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.application-groups:0 OTHERTEAM.com.flowlight.shared' "$app_entitlements"
    /usr/libexec/PlistBuddy -c 'Set :com.apple.security.application-groups:0 OTHERTEAM.com.flowlight.shared' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "wrong App Group prefix self-test was not rejected"
    ;;
  --self-test-unexpected-extension-entitlement)
    app_entitlements="$temporary/app-entitlements.plist"
    extension_entitlements="$temporary/extension-entitlements.plist"
    make_entitlement_fixture "$app_entitlements" "$extension_entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.server bool true' "$extension_entitlements"
    check_store_entitlements "$app_entitlements" "$extension_entitlements"
    fail "unexpected extension entitlement self-test was not rejected"
    ;;
  --self-test-valid-product-identity)
    app_info="$temporary/app-info.plist"
    extension_info="$temporary/extension-info.plist"
    make_info_fixture "$app_info" com.flowlight.app
    make_info_fixture "$extension_info" com.flowlight.app.filter
    check_product_identity "$app_info" "$extension_info"
    exit 0
    ;;
  --self-test-stale-version)
    app_info="$temporary/app-info.plist"
    extension_info="$temporary/extension-info.plist"
    make_info_fixture "$app_info" com.flowlight.app 0.17.9
    make_info_fixture "$extension_info" com.flowlight.app.filter 0.17.9
    check_product_identity "$app_info" "$extension_info"
    fail "stale version self-test was not rejected"
    ;;
  --self-test-stale-build)
    app_info="$temporary/app-info.plist"
    extension_info="$temporary/extension-info.plist"
    make_info_fixture "$app_info" com.flowlight.app "$(project_value MARKETING_VERSION)" 83
    make_info_fixture "$extension_info" com.flowlight.app.filter "$(project_value MARKETING_VERSION)" 83
    check_product_identity "$app_info" "$extension_info"
    fail "stale build self-test was not rejected"
    ;;
  --self-test-wrong-app-bundle-id)
    app_info="$temporary/app-info.plist"
    extension_info="$temporary/extension-info.plist"
    make_info_fixture "$app_info" com.flowlight.wrong
    make_info_fixture "$extension_info" com.flowlight.app.filter
    check_product_identity "$app_info" "$extension_info"
    fail "wrong app bundle identifier self-test was not rejected"
    ;;
  --self-test-wrong-extension-bundle-id)
    app_info="$temporary/app-info.plist"
    extension_info="$temporary/extension-info.plist"
    make_info_fixture "$app_info" com.flowlight.app
    make_info_fixture "$extension_info" com.flowlight.wrong.filter
    check_product_identity "$app_info" "$extension_info"
    fail "wrong extension bundle identifier self-test was not rejected"
    ;;
esac

if [ "${1:-}" = --self-test-read-only ]; then
  read_only="$temporary/read-only-entitlements.plist"
  plutil -create xml1 "$read_only"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.files.user-selected.read-only bool true' "$read_only"
  check_user_selected_write_access "$read_only"
  fail "read-only file-access self-test was not rejected"
fi

if [ "${1:-}" = --self-test-missing-proxy-server ]; then
  app_entitlements="$temporary/app-entitlements.plist"
  extension_entitlements="$temporary/extension-entitlements.plist"
  plutil -create xml1 "$app_entitlements"
  plutil -create xml1 "$extension_entitlements"
  check_inspection_entitlements "$app_entitlements" "$extension_entitlements"
  fail "missing-proxy-server self-test was not rejected"
fi

if [ "${1:-}" = --self-test-missing-proxy-attribution ]; then
  fake_extension="$temporary/fake-extension"
  printf '%s\n' 'ordinary extension bytes' > "$fake_extension"
  check_proxy_attribution_surface "$fake_extension" "$temporary/fake-extension-strings.txt"
  fail "missing-proxy-attribution self-test was not rejected"
fi

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
app_info="$contents/Info.plist"
extension_info="$extension/Contents/Info.plist"

[ -x "$app_binary" ] || fail "missing app executable"
[ -x "$extension_binary" ] || fail "missing embedded content-filter executable"
extract_entitlements "$app_binary" "$temporary/app-entitlements.plist" app
extract_entitlements "$extension_binary" "$temporary/extension-entitlements.plist" extension
allow_unexpanded_group=false
if is_ad_hoc_signature "$app_binary" && is_ad_hoc_signature "$extension_binary"; then
  # The unsigned CI product is re-signed ad hoc from the source entitlement plists, so Xcode has not expanded
  # TeamIdentifierPrefix or added application identifiers. Distribution signatures must carry both identifiers.
  allow_unexpanded_group=true
fi
check_store_entitlements "$temporary/app-entitlements.plist" "$temporary/extension-entitlements.plist" \
  "$allow_unexpanded_group"

camera_description=$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$app_info" 2>/dev/null) ||
  fail "Store app has no camera activity usage description"
[ -n "$camera_description" ] || fail "Store app has an empty camera activity usage description"
if /usr/libexec/PlistBuddy -c 'Print :NSSystemExtensionUsageDescription' "$app_info" >/dev/null 2>&1; then
  fail "Store app carries the Developer-only system-extension usage description"
fi

# Flowlight uses Apple's TLS APIs and does not ship custom cryptography. Declaring that in the built product keeps
# export-compliance handling deterministic instead of leaving each upload to an avoidable App Store Connect prompt.
uses_non_exempt_encryption=$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' \
  "$app_info" 2>/dev/null) || fail "Store app does not declare export-compliance encryption usage"
[ "$uses_non_exempt_encryption" = false ] || fail "Store app declares non-exempt encryption"

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
  plist = project.dig("targets", "FlowlightAppStore", "settings", "base", "INFOPLIST_FILE")
  abort "FlowlightAppStore uses #{plist.inspect}, expected Flowlight/Info-AppStore.plist" unless plist == "Flowlight/Info-AppStore.plist"
' "$repo/project.yml" || fail "Store targets use the wrong entitlement files"

[ -d "$extension" ] || fail "missing embedded content-filter app extension"
[ ! -d "$contents/Library/SystemExtensions" ] || fail "contains a direct-distribution system extension"
[ ! -e "$contents/Library/Helpers/FlowlightResponseScriptHelper" ] || fail "contains the response-script helper"
[ ! -e "$contents/Resources/bpf-access.sh" ] || fail "contains the privileged packet-capture installer"

point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$extension_info")
[ "$point" = "com.apple.networkextension.filter-data" ] || fail "wrong extension point: $point"

check_product_identity "$app_info" "$extension_info"
app_version=$(plist_value "$app_info" CFBundleShortVersionString)
app_build=$(plist_value "$app_info" CFBundleVersion)

check_forbidden_linkage "$app_binary" "$temporary/app-libraries.txt" \
  "$temporary/app-undefined-symbols.txt"
check_forbidden_automation "$app_binary" "$temporary/app-strings.txt"
check_proxy_attribution_surface "$extension_binary" "$temporary/extension-strings.txt"

printf 'Mac App Store product is structurally valid: Flowlight %s/%s\n' "$app_version" "$app_build"
