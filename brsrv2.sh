#!/bin/bash
# brsrv2.sh — интерактивная полная настройка BR-SRV

set -e

sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

# --- NTP клиент ---
echo "=== Установка и настройка chrony ==="
dnf install -y chrony
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
read -p "NTP сервер (172.16.2.1): " NTP_SERVER
echo "server $NTP_SERVER iburst" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd
chronyc sources -v

# --- Установка пакетов ---
echo "=== Установка пакетов ==="
if rpm -q podman-docker &>/dev/null; then
    dnf remove -y podman-docker
fi
dnf install -y samba samba-client samba-dc bind bind-utils
dnf install -y ansible sshpass || true
dnf install -y docker-ce docker-ce-cli docker-compose || true
if ! command -v docker &>/dev/null; then
    dnf install -y docker docker-compose || true
fi

# --- SSH порт ---
read -p "Порт SSH (например, 2026): " SSH_PORT
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
systemctl restart sshd

# --- Samba DC ---
echo "=== Настройка контроллера домена Samba ==="
read -p "Realm (например, AU-TEAM.IRPO): " REALM
read -p "Domain (например, AU-TEAM): " DOMAIN
read -sp "Пароль администратора домена: " ADMIN_PASS
echo
systemctl mask systemd-resolved
systemctl stop systemd-resolved
rm -f /etc/samba/smb.conf
samba-tool domain provision --use-rfc2307 \
    --realm="$REALM" \
    --domain="$DOMAIN" \
    --adminpass="$ADMIN_PASS" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --option="bind interfaces only=no"
systemctl enable samba --now
echo "nameserver 127.0.0.1" > /etc/resolv.conf
echo "search $REALM" >> /etc/resolv.conf

# Создание пользователей и группы (запрашиваем параметры)
read -p "Базовое имя пользователей (например, sidehquser): " USER_BASE
read -p "Количество пользователей (например, 5): " USER_COUNT
read -p "Имя группы (например, sidehq): " GROUP_NAME
for i in $(seq 1 $USER_COUNT); do
    samba-tool user create ${USER_BASE}$i \
        --given-name=User \
        --surname=$i \
        --password="$ADMIN_PASS"
done
samba-tool group add "$GROUP_NAME"
for i in $(seq 1 $USER_COUNT); do
    samba-tool group addmembers "$GROUP_NAME" ${USER_BASE}$i
done
read -p "Имя компьютера для добавления в домен (например, HQ-CLI): " COMPUTER_NAME
samba-tool computer add "$COMPUTER_NAME" --password="$ADMIN_PASS"

# --- Ansible ---
echo "=== Настройка Ansible ==="
mkdir -p /etc/ansible
cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
host_key_checking = False
interpreter_python = auto_silent
EOF

# Запрашиваем параметры хостов Ansible
echo "Введите параметры для хостов Ansible (серверы, клиенты, роутеры):"
read -p "IP сервера HQ-SRV (192.168.1.2): " HQ_SRV_IP
read -p "Пользователь SSH для HQ-SRV: " HQ_SRV_USER
read -sp "Пароль для HQ-SRV: " HQ_SRV_PASS
echo
read -p "IP клиента HQ-CLI (192.168.2.2): " HQ_CLI_IP
read -p "Пользователь SSH для HQ-CLI: " HQ_CLI_USER
read -sp "Пароль для HQ-CLI: " HQ_CLI_PASS
echo
read -p "IP роутера HQ-RTR (192.168.1.1): " HQ_RTR_IP
read -p "Пользователь для HQ-RTR: " HQ_RTR_USER
read -sp "Пароль: " HQ_RTR_PASS
echo
read -p "IP роутера BR-RTR (192.168.4.1): " BR_RTR_IP
read -p "Пользователь для BR-RTR: " BR_RTR_USER
read -sp "Пароль: " BR_RTR_PASS
echo

cat > /etc/ansible/hosts <<EOF
[servers]
HQ-SRV ansible_host=$HQ_SRV_IP ansible_user=$HQ_SRV_USER ansible_password=$HQ_SRV_PASS ansible_port=$SSH_PORT
HQ-CLI ansible_host=$HQ_CLI_IP ansible_user=$HQ_CLI_USER ansible_password=$HQ_CLI_PASS
HQ-RTR ansible_host=$HQ_RTR_IP ansible_user=$HQ_RTR_USER ansible_password=$HQ_RTR_PASS
BR-RTR ansible_host=$BR_RTR_IP ansible_user=$BR_RTR_USER ansible_password=$BR_RTR_PASS
EOF

if command -v ansible &>/dev/null && command -v sshpass &>/dev/null; then
    ansible all -m ping -i /etc/ansible/hosts || echo "Предупреждение: не все хосты доступны."
else
    echo "Ошибка: ansible или sshpass не установлены."
    exit 1
fi

# --- Docker и testapp ---
echo "=== Настройка Docker и testapp ==="
systemctl enable --now docker

# Монтирование ISO (опционально)
read -p "Путь к каталогу с docker образами (например, /mnt/iso/docker): " DOCKER_IMAGES_DIR
if [ -d "$DOCKER_IMAGES_DIR" ]; then
    for tarfile in "$DOCKER_IMAGES_DIR"/*.tar; do
        [ -f "$tarfile" ] && docker load -i "$tarfile"
    done
fi

# Перетегирование
if docker image inspect site_latest &>/dev/null; then
    docker tag site_latest site:latest
fi
if docker image inspect mariadb_latest &>/dev/null; then
    docker tag mariadb_latest mariadb:10.11
fi

# Параметры для docker-compose
read -p "IP сервера базы данных (192.168.4.2): " DB_HOST_IP
read -p "Пароль для MariaDB root: " MYSQL_ROOT_PASS
read -p "Пользователь БД testc: " DB_USER
read -sp "Пароль пользователя: " DB_USER_PASS
echo

mkdir -p /opt/testapp
cat > /opt/testapp/docker-compose.yml <<EOF
services:
  testapp:
    container_name: testapp
    image: site:latest
    restart: always
    ports:
      - "80:8000"
    environment:
      DB_TYPE: maria
      DB_HOST: "$DB_HOST_IP"
      DB_NAME: mariadb
      DB_PORT: "3306"
      DB_USER: "$DB_USER"
      DB_PASS: "$DB_USER_PASS"
    depends_on:
      - db
  db:
    container_name: db
    image: mariadb:10.11
    restart: always
    ports:
      - "3306:3306"
    environment:
      MARIADB_DATABASE: mariadb
      MARIADB_USER: "$DB_USER"
      MARIADB_PASSWORD: "$DB_USER_PASS"
      MARIADB_ROOT_PASSWORD: "$MYSQL_ROOT_PASS"
EOF

if docker image inspect site:latest &>/dev/null && docker image inspect mariadb:10.11 &>/dev/null; then
    docker-compose -f /opt/testapp/docker-compose.yml up -d
else
    echo "Не найдены образы site:latest или mariadb:10.11. Запуск пропущен."
fi

echo "=== Настройка BR-SRV завершена ==="