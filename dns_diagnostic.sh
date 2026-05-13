#!/bin/bash
# ============================================================================
# DNS Diagnostic Tool for FreePBX SIP Trunk Issues
# ============================================================================
# This script helps diagnose DNS resolution problems that prevent SIP trunks
# from registering. Run this if you see errors like:
# "No answer record in the DNS response (PJLIB_UTIL_EDNSNOANSWERREC)"
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}    FreePBX DNS Diagnostic Tool for SIP Trunks         ${NC}"
echo -e "${BLUE}========================================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root: sudo bash dns_diagnostic.sh${NC}"
    exit 1
fi

# 1. Check DNS packages
echo -e "${YELLOW}1. Checking DNS packages installation...${NC}"
MISSING_PKGS=0
for pkg in dnsutils bind9-dnsutils bind9-host; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        echo -e "  ${GREEN}✓${NC} $pkg is installed"
    else
        echo -e "  ${RED}✗${NC} $pkg is MISSING"
        MISSING_PKGS=1
    fi
done

if [ $MISSING_PKGS -eq 1 ]; then
    echo -e "${YELLOW}  → Fix: apt-get install -y dnsutils bind9-dnsutils bind9-host${NC}"
fi

# 2. Check /etc/resolv.conf
echo ""
echo -e "${YELLOW}2. DNS Server Configuration (/etc/resolv.conf):${NC}"
if [ -f /etc/resolv.conf ]; then
    NAMESERVERS=$(grep "^nameserver" /etc/resolv.conf | wc -l)
    if [ $NAMESERVERS -gt 0 ]; then
        grep "^nameserver" /etc/resolv.conf | while read line; do
            echo -e "  ${GREEN}✓${NC} $line"
        done
    else
        echo -e "  ${RED}✗ No nameservers configured!${NC}"
        echo -e "${YELLOW}  → Add a nameserver: echo 'nameserver 8.8.8.8' >> /etc/resolv.conf${NC}"
    fi
else
    echo -e "  ${RED}✗ /etc/resolv.conf not found!${NC}"
fi

# 3. Test basic DNS resolution
echo ""
echo -e "${YELLOW}3. Testing basic DNS resolution...${NC}"
if command -v dig &> /dev/null; then
    GOOGLE_IP=$(dig google.com +short | head -n 1)
    if [ -n "$GOOGLE_IP" ]; then
        echo -e "  ${GREEN}✓${NC} Basic DNS works: google.com → $GOOGLE_IP"
    else
        echo -e "  ${RED}✗${NC} Cannot resolve google.com"
    fi
else
    echo -e "  ${RED}✗${NC} 'dig' command not available (install dnsutils)"
fi

# 4. Test SIP provider DNS (if user provides one)
echo ""
echo -e "${YELLOW}4. Testing SIP Provider DNS Resolution...${NC}"
echo -e "  Enter your SIP provider domain (e.g., voip.convergenze.it) or press Enter to skip:"
read -t 10 SIP_DOMAIN

if [ -n "$SIP_DOMAIN" ]; then
    if command -v dig &> /dev/null; then
        SIP_IP=$(dig "$SIP_DOMAIN" +short | head -n 1)
        if [ -n "$SIP_IP" ]; then
            echo -e "  ${GREEN}✓${NC} SIP provider DNS works: $SIP_DOMAIN → $SIP_IP"
            
            # Try to ping
            if ping -c 2 "$SIP_DOMAIN" &> /dev/null; then
                echo -e "  ${GREEN}✓${NC} Can reach SIP provider (ping successful)"
            else
                echo -e "  ${YELLOW}⚠${NC} DNS resolves but ping failed (may be normal if ICMP is blocked)"
            fi
        else
            echo -e "  ${RED}✗${NC} Cannot resolve $SIP_DOMAIN"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} Cannot test - dig not available"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} Skipped (no domain provided)"
fi

# 5. Check Asterisk PJSIP status
echo ""
echo -e "${YELLOW}5. Asterisk PJSIP Status...${NC}"
if systemctl is-active --quiet asterisk; then
    echo -e "  ${GREEN}✓${NC} Asterisk is running"
    
    # Show registrations
    echo ""
    echo -e "${BLUE}  SIP Trunk Registrations:${NC}"
    asterisk -rx "pjsip show registrations" 2>/dev/null || echo -e "  ${YELLOW}⚠${NC} Cannot query PJSIP (may not be configured)"
else
    echo -e "  ${RED}✗${NC} Asterisk is not running"
    echo -e "${YELLOW}  → Start it: systemctl start asterisk${NC}"
fi

# 6. Check recent Asterisk errors
echo ""
echo -e "${YELLOW}6. Recent DNS-related errors in Asterisk logs:${NC}"
if [ -f /var/log/asterisk/full ]; then
    DNS_ERRORS=$(grep -i "EDNSNOANSWERREC\|DNS.*fail\|resolution.*fail" /var/log/asterisk/full 2>/dev/null | tail -n 5)
    if [ -n "$DNS_ERRORS" ]; then
        echo "$DNS_ERRORS" | while read line; do
            echo -e "  ${RED}✗${NC} $line"
        done
    else
        echo -e "  ${GREEN}✓${NC} No recent DNS errors found"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} Log file /var/log/asterisk/full not found"
fi

# Summary and recommendations
echo ""
echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}                    SUMMARY                            ${NC}"
echo -e "${BLUE}========================================================${NC}"

if [ $MISSING_PKGS -eq 1 ]; then
    echo -e "${RED}ACTION REQUIRED:${NC} Install missing DNS packages:"
    echo -e "  ${YELLOW}apt-get update && apt-get install -y dnsutils bind9-dnsutils bind9-host${NC}"
    echo -e "  ${YELLOW}systemctl restart asterisk${NC}"
else
    echo -e "${GREEN}✓ All DNS packages are installed${NC}"
fi

if [ $NAMESERVERS -eq 0 ]; then
    echo -e "${RED}ACTION REQUIRED:${NC} Configure DNS servers in /etc/resolv.conf"
fi

echo ""
echo -e "For more help, check:"
echo -e "  • Asterisk logs: ${YELLOW}tail -f /var/log/asterisk/full${NC}"
echo -e "  • PJSIP settings: ${YELLOW}asterisk -rx 'pjsip show endpoints'${NC}"
echo -e "  • Registration status: ${YELLOW}asterisk -rx 'pjsip show registrations'${NC}"
echo ""
