#!/bin/bash
# hq-rtr_setup.sh (интерактивная версия)

set -e

# Функция для перевода маски в CIDR
mask_to_cidr() {
    local mask=$1
    if [[ "$mask" =~ ^[0-9]+$ ]]; then
        echo "$mask"
    elif [[ "$mask" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local cidr=0
        IFS=. read -r o1 o2 o3 o4 <<< "$mask"
        for octet in $o1 $o2 $o3 $o4; do
            while [ $octet -gt 0 ]; do
                ((cidr += octet & 1))
                octet=$((octet >> 1))
            done
        done
        echo "$cidr"
    else
        echo "0"
    fi
}

echo "=== Настройка HQ-RTR (интерактивный режим) ==="

# Отключение SELinux
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

# Включение IP-форвардинга
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Установка nftables
dnf install -y nftables
systemctl enable nftables

# Запрос параметров для DNAT
read -p "Внешний IP для DNAT (например, 172.16.1.2): " EXTERNAL_IP
read -p "Внутренний IP целевого сервера (например, 192.168.1.2): " INTERNAL_IP
read -p "Порт для веб-сервера (например, 8080 -> 80): " PORT_WEB
read -p "Порт для MySQL (например, 3306 -> 2026): " PORT_MYSQL
read -p "Имя исходящего интерфейса для masquerade (например, ens160): " OUT_IF

# Создание каталога для конфигов
mkdir -p /etc/nftables

# Запись файла hq.nft с подстановкой переменных
cat > /etc/nftables/hq.nft <<EOF
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

# Загрузка правил
nft -f /etc/nftables/hq.nft

# Настройка NTP
echo "=== Установка chrony ==="
dnf install -y chrony
echo "=== Настройка /etc/chrony.conf ==="
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
read -p "Введите IP сервера NTP (например, 172.16.2.1): " NTP_SERVER
echo "server $NTP_SERVER iburst" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd
chronyc sources -v

# Сохранение правил nftables
echo 'include "/etc/nftables/hq.nft"' > /etc/nftables.conf
systemctl restart nftables

echo "HQ-RTR настроен."