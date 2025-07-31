# SETUP VPS

Script interactivo para preparar una VPS con:

- Cambio de hostname con dominio `.tu.dominio`
- Registro DNS automático en Cloudflare
- Instalación opcional de:
  - Laravel
  - MySQL
  - Nginx + Let's Encrypt

## Requisitos

- Una cuenta en Cloudflare con tu dominio configurado y el token de API generado.
- Acceso SSH a la VPS.
- Archivo `.env` con las siguientes variables:

```
CF_API_TOKEN=tu_token
CF_DOMAIN=tu.dominio
VPS_USER=tu_usuario
```

## Uso

```bash
git clone https://github.com/GoRhY/new-vps.git
cd new-vps
cp .env.sample .env
nano .env
chmod +x vps-setup.sh
sudo ./vps-setup.sh
```

Para añadir nuevos proyectos al VPS, usar el archivo project-setup.sh

```bash
chmod +x project-setup.sh
sudo ./project-setup.sh
```
