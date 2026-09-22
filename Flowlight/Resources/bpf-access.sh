#!/bin/sh
# Flowlight packet-capture access (run as root by the app after an admin prompt).
#   bpf-access.sh install <user>   grant <user> read access to /dev/bpf* now and at every boot
#   bpf-access.sh uninstall <user> remove the boot job and revert device permissions
# Same approach as Wireshark's ChmodBPF: members of access_bpf may read BPF devices.
set -eu
ACTION="$1"
TARGET_USER="$2"
GROUP=access_bpf
SUPPORT="/Library/Application Support/Flowlight"
HELPER="$SUPPORT/bpf-access-boot.sh"
PLIST=/Library/LaunchDaemons/com.flowlight.bpf-access.plist

case "$ACTION" in
install)
    /usr/sbin/dseditgroup -o read "$GROUP" >/dev/null 2>&1 || /usr/sbin/dseditgroup -o create -r "BPF device access" "$GROUP"
    /usr/sbin/dseditgroup -o edit -a "$TARGET_USER" -t user "$GROUP"
    /bin/mkdir -p "$SUPPORT"
    /bin/cat > "$HELPER" <<'BOOT'
#!/bin/sh
/usr/bin/chgrp access_bpf /dev/bpf*
/bin/chmod g+r /dev/bpf*
BOOT
    /usr/sbin/chown root:wheel "$HELPER"
    /bin/chmod 755 "$HELPER"
    /bin/cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.flowlight.bpf-access</string>
    <key>ProgramArguments</key><array><string>/bin/sh</string><string>$HELPER</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
    /usr/sbin/chown root:wheel "$PLIST"
    /bin/chmod 644 "$PLIST"
    /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
    /bin/launchctl bootstrap system "$PLIST"
    /bin/sh "$HELPER"
    ;;
uninstall)
    /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
    /bin/rm -f "$PLIST" "$HELPER"
    # Leave permissions alone if Wireshark relies on the same group.
    if [ ! -f /Library/LaunchDaemons/org.wireshark.ChmodBPF.plist ]; then
        /usr/bin/chgrp wheel /dev/bpf* || true
        /bin/chmod g-r /dev/bpf* || true
        /usr/sbin/dseditgroup -o edit -d "$TARGET_USER" -t user "$GROUP" 2>/dev/null || true
    fi
    ;;
*)
    echo "usage: $0 install|uninstall <user>" >&2
    exit 64
    ;;
esac
