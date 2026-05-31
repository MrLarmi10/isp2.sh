#!/bin/bash
# hq-srv_setup.sh - интерактивная версия

set -euo pipefail

# Отключение SELinux
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

echo "=== Установка chrony ==="
dnf install -y chrony
mount /dev/sr0 /mnt/ || true

echo "=== Настройка /etc/chrony.conf ==="
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
read -p "NTP сервер (например, 172.16.2.1): " NTP_SERVER
echo "server $NTP_SERVER iburst" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd
chronyc sources -v

# === 1. Изменение порта SSH ===
read -p "Новый порт SSH (например, 2026): " SSH_PORT
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
systemctl restart sshd || true

# === 2. RAID1 (автоматический поиск дисков с ручным подтверждением) ===
echo "=== Настройка RAID1 ==="
ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
DISKS=()
for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
    [ -b "$dev" ] || continue
    if [[ "$dev" == "$ROOT_DEV"* ]]; then continue; fi
    if ls ${dev}[0-9]* 2>/dev/null | grep -q .; then continue; fi
    DISKS+=("$dev")
done

if [ ${#DISKS[@]} -ge 2 ]; then
    echo "Доступные свободные диски: ${DISKS[@]}"
    read -p "Использовать первый и второй для RAID1? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        DISK1="${DISKS[0]}"
        DISK2="${DISKS[1]}"
        echo "Используем диски: $DISK1 и $DISK2"
        mdadm --create --verbose /dev/md0 --level=1 --raid-devices=2 "$DISK1" "$DISK2" || echo "RAID уже существует?"
        mdadm --detail --scan --verbose >> /etc/mdadm.conf 2>/dev/null || true
        mkfs.ext4 /dev/md0 || true
        mkdir -p /raid1
        if ! grep -q '/dev/md0' /etc/fstab; then
            echo '/dev/md0 /raid1 ext4 defaults 0 0' >> /etc/fstab
        fi
        mount -av || true
    else
        echo "RAID пропущен."
    fi
else
    echo "Не найдено двух свободных дисков для RAID. Пропускаем."
fi

# === 3. NFS ===
echo "=== Настройка NFS ==="
dnf install -y nfs-utils || true
mkdir -p /raid1/nfs
chmod -R 777 /raid1/nfs
read -p "IP подсети для экспорта NFS (например, 192.168.2.0/28): " NFS_NET
if ! grep -q '/raid1/nfs' /etc/exports; then
    echo "/raid1/nfs $NFS_NET(rw,sync,no_root_squash,no_subtree_check)" >> /etc/exports
fi
systemctl enable --now nfs-server || true
exportfs -a || true

# === 4. Веб-сервер и MariaDB ===
echo "=== Установка Apache, MariaDB, PHP ==="
dnf install -y httpd mariadb-server mariadb php php-mysqlnd || true
systemctl enable --now mariadb httpd || true

# Запрос пароля root для MySQL
read -sp "Введите пароль root для MySQL: " MYSQL_ROOT_PASS
echo
mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$MYSQL_ROOT_PASS');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Создание БД и пользователя
read -p "Имя базы данных (например, webdb): " DB_NAME
read -p "Имя пользователя БД: " DB_USER
read -sp "Пароль пользователя БД: " DB_PASS
echo
mysql -uroot -p"$MYSQL_ROOT_PASS" <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
EOF

# Импорт дампа (путь запрашивается)
read -p "Путь к SQL дампу (например, /mnt/web/dump.sql): " SQL_DUMP
if [ -f "$SQL_DUMP" ]; then
    mysql $DB_NAME < "$SQL_DUMP"
else
    echo "Файл дампа не найден, импорт пропущен."
fi

systemctl restart mariadb

# Копирование файлов сайта
read -p "Путь к logo.png: " LOGO_PATH
read -p "Путь к index.php: " INDEX_PATH
cp "$LOGO_PATH" /var/www/html/ 2>/dev/null || echo "logo.png не скопирован"
cp "$INDEX_PATH" /var/www/html/ 2>/dev/null || echo "index.php не скопирован"

# Правка index.php (запрашиваем параметры подключения)
if [ -f /var/www/html/index.php ]; then
    sed -i \
      -e "s|\$servername *= *\".*\";|\$servername = \"localhost\";|" \
      -e "s|\$username *= *\".*\";|\$username = \"$DB_USER\";|" \
      -e "s|\$password *= *\".*\";|\$password = \"$DB_PASS\";|" \
      -e "s|\$dbname *= *\".*\";|\$dbname = \"$DB_NAME\";|" \
      /var/www/html/index.php
fi

chown -R apache:apache /var/www/html
systemctl enable --now httpd

echo "=== Настройка HQ-SRV завершена ==="
exit 0