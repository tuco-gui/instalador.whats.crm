#!/bin/bash
#
# functions for setting up app backend

# Helper: executa como deploy com HOME/PM2_HOME corretos
_run_as_deploy() {
  sudo -u deploy -H env \
    HOME=/home/deploy \
    PM2_HOME=/home/deploy/.pm2 \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -lc "$*"
}

#######################################
# cria Redis (docker) e garante Postgres (db/usuário) — idempotente
#######################################
backend_redis_create() {
  print_banner
  printf "${WHITE} 💻 Criando Redis & Banco Postgres...${GRAY_LIGHT}\n\n"
  sleep 2

  # Redis via Docker (mudando porta para evitar conflito)
  sudo bash -lc "
    usermod -aG docker deploy || true
    if ! docker ps -a --format '{{.Names}}' | grep -q '^redis-${instancia_add}\$'; then
      docker run --name redis-${instancia_add} \
        -p ${redis_port:-6380}:6379 \
        --restart always \
        --detach redis \
        redis-server --requirepass ${mysql_root_password}
    else
      docker start redis-${instancia_add} >/dev/null 2>&1 || true
    fi
  "

  sleep 2

  # Postgres: cria DB/USER se não existirem (porta diferente)
  sudo -u postgres bash -lc "
    DB_EXISTS=\$(psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${instancia_add}';\")
    if [ \"\$DB_EXISTS\" != \"1\" ]; then
      createdb -p 5433 ${instancia_add}
    fi

    USER_EXISTS=\$(psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${instancia_add}';\")
    if [ \"\$USER_EXISTS\" != \"1\" ]; then
      psql -p 5433 -v ON_ERROR_STOP=1 <<SQL
CREATE USER ${instancia_add} SUPERUSER INHERIT CREATEDB CREATEROLE LOGIN PASSWORD '${mysql_root_password}';
SQL
    else
      psql -p 5433 -v ON_ERROR_STOP=1 -c \"ALTER USER ${instancia_add} PASSWORD '${mysql_root_password}';\"
    fi
  "

  sleep 2
}

#######################################
# escreve .env do backend
#######################################
backend_set_env() {
  print_banner
  printf "${WHITE} 💻 Configurando variáveis de ambiente (backend)...${GRAY_LIGHT}\n\n"
  sleep 2

  backend_url=$(echo "${backend_url/https:\/\/}")
  backend_url=${backend_url%%/*}
  backend_url="https://${backend_url}"

  frontend_url=$(echo "${frontend_url/https:\/\/}")
  frontend_url=${frontend_url%%/*}
  frontend_url="https://${frontend_url}"

  _run_as_deploy "
    cat > /home/deploy/${instancia_add}/backend/.env <<'EOFENV'
NODE_ENV=production
BACKEND_URL=${backend_url}
FRONTEND_URL=${frontend_url}
PROXY_PORT=443
PORT=${backend_port}

DB_HOST=localhost
DB_DIALECT=postgres
DB_PORT=5433
DB_USER=${instancia_add}
DB_PASS=${mysql_root_password}
DB_NAME=${instancia_add}

JWT_SECRET=${jwt_secret}
JWT_REFRESH_SECRET=${jwt_refresh_secret}

REDIS_URI=redis://:${mysql_root_password}@127.0.0.1:${redis_port:-6380}
REDIS_OPT_LIMITER_MAX=1
REDIS_OPT_LIMITER_DURATION=3000

USER_LIMIT=${max_user}
CONNECTIONS_LIMIT=${max_whats}
CLOSED_SEND_BY_ME=true
EOFENV
  "

  sleep 2
}

#######################################
# configura Nginx para backend (reverse-proxy)
#######################################
backend_nginx_setup() {
  print_banner
  printf "${WHITE} 💻 Configurando nginx (backend)...${GRAY_LIGHT}\n\n"
  sleep 2

  backend_hostname=$(echo "${backend_url/https:\/\/}")

  sudo bash -lc "
cat > /etc/nginx/sites-available/${instancia_add}-backend <<EOF
server {
  server_name ${backend_hostname};

  location / {
    proxy_pass http://127.0.0.1:${backend_port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \"upgrade\";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF

ln -sf /etc/nginx/sites-available/${instancia_add}-backend /etc/nginx/sites-enabled/${instancia_add}-backend
nginx -t && systemctl reload nginx
"
  sleep 2
}
