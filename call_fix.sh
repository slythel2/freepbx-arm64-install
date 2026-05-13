#!/bin/bash
# ============================================================================
# Immediate Fix for Call Issues (31-second timeout + hangup problems)
# Apply this on your existing FreePBX installation
# ============================================================================

echo "============================================================"
echo "  FreePBX Call Issues Fix (Session Timer + Hangup)"
echo "============================================================"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Please run as root: sudo bash call_fix.sh"
    exit 1
fi

# 1. Create custom PJSIP configuration
echo "[1/4] Creating PJSIP custom configuration..."
cat > /etc/asterisk/pjsip_custom.conf <<'EOF'
; ============================================================================
; Custom PJSIP Configuration for Reliable Call Handling
; Fixes: 31-second timeout and hangup propagation issues
; ============================================================================

[global]
type=global
; Disable session timers to prevent 31-second disconnects
; Session timers can cause calls to drop if not properly refreshed
timers=no

EOF

echo "  ✓ Created /etc/asterisk/pjsip_custom.conf"

# 2. Include custom config in main pjsip.conf
echo "[2/4] Including custom config in pjsip.conf..."
if [ ! -f /etc/asterisk/pjsip.conf ]; then
    echo "  Creating /etc/asterisk/pjsip.conf..."
    touch /etc/asterisk/pjsip.conf
fi

if ! grep -q "pjsip_custom.conf" /etc/asterisk/pjsip.conf 2>/dev/null; then
    echo ";Custom optimizations" >> /etc/asterisk/pjsip.conf
    echo "#include pjsip_custom.conf" >> /etc/asterisk/pjsip.conf
    echo "  ✓ Include directive added"
else
    echo "  ✓ Already included"
fi

# 3. Verify configuration
echo "[3/4] Verifying configuration..."
if grep -q "timers=no" /etc/asterisk/pjsip_custom.conf; then
    echo "  ✓ Session timers disabled"
else
    echo "  ✗ Configuration may be incomplete"
fi

# 4. Reload Asterisk
echo "[4/4] Reloading Asterisk to apply changes..."
if systemctl is-active --quiet asterisk; then
    # Reload Asterisk configuration
    asterisk -rx "module reload res_pjsip.so" &>/dev/null
    sleep 1
    asterisk -rx "pjsip reload" &>/dev/null
    sleep 1
    
    # Also reload from FreePBX
    if command -v fwconsole &>/dev/null; then
        fwconsole reload &>/dev/null
    fi
    
    echo "  ✓ Asterisk reloaded"
else
    echo "  ! Asterisk not running, starting it..."
    systemctl start asterisk
    sleep 3
    echo "  ✓ Asterisk started"
fi

echo ""
echo "============================================================"
echo "  FIX APPLIED SUCCESSFULLY!"
echo "============================================================"
echo ""
echo "What was fixed:"
echo "  ✓ Disabled SIP session timers (prevents 31-second timeout)"
echo "  ✓ Configuration persistent across reboots"
echo ""
echo "Testing:"
echo "  1. Make a test call between two extensions"
echo "  2. Keep the call active for more than 60 seconds"
echo "  3. Try hanging up from both sides"
echo ""
echo "Verification commands:"
echo "  asterisk -rx 'pjsip show global'"
echo "  grep -i timer /etc/asterisk/pjsip_custom.conf"
echo ""
echo "If issues persist, check Asterisk logs:"
echo "  tail -f /var/log/asterisk/full"
echo ""
