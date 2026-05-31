#!/bin/bash
# isp_setup.sh - интерактивная версия

set -e

# Отключение SELinux
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

dnf install -y chrony nginx httpd-tools

echo "=== Установка и настройка chrony (сервер NTP) ==="
dnf install -y chrony
cat > /etc/chrony.conf <<EOF
# Внешний NTP сервер (можно оставить или закомментировать)
# server ntp1.vniiftri.ru iburst prefer
allow 0.0.0.0/0
local stratum 5
logdir /var/log/chrony
EOF
read -p "Введите внешний NTP сервер (например, ntp1.vniiftri.ru) или оставьте пустым: " EXT_NTP
if [ -n "$EXT_NTP" ]; then
    echo "server $EXT_NTP iburst prefer" >> /etc/chrony.conf
fi
systemctl restart chronyd
systemctl enable chronyd
chronyc tracking

# Настройка аутентификации для nginx
mkdir -p /etc/nginx
read -p "Логин для доступа к web.au-team.irpo: " WEB_USER
read -sp "Пароль: " WEB_PASS
echo
htpasswd -bc /etc/nginx/.htpasswd "$WEB_USER" "$WEB_PASS"

# Запрос IP адресов для прокси
read -p "Внутренний IP сервера HQ-SRV (172.16.1.2): " HQ_IP
read -p "Внутренний IP сервера BR-SRV (172.16.2.2): " BR_IP
read -p "Имя домена для первого прокси (web.au-team.irpo): " WEB_DOMAIN
read -p "Имя домена для второго прокси (docker.au-team.irpo): " DOCKER_DOMAIN

# Запись конфигурации nginx
cat > /etc/nginx/conf.d/proxy.conf <<EOF
server {
    listen 80;
    server_name $WEB_DOMAIN;
    location / {
        proxy_pass http://$HQ_IP:8080;
        auth_basic "Restricted area";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}

server {
    listen 80;
    server_name $DOCKER_DOMAIN;
    location / {
        proxy_pass http://$BR_IP:8080;
    }
}
EOF

rm -f /etc/nginx/conf.d/default.conf
nginx -t
systemctl enable --now nginx

# Включение маршрутизации
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

echo "Настройка ISP завершена. Прокси настроены на $HQ_IP:8080 и $BR_IP:8080"