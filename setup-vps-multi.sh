#!/bin/bash

set -e

# Verificar si es root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Este script debe ejecutarse como root." >&2
  exit 1
fi

# Cargar configuración de Cloudflare y usuario
if [ -f ".env" ]; then
  echo "🔄 Cargando configuración de .env..."
  export $(grep -v '^#' .env | xargs)
fi

if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_DOMAIN" ] || [ -z "$VPS_USER" ]; then
  echo "❌ Faltan CF_API_TOKEN, CF_DOMAIN o VPS_USER en el archivo .env" >&2
  exit 1
fi

# Solicitar subdominio
read -p "Introduce el subdominio para el nuevo proyecto Laravel (ej: tienda): " SUB
FULL_HOST="${SUB}.${CF_DOMAIN}"

# Obtener Zone ID por API
echo "🔍 Obteniendo Zone ID para $CF_DOMAIN desde Cloudflare..."
CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_DOMAIN" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ -z "$CF_ZONE_ID" ] || [ "$CF_ZONE_ID" == "null" ]; then
  echo "❌ No se pudo obtener el Zone ID para $CF_DOMAIN" >&2
  exit 1
fi

# Comprobar si existe ya el registro
echo "🌐 Comprobando si ya existe el registro DNS $FULL_HOST..."
EXISTING_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$FULL_HOST" \
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

else
  echo "✅ El registro DNS $FULL_HOST ya existe."
fi

# Validar que composer esté disponible
if ! command -v composer >/dev/null; then
  echo "❌ Composer no está disponible en el PATH. ¿Olvidaste ejecutar el script de setup inicial?" >&2
  exit 1
fi

# Crear el proyecto Laravel
echo "📦 Creando nuevo proyecto Laravel: $SUB"
sudo -u "$VPS_USER" bash -c "cd /home/$VPS_USER && composer create-project laravel/laravel $SUB"
if [ ! -d "/home/$VPS_USER/$SUB" ]; then
  echo "❌ Error al crear el proyecto Laravel." >&2
  exit 1
fi
LARAVEL_PATH="/home/$VPS_USER/$SUB"

# Detectar versión de PHP y generar virtual host Nginx
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

cat > /etc/nginx/sites-available/$SUB <<EOF
server {
    listen 80;
    server_name $FULL_HOST;

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

    access_log /var/log/nginx/$SUB.access.log;
    error_log  /var/log/nginx/$SUB.error.log;
}
EOF

ln -s /etc/nginx/sites-available/$SUB /etc/nginx/sites-enabled/$SUB
if nginx -t; then
  systemctl reload nginx
else
  echo "❌ Error en la configuración de Nginx. No se recargó el servicio." >&2
  exit 1
fi

# Certbot para HTTPS
certbot --nginx -d "$FULL_HOST" --non-interactive --agree-tos -m "admin@$FULL_HOST"

# Añadir a /etc/hosts si no existe (opcional)
if ! grep -q "$FULL_HOST" /etc/hosts; then
  echo "127.0.0.1 $FULL_HOST" >> /etc/hosts
fi

echo
echo "🎉 Proyecto Laravel desplegado correctamente."
echo "🌍 URL: https://$FULL_HOST"
echo "📂 Ruta: /home/$VPS_USER/$SUB"