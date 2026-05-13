#!/bin/bash
# ============================================================================
# Fail2ban Management and Monitoring Script for FreePBX
# ============================================================================
# This script helps manage and monitor fail2ban security for Asterisk/FreePBX
# Usage: ./fail2ban_monitor.sh [status|unban|list|stats]
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root: sudo bash fail2ban_monitor.sh${NC}"
    exit 1
fi

# Check if fail2ban is installed
if ! command -v fail2ban-client &> /dev/null; then
    echo -e "${RED}Fail2ban is not installed!${NC}"
    exit 1
fi

# Function to display status
show_status() {
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BLUE}           Fail2ban Status for FreePBX                 ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo ""
    
    # Check service status
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}✓ Fail2ban service is running${NC}"
    else
        echo -e "${RED}✗ Fail2ban service is NOT running${NC}"
        echo -e "${YELLOW}  Start it with: systemctl start fail2ban${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}Active Jails:${NC}"
    fail2ban-client status | grep "Jail list" | sed 's/.*://g' | tr ',' '\n' | while read jail; do
        jail_trimmed=$(echo "$jail" | xargs)
        if [ -n "$jail_trimmed" ]; then
            echo -e "  • $jail_trimmed"
        fi
    done
    
    echo ""
    echo -e "${YELLOW}Asterisk PJSIP Jail Details:${NC}"
    if fail2ban-client status asterisk-pjsip &>/dev/null; then
        CURRENTLY_BANNED=$(fail2ban-client status asterisk-pjsip | grep "Currently banned" | awk '{print $NF}')
        TOTAL_BANNED=$(fail2ban-client status asterisk-pjsip | grep "Total banned" | awk '{print $NF}')
        CURRENTLY_FAILED=$(fail2ban-client status asterisk-pjsip | grep "Currently failed" | awk '{print $NF}')
        
        echo -e "  Currently banned IPs: ${RED}$CURRENTLY_BANNED${NC}"
        echo -e "  Total banned (all time): $TOTAL_BANNED"
        echo -e "  Currently failed attempts: $CURRENTLY_FAILED"
        
        # Show banned IPs if any
        BANNED_IPS=$(fail2ban-client status asterisk-pjsip | grep "Banned IP list:" | sed 's/.*://')
        if [ -n "$BANNED_IPS" ] && [ "$BANNED_IPS" != " " ]; then
            echo ""
            echo -e "${YELLOW}  Banned IP addresses:${NC}"
            for ip in $BANNED_IPS; do
                echo -e "    ${RED}✗${NC} $ip"
            done
        fi
    else
        echo -e "${RED}  asterisk-pjsip jail not found or not active${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}Asterisk PJSIP DDoS Jail Details:${NC}"
    if fail2ban-client status asterisk-pjsip-ddos &>/dev/null; then
        CURRENTLY_BANNED=$(fail2ban-client status asterisk-pjsip-ddos | grep "Currently banned" | awk '{print $NF}')
        echo -e "  Currently banned IPs: ${RED}$CURRENTLY_BANNED${NC}"
    else
        echo -e "${RED}  asterisk-pjsip-ddos jail not found or not active${NC}"
    fi
    
    echo ""
}

# Function to unban an IP
unban_ip() {
    if [ -z "$1" ]; then
        echo -e "${RED}Error: Please provide an IP address to unban${NC}"
        echo "Usage: $0 unban <IP_ADDRESS>"
        exit 1
    fi
    
    IP=$1
    echo -e "${YELLOW}Attempting to unban IP: $IP${NC}"
    
    # Try to unban from both jails
    fail2ban-client set asterisk-pjsip unbanip "$IP" 2>/dev/null && echo -e "${GREEN}✓ Unbanned from asterisk-pjsip${NC}" || echo -e "${YELLOW}⚠ Not found in asterisk-pjsip${NC}"
    fail2ban-client set asterisk-pjsip-ddos unbanip "$IP" 2>/dev/null && echo -e "${GREEN}✓ Unbanned from asterisk-pjsip-ddos${NC}" || echo -e "${YELLOW}⚠ Not found in asterisk-pjsip-ddos${NC}"
    
    echo ""
    echo -e "${GREEN}Done! IP $IP should now be able to connect.${NC}"
}

# Function to list recent bans from logs
list_recent_bans() {
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BLUE}        Recent Ban Activity (last 50 entries)          ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo ""
    
    if [ -f /var/log/fail2ban.log ]; then
        grep "Ban\|Unban" /var/log/fail2ban.log | tail -50 | while read line; do
            if echo "$line" | grep -q "Ban"; then
                echo -e "${RED}$line${NC}"
            else
                echo -e "${GREEN}$line${NC}"
            fi
        done
    else
        echo -e "${RED}No fail2ban log file found at /var/log/fail2ban.log${NC}"
    fi
    echo ""
}

# Function to show detailed statistics
show_stats() {
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BLUE}           Fail2ban Statistics & Configuration         ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo ""
    
    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "  Filter file: /etc/fail2ban/filter.d/asterisk-pjsip.conf"
    echo -e "  Jail file: /etc/fail2ban/jail.d/asterisk.local"
    echo ""
    
    echo -e "${YELLOW}Jail Settings (asterisk-pjsip):${NC}"
    if [ -f /etc/fail2ban/jail.d/asterisk.local ]; then
        MAXRETRY=$(grep "maxretry" /etc/fail2ban/jail.d/asterisk.local | head -1 | awk '{print $3}')
        FINDTIME=$(grep "findtime" /etc/fail2ban/jail.d/asterisk.local | head -1 | awk '{print $3}')
        BANTIME=$(grep "bantime" /etc/fail2ban/jail.d/asterisk.local | head -1 | awk '{print $3}')
        
        echo -e "  Max retry: $MAXRETRY attempts"
        echo -e "  Find time: $FINDTIME seconds ($(($FINDTIME / 60)) minutes)"
        echo -e "  Ban time: $BANTIME seconds ($(($BANTIME / 60)) minutes)"
    fi
    
    echo ""
    echo -e "${YELLOW}Monitoring Commands:${NC}"
    echo -e "  View all jails: ${GREEN}fail2ban-client status${NC}"
    echo -e "  View specific jail: ${GREEN}fail2ban-client status asterisk-pjsip${NC}"
    echo -e "  Live log monitoring: ${GREEN}tail -f /var/log/fail2ban.log${NC}"
    echo -e "  Asterisk security events: ${GREEN}tail -f /var/log/asterisk/full | grep SecurityEvent${NC}"
    echo ""
    
    echo -e "${YELLOW}Firewall Rules (iptables):${NC}"
    BANNED_COUNT=$(iptables -L -n | grep -c "f2b-asterisk")
    echo -e "  Active fail2ban rules: $BANNED_COUNT"
    echo ""
    
    iptables -L -n | grep "f2b-asterisk" | head -10
    echo ""
}

# Main menu
case "$1" in
    status)
        show_status
        ;;
    unban)
        unban_ip "$2"
        ;;
    list)
        list_recent_bans
        ;;
    stats)
        show_stats
        ;;
    *)
        echo -e "${BLUE}========================================================${NC}"
        echo -e "${BLUE}      Fail2ban Manager for FreePBX/Asterisk           ${NC}"
        echo -e "${BLUE}========================================================${NC}"
        echo ""
        echo "Usage: $0 {status|unban|list|stats}"
        echo ""
        echo -e "${YELLOW}Commands:${NC}"
        echo -e "  ${GREEN}status${NC}          - Show current fail2ban status and banned IPs"
        echo -e "  ${GREEN}unban <IP>${NC}      - Unban a specific IP address"
        echo -e "  ${GREEN}list${NC}            - List recent ban/unban activity"
        echo -e "  ${GREEN}stats${NC}           - Show detailed statistics and configuration"
        echo ""
        echo -e "${YELLOW}Examples:${NC}"
        echo "  $0 status"
        echo "  $0 unban 192.168.1.100"
        echo "  $0 list"
        echo ""
        exit 1
        ;;
esac
