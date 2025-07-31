#!/bin/bash

set -e

# Función para validar identificadores simples (alfanuméricos y guiones bajos)
valid_input() {
  [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Cargar .env si existe
if [ -f ".env" ]; then
  echo "🔄 Cargando configuración de .env..."
  export $(grep -v '^#' .env | xargs)
fi

# Validación de variables necesarias
if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_DOMAIN" ] || [ -z "$VPS_USER" ]; then
  echo "❌ Faltan CF_API_TOKEN, CF_DOMAIN o VPS_USER en el archivo .env" >&2
  exit 1
fi

echo "📝 Comenzando configuración interactiva..."

# Prompt inicial
read -r -p "Introduce el subdominio para el nuevo proyecto Laravel (solo el subdominio): " SUBDOMAIN
while ! valid_input "$SUBDOMAIN"; do
  echo "❌ Subdominio inválido. Debe contener solo letras, números y guiones bajos."
  read -r -p "Introduce el subdominio para este VPS (se usará como subdominio.$CF_DOMAIN): " SUBDOMAIN
done
FULL_HOSTNAME="$SUBDOMAIN.$CF_DOMAIN"
LARAVEL_PATH="/home/$VPS_USER/$SUBDOMAIN"

# Introduce la contraseña de MariaDB para el usuario '$VPS_USER' (ya existente)
read -s -p "Introduce la contraseña de MariaDB para el usuario '$VPS_USER': " DB_PASS; echo

# Introduce la contraseña de MariaDB para el usuario 'root'
read -s -p "Introduce la contraseña de MariaDB para el usuario 'root': " MARIADB_ROOT_PASS; echo

# Introduce el correo electrónico para Let's Encrypt
read -r -p "Correo electrónico para Let's Encrypt: " EMAIL

# Obtener IP pública
SERVER_IP=$(curl -s https://api.ipify.org)

# Obtener Zone ID
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_DOMAIN" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$CF_ZONE_ID" ] || [ "$CF_ZONE_ID" == "null" ]; then
  echo "❌ No se pudo obtener el Zone ID para $CF_DOMAIN" >&2
  exit 1
fi

# Crear registro DNS si no existe
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

# Crear proyecto Laravel
sudo -u "$VPS_USER" bash -lc "export PATH=\$HOME/.config/herd-lite/bin:\$PATH && cd /home/$VPS_USER && composer create-project laravel/laravel $SUBDOMAIN"
echo "✅ Proyecto Laravel creado en $LARAVEL_PATH"

# Establecer permisos
echo "🔐 Estableciendo permisos para Laravel..."
chown -R www-data:www-data "$LARAVEL_PATH/storage" "$LARAVEL_PATH/bootstrap/cache"
chmod -R 775 "$LARAVEL_PATH/storage" "$LARAVEL_PATH/bootstrap/cache"
echo "✅ Permisos establecidos."

# Crear base de datos
mysql -u root -p"$MARIADB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS \`$SUBDOMAIN\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`$SUBDOMAIN\`.* TO '$VPS_USER'@'localhost' IDENTIFIED BY '${DB_PASS//\'/\\\'}';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Configurar .env de Laravel
LARAVEL_ENV="$LARAVEL_PATH/.env"
sed -i '/^# DB_HOST=/c\DB_HOST=127.0.0.1' "$LARAVEL_ENV"
sed -i '/^# DB_PORT=/c\DB_PORT=3306' "$LARAVEL_ENV"
sed -i '/^# DB_DATABASE=/c\DB_DATABASE='$SUBDOMAIN "$LARAVEL_ENV"
sed -i '/^# DB_USERNAME=/c\DB_USERNAME='$VPS_USER "$LARAVEL_ENV"
sed -i '/^# DB_PASSWORD=/c\DB_PASSWORD='$DB_PASS "$LARAVEL_ENV"
sed -i 's/^DB_CONNECTION=.*/DB_CONNECTION=mysql/' "$LARAVEL_ENV"
chown "$VPS_USER:$VPS_USER" "$LARAVEL_ENV"
echo "✅ .env de Laravel actualizado"

# Ejecutar migraciones de Laravel
echo "🛠 Ejecutando migraciones de Laravel..."
sudo -u "$VPS_USER" bash -lc "export PATH=\$HOME/.config/herd-lite/bin:\$PATH && cd $LARAVEL_PATH && php artisan migrate --force"

# Obtener versión PHP
HERD_PHP_BIN="/home/$VPS_USER/.config/herd-lite/bin/php"
PHP_VERSION=$($HERD_PHP_BIN -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;")
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

# Configuración temporal en Nginx
cat > "/etc/nginx/sites-available/$SUBDOMAIN" <<EOF
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
}
EOF

ln -sf "/etc/nginx/sites-available/$SUBDOMAIN" "/etc/nginx/sites-enabled/$SUBDOMAIN"
nginx -t && systemctl reload nginx

# SSL con Certbot
certbot certonly --webroot -w "$LARAVEL_PATH/public" -d "$FULL_HOSTNAME" --non-interactive --agree-tos -m "$EMAIL"

if [ -f "/etc/letsencrypt/live/$FULL_HOSTNAME/fullchain.pem" ]; then
  echo "✅ Certificado generado. Configurando HTTPS en Nginx..."

  cat > "/etc/nginx/sites-available/$SUBDOMAIN" <<EOF
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

    ssl_certificate /etc/letsencrypt/live/$FULL_HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FULL_HOSTNAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    access_log /var/log/nginx/${SUBDOMAIN}.access.log;
    error_log  /var/log/nginx/${SUBDOMAIN}.error.log;
}
EOF

  nginx -t && systemctl reload nginx
  echo "✅ Configuración HTTPS completada."
else
  echo "❌ Falló la generación del certificado SSL." >&2
fi

echo "🎉 Proyecto Laravel desplegado correctamente."
echo "🌍 URL: https://$FULL_HOSTNAME"
echo "📂 Ruta: /home/$VPS_USER/$SUBDOMAIN"
