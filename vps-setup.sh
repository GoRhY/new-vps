#!/bin/bash

set -e

# Función para cambiar el timezone de forma automática
CLIENT_IP=$(who | awk '{print $5}' | tr -d '()' | head -n 1)
echo "🌍 Detectando timezone automáticamente para la IP: $CLIENT_IP"
TIMEZONE=$(curl -s "http://ip-api.com/json/$CLIENT_IP?fields=timezone" | grep -oP '"timezone"\s*:\s*"\K[^"]+')
if [ -z "$TIMEZONE" ]; then
  echo "❌ No se pudo determinar el timezone automáticamente. Por favor, configúralo manualmente."
else
  echo "🌍 Estableciendo timezone a: $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE"
fi

# Función para validar identificadores simples (alfanuméricos y guiones bajos)
valid_input() {
  [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Verificar si es root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Este script debe ejecutarse como root." >&2
  exit 1
fi

# Detectar sistema operativo
if [ -f /etc/debian_version ]; then
  echo "🔍 Sistema compatible detectado: Debian/Ubuntu"
else
  echo "❌ Este script solo es compatible con Debian o Ubuntu." >&2
  exit 1
fi

# Cargar .env si existe
if [ -f ".env" ]; then
  echo "🔄 Cargando configuración de .env..."
  export $(grep -v '^#' .env | xargs)
fi

# Comprobar variables necesarias
if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_DOMAIN" ] || [ -z "$VPS_USER" ]; then
  echo "❌ Faltan CF_API_TOKEN, CF_DOMAIN o VPS_USER en el archivo .env" >&2
  exit 1
fi

# ───────────
# Sección de prompts interactivos
# ───────────
echo "📝 Comenzando configuración interactiva..."

# Subdominio y hostname completo
read -r -p "Introduce el subdominio para este VPS (se usará como subdominio.$CF_DOMAIN): " SUBDOMAIN
while ! valid_input "$SUBDOMAIN"; do
  echo "❌ Subdominio inválido. Debe contener solo letras, números y guiones bajos."
  read -r -p "Introduce el subdominio para este VPS (se usará como subdominio.$CF_DOMAIN): " SUBDOMAIN
done
FULL_HOSTNAME="${SUBDOMAIN}.${CF_DOMAIN}"

# Puerto SSH
read -r -p "Introduce el puerto SSH que quieres utilizar: " SSH_PORT
while ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; do
  echo "❌ Puerto SSH inválido. Debe ser un número entre 1 y 65535."
  read -r -p "Introduce el puerto SSH que quieres utilizar: " SSH_PORT
done

# Contraseña de usuario
read -s -p "Introduce la contraseña para el usuario '$VPS_USER': " USER_PASS; echo

# Actualización del sistema
read -r -p "¿Quieres actualizar el sistema? (s/n): " UPDATE_SYSTEM

# Clave pública SSH
read -r -p "¿Quieres añadir una clave pública SSH para '$VPS_USER'? (s/n): " ADD_KEY
if [[ "$ADD_KEY" =~ ^[Ss]$ ]]; then
  read -r -p "Pega la clave pública (ssh-rsa...): " SSH_KEY
fi

# Preparación para Laravel
read -r -p "¿Quieres preparar el sistema para usar Laravel? (s/n): " INSTALL_LARAVEL
if [[ "$INSTALL_LARAVEL" =~ ^[Ss]$ ]]; then
  # Instalación de MariaDB
  read -r -p "¿Quieres instalar MariaDB para usar con Laravel? (s/n): " INSTALL_MARIADB
  if [[ "$INSTALL_MARIADB" =~ ^[Ss]$ ]]; then
    read -s -p "Contraseña para el usuario root de MariaDB: " MARIADB_ROOT_PASS; echo
    read -s -p "Contraseña para el usuario '$VPS_USER': " DB_PASS; echo
  fi

  # Instalación de Nginx + SSL
  read -r -p "¿Quieres instalar Nginx y configurar SSL con Let's Encrypt para $FULL_HOSTNAME? (s/n): " INSTALL_HTTPS
  if [[ "$INSTALL_HTTPS" =~ ^[Ss]$ ]]; then
    read -r -p "Escribe tu correo electrónico para Let's Encrypt: " EMAIL
  fi
fi

# Reinicio al final
read -r -p "¿Quieres reiniciar el servidor ahora para aplicar posibles actualizaciones del kernel? (s/n): " REBOOT_NOW

# Obtener IP pública
SERVER_IP=$(curl -s https://api.ipify.org)
if [ -z "$SERVER_IP" ]; then
  echo "❌ No se pudo obtener la IP pública." >&2
  exit 1
fi

# Obtener Zone ID por API
echo "🔍 Obteniendo Zone ID para $CF_DOMAIN desde Cloudflare..."
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_DOMAIN" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$CF_ZONE_ID" ] || [ "$CF_ZONE_ID" == "null" ]; then
  echo "❌ No se pudo obtener el Zone ID para $CF_DOMAIN" >&2
  exit 1
fi

# Crear registro A en Cloudflare si no existe
echo "🌐 Comprobando si ya existe el registro DNS $FULL_HOSTNAME..."
EXISTING_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$FULL_HOSTNAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json")

if echo "$EXISTING_RECORD" | grep -q '"count":0'; then
  echo "📡 Creando registro DNS $FULL_HOSTNAME -> $SERVER_IP en Cloudflare..."
  CREATE_RESULT=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(printf '{
      "type": "A",
      "name": "%s",
      "content": "%s",
      "ttl": 120,
      "proxied": false
    }' "$FULL_HOSTNAME" "$SERVER_IP")")

  if [[ "$CREATE_RESULT" != *'"success":true'* ]]; then
    echo "⚠️ Error creando el registro DNS en Cloudflare:" >&2
    echo "$CREATE_RESULT"
    exit 1
  fi
  echo "✅ Registro DNS creado."
else
  echo "✅ El registro DNS $FULL_HOSTNAME ya existe."
fi

# Establecer hostname en el sistema
echo "🔧 Estableciendo hostname a: $FULL_HOSTNAME"
hostnamectl set-hostname "$FULL_HOSTNAME"
if ! grep -q "$FULL_HOSTNAME" /etc/hosts; then
  echo "127.0.1.1 $FULL_HOSTNAME" >> /etc/hosts
fi

# Crear usuario
echo
useradd -m -s /bin/bash "$VPS_USER"
echo "$VPS_USER:$USER_PASS" | chpasswd
usermod -aG sudo "$VPS_USER"
echo "✅ Usuario '$VPS_USER' creado y añadido a sudoers."

# Actualizar sistema
if [[ "$UPDATE_SYSTEM" =~ ^[Ss]$ ]]; then
  echo "⏳ Actualizando sistema..."
  apt update && apt -y upgrade
  echo "✅ Sistema actualizado."
else
  echo "ℹ️ No se actualizará el sistema."
fi

# Crear .ssh y clave pública
mkdir -p "/home/$VPS_USER/.ssh"
chmod 700 "/home/$VPS_USER/.ssh"
chown "$VPS_USER:$VPS_USER" "/home/$VPS_USER/.ssh"

if [[ "$ADD_KEY" =~ ^[Ss]$ ]]; then
  echo "$SSH_KEY" > "/home/$VPS_USER/.ssh/authorized_keys"
  chmod 600 "/home/$VPS_USER/.ssh/authorized_keys"
  chown "$VPS_USER:$VPS_USER" "/home/$VPS_USER/.ssh/authorized_keys"
  echo "✅ Clave pública añadida"
fi

# Cambiar puerto SSH
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config

if command -v ufw >/dev/null; then
  ufw allow $SSH_PORT/tcp
  echo "✅ Puerto $SSH_PORT abierto en UFW."
fi

systemctl restart ssh

# Laravel + PHP
if [[ "$INSTALL_LARAVEL" =~ ^[Ss]$ ]]; then
  echo "⏳ Instalando unzip para composer..."
  apt install -y unzip
  echo "⏳ Instalando PHP y Composer con php.new..."
  sudo -u "$VPS_USER" bash -c 'bash -c "$(curl -fsSL https://php.new/install/linux/)"'
  echo "✅ PHP y Composer instalados para el usuario '$VPS_USER'"

  COMPOSER_BIN=$(sudo -u $VPS_USER find /home/$VPS_USER -type f -name composer | grep herd-lite | head -n1)

  if [ -n "$COMPOSER_BIN" ]; then
    echo "✅ Composer detectado en: $COMPOSER_BIN"
    ln -sf "$COMPOSER_BIN" /usr/local/bin/composer
    echo "🔗 Symlink creado en /usr/local/bin/composer"
  else
    echo "⚠️ No se encontró Composer en Herd Lite. Puede que la instalación haya fallado." >&2
  fi

  LARAVEL_PROJECT="$SUBDOMAIN"

  sudo -u "$VPS_USER" bash -lc "export PATH=\$HOME/.config/herd-lite/bin:\$PATH && cd /home/$VPS_USER && composer create-project laravel/laravel $LARAVEL_PROJECT"
  echo "✅ Proyecto Laravel creado en /home/$VPS_USER/$LARAVEL_PROJECT"
  echo "🔐 Estableciendo permisos para Laravel..."
  chown -R www-data:www-data "/home/$VPS_USER/$LARAVEL_PROJECT/storage" "/home/$VPS_USER/$LARAVEL_PROJECT/bootstrap/cache"
  chmod -R 775 "/home/$VPS_USER/$LARAVEL_PROJECT/storage" "/home/$VPS_USER/$LARAVEL_PROJECT/bootstrap/cache"
  usermod -aG $VPS_USER www-data
  chmod 750 /home/$VPS_USER
  echo "✅ Permisos establecidos."

fi

# MariaDB opcional
if [[ "$INSTALL_MARIADB" =~ ^[Ss]$ ]]; then
  apt install -y mariadb-server mariadb-client

  if ! command -v mysql >/dev/null; then
    echo "❌ MariaDB no se instaló correctamente." >&2
    exit 1
  fi

  echo

  DB_NAME="$SUBDOMAIN"
  DB_USER="$VPS_USER"

  echo

  mysql -u root <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASS//\'/\\\'}';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASS//\'/\\\'}';
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '${DB_PASS//\'/\\\'}';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

  if [[ -n "$LARAVEL_PROJECT" ]]; then
    LARAVEL_ENV="/home/$VPS_USER/$LARAVEL_PROJECT/.env"
    sed -i '/^# DB_HOST=/c\DB_HOST=127.0.0.1' "$LARAVEL_ENV"
    sed -i '/^# DB_PORT=/c\DB_PORT=3306' "$LARAVEL_ENV"
    sed -i '/^# DB_DATABASE=/c\DB_DATABASE='$DB_NAME "$LARAVEL_ENV"
    sed -i '/^# DB_USERNAME=/c\DB_USERNAME='$DB_USER "$LARAVEL_ENV"
    sed -i '/^# DB_PASSWORD=/c\DB_PASSWORD='$DB_PASS "$LARAVEL_ENV"
    sed -i 's/^DB_CONNECTION=.*/DB_CONNECTION=mysql/' "$LARAVEL_ENV"
    chown "$VPS_USER:$VPS_USER" "$LARAVEL_ENV"
    echo "✅ .env de Laravel actualizado"
    # Ejecutar migraciones de Laravel
    echo "🛠 Ejecutando migraciones de Laravel..."
    sudo -u "$VPS_USER" bash -lc "export PATH=\$HOME/.config/herd-lite/bin:\$PATH && cd /home/$VPS_USER/$LARAVEL_PROJECT && php artisan migrate --force"
  fi
fi

# Nginx + Let's Encrypt opcional
if [[ "$INSTALL_HTTPS" =~ ^[Ss]$ && -n "$LARAVEL_PROJECT" ]]; then
  apt install -y nginx certbot python3-certbot-nginx

  # Aumentar server_names_hash_bucket_size en nginx.conf si no existe o está comentado
  NGINX_CONF="/etc/nginx/nginx.conf"
  if grep -q "http {" "$NGINX_CONF"; then
    if grep -Eq "^\s*#?\s*server_names_hash_bucket_size" "$NGINX_CONF"; then
      echo "🔧 Corrigiendo server_names_hash_bucket_size en nginx.conf..."
      sed -i 's/^\s*#\?\s*server_names_hash_bucket_size.*/    server_names_hash_bucket_size 64;/' "$NGINX_CONF"
    else
      echo "🔧 Añadiendo server_names_hash_bucket_size a nginx.conf..."
      sed -i '/http {/a \    server_names_hash_bucket_size 64;' "$NGINX_CONF"
    fi
  fi

  LARAVEL_PATH="/home/$VPS_USER/$LARAVEL_PROJECT"
  HERD_PHP_BIN="/home/$VPS_USER/.config/herd-lite/bin/php"
  PHP_VERSION=$($HERD_PHP_BIN -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;")
  PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

  if [ ! -e "$PHP_FPM_SOCK" ]; then
    echo "⚠️  php-fpm no está instalado para PHP $PHP_VERSION. Instalando desde PPA ondrej/php..."

    # Instalar software-properties-common si no existe
    if ! command -v add-apt-repository >/dev/null; then
      apt update
      apt install -y software-properties-common
    fi

    # Añadir el PPA de Ondřej si no existe
    if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
      add-apt-repository -y ppa:ondrej/php
      apt update
    fi

    # Instalar php-fpm y módulos básicos
    apt install -y php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml

    # Verificar si se creó el socket correctamente
    if [ -e "$PHP_FPM_SOCK" ]; then
      echo "✅ php-fpm instalado correctamente para PHP $PHP_VERSION"
    else
      echo "❌ Fallo al instalar php-fpm para PHP $PHP_VERSION. Revisa la instalación manualmente." >&2
      exit 1
    fi
  fi

  # Configuración temporal solo HTTP para validación SSL
  cat > /etc/nginx/sites-available/laravel <<EOF
server {
    listen 80;
    server_name $FULL_HOSTNAME;

    root $LARAVEL_PATH/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /.well-known/acme-challenge/ {
        root $LARAVEL_PATH/public;
        allow all;
    }

    access_log /var/log/nginx/laravel.access.log;
    error_log  /var/log/nginx/laravel.error.log;
}
EOF

  ln -sf /etc/nginx/sites-available/laravel /etc/nginx/sites-enabled/laravel
  nginx -t && systemctl reload nginx

  # Lanzar certbot en modo webroot
  certbot certonly --webroot -w "$LARAVEL_PATH/public" -d "$FULL_HOSTNAME" --non-interactive --agree-tos -m "$EMAIL"

  if [ -f /etc/letsencrypt/live/$FULL_HOSTNAME/fullchain.pem ]; then
    echo "✅ Certificado generado. Configurando SSL en Nginx..."

    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
      echo "🔧 Descargando configuración SSL recomendada de Let's Encrypt..."
      curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf
    fi

    # Reconstruir la config de Nginx con HTTPS y alias phpMyAdmin opcional
    PMA_BLOCK=""
    if [[ "$INSTALL_PMA" =~ ^[Ss]$ ]]; then
      PMA_BLOCK=$(cat <<PMABLOCK
    location /phpmyadmin {
        root /usr/share/;
        index index.php index.html index.htm;
        location ~ ^/phpmyadmin/(.+\\.php)$ {
            root /usr/share/;
            fastcgi_pass unix:$PHP_FPM_SOCK;
            include snippets/fastcgi-php.conf;
        }
        location ~* ^/phpmyadmin/(.+\\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            root /usr/share/;
        }
    }
    location /phpMyAdmin {
        return 301 /phpmyadmin;
    }
PMABLOCK
      )
    fi

    cat > /etc/nginx/sites-available/laravel <<EOF
server {
    listen 80;
    server_name $FULL_HOSTNAME;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $FULL_HOSTNAME;

    root $LARAVEL_PATH/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
    }

    location ~ /\.ht {
        deny all;
    }

    location ^~ /.well-known/acme-challenge/ {
        root $LARAVEL_PATH/public;
        allow all;
    }

$PMA_BLOCK

    access_log /var/log/nginx/laravel.access.log;
    error_log  /var/log/nginx/laravel.error.log;

    ssl_certificate /etc/letsencrypt/live/$FULL_HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_HOSTNAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
}
EOF

    echo "✅ Configuración SSL completada. Recargando Nginx..."
    nginx -t && systemctl reload nginx
  else
    echo "❌ No se generó el certificado. Revisa el log de Certbot." >&2
  fi
fi

echo
if [[ "$REBOOT_NOW" =~ ^[Ss]$ ]]; then
  echo
  echo "🎉 VPS configurada correctamente."
  echo "ℹ️  Accede con: ssh -p $SSH_PORT $VPS_USER@$FULL_HOSTNAME"
  echo "♻️ Reiniciando el servidor..."
  sleep 5 && reboot
else
  echo "⚠️  Recuerda que puede ser necesario reiniciar manualmente para aplicar algunos cambios del kernel."
  echo
  echo "🎉 VPS configurada correctamente."
  echo "ℹ️  Accede con: ssh -p $SSH_PORT $VPS_USER@$FULL_HOSTNAME"
fi