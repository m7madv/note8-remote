#!/system/bin/sh

# Start the Note8 remote-control foreground service after Android finishes
# booting. Tailscale is configured separately as Android's always-on VPN.
attempt=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$attempt" -lt 120 ]; do
    sleep 1
    attempt=$((attempt + 1))
done

# Give credential-protected app storage and the package manager a moment to
# settle, then start the service even if the VPN is still reconnecting. The
# listener becomes reachable as soon as Tailscale brings tun0 up.
sleep 3
am start-foreground-service -n com.codex.note8remote/.RemoteService >/dev/null 2>&1
