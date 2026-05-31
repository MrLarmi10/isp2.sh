#!/bin/bash
# hq-cli_setup.sh — интерактивная версия

set -e

SUDO_PASS="P@ssword"  # временно, но лучше запросить
run_sudo() {
    echo "$SUDO_PASS" | sudo -S bash -c "$1"
}

echo "=== Установка chrony ==="
dnf install -y chrony
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
read -p "NTP сервер (172.16.2.1): " NTP_SERVER
echo "server $NTP_SERVER iburst" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd
chronyc sources -v

echo "=== 1. Установка Яндекс Браузера ==="
run_sudo "dnf install -y yandex-browser-stable"

echo "=== 2. Вход в домен ==="
read -p "DNS сервер (192.168.4.2): " DNS_SERVER
read -p "Домен поиска (au-team.irpo): " DOMAIN
nmcli con mod ens160.200 ipv4.dns "$DNS_SERVER 8.8.8.8"
nmcli con mod ens160.200 ipv4.dns-search "$DOMAIN"
nmcli con up ens160.200

echo "=== 4. Проверка разрешения домена ==="
if ! run_sudo "nslookup $DOMAIN $DNS_SERVER" | grep -q "$DNS_SERVER"; then
    echo "ОШИБКА: не удаётся разрешить домен $DOMAIN. Проверьте DNS на $DNS_SERVER."
    exit 1
fi

read -sp "Пароль администратора домена: " ADMIN_PASS
echo
echo "$ADMIN_PASS" | sudo -S realm join --user=Administrator "$DOMAIN" || {
    echo "ОШИБКА: не удалось войти в домен. Проверьте работу Samba DC."
    exit 1
}

echo "=== 5. Sudo для группы ==="
read -p "Имя группы, которая получит sudo (например, sidehq): " GROUP_NAME
run_sudo "echo '%$GROUP_NAME ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id' > /etc/sudoers.d/$GROUP_NAME"
run_sudo "chmod 440 /etc/sudoers.d/$GROUP_NAME"

echo "=== 6. Монтирование NFS ==="
read -p "IP NFS сервера (192.168.1.2): " NFS_SERVER
run_sudo "mkdir -p /mnt/nfs"
run_sudo "chmod -R 777 /mnt/nfs"
if run_sudo "ping -c 2 $NFS_SERVER &>/dev/null"; then
    run_sudo "echo '$NFS_SERVER:/raid1/nfs /mnt/nfs nfs defaults,_netdev 0 0' >> /etc/fstab"
    run_sudo "systemctl daemon-reload"
    run_sudo "mount -a"
else
    echo "NFS-сервер $NFS_SERVER недоступен. Монтирование пропущено."
fi

# Добавление записей в /etc/hosts
cp /etc/hosts /etc/hosts.bak
sed -i '/docker.au-team.irpo/d' /etc/hosts
sed -i '/web.au-team.irpo/d' /etc/hosts

read -p "IP для docker.au-team.irpo (172.16.2.1): " DOCKER_IP
read -p "IP для web.au-team.irpo (172.16.1.1): " WEB_IP
cat >> /etc/hosts <<EOF
$DOCKER_IP docker.au-team.irpo
$WEB_IP web.au-team.irpo
EOF

echo "Записи в /etc/hosts добавлены."
echo "=== Настройка HQ-CLI завершена ==="