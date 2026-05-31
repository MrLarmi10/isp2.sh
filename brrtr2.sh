#!/bin/bash
# br-rtr_setup.sh - интерактивная версия

set -e

sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

dnf install -y nftables
systemctl enable nftables

mkdir -p /etc/nftables

read -p "Внешний IP для DNAT (172.16.2.2): " EXTERNAL_IP
read -p "Внутренний IP целевого сервера (192.168.4.2): " INTERNAL_IP
read -p "Порт для веб (8080): " PORT_WEB
read -p "Порт для MySQL (3306): " PORT_MYSQL
read -p "Имя исходящего интерфейса (ens160): " OUT_IF

cat > /etc/nftables/br.nft <<EOF
table inet nat {
    chain PREROUTING {
        type nat hook prerouting priority filter; policy accept;
        ip daddr $EXTERNAL_IP tcp dport $PORT_WEB dnat ip to $INTERNAL_IP:80
        ip daddr $EXTERNAL_IP tcp dport $PORT_MYSQL dnat ip to $INTERNAL_IP:2026
    }

    chain POSTROUTING {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$OUT_IF" masquerade
    }
}
EOF

echo "=== Установка chrony ==="
dnf install -y chrony
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
read -p "NTP сервер (172.16.2.1): " NTP_SERVER
echo "server $NTP_SERVER iburst" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd
chronyc sources -v

nft -f /etc/nftables/br.nft
echo 'include "/etc/nftables/br.nft"' > /etc/nftables.conf
systemctl restart nftables

echo "BR-RTR настроен."