#!/bin/bash
#
# functions for setting up app frontend

# Helper: executa como deploy com HOME/PM2_HOME corretos
_run_as_deploy() {
  sudo -u deploy -H env \
    HOME=/home/deploy \
    PM2_HOME=/home/deploy/.pm2 \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -lc "$*"
}

#######################################
# instala dependências do frontend
#######################################
frontend_node_dependencies() {
  print_banner
  printf "${WHITE} 💻 Instalando dependências do frontend...${GRAY_LIGHT}\n\n"
  sleep 2

  _run_as_deploy "
    cd /home/deploy/${instancia_add}/frontend
    if [ -f package-lock.json ]; then
      npm ci --force
    else
      npm install --force
    fi
  "

  sleep 2
}

#######################################
# compila o frontend
#######################################
frontend_node_build() {
  print_banner
  printf "${WHITE} 💻 Compilando o código do frontend...${GRAY_LIGHT}\n\n"
  sleep 2

  _run_as_deploy "
    cd /home/deploy/${instancia_add}/frontend
    npm run build
  "

  sleep 2
}

#######################################
# atualiza o frontend
#######################################
frontend_update() {
  print_banner
  printf "${WHITE} 💻 Atualizando o frontend...${GRAY_LIGHT}\n\n"
  sleep 2

  _run_as_deploy "
    cd /home/deploy/${empresa_atualizar}
    pm2 stop ${empresa_atualizar}-frontend || true
    git pull
    cd /home/deploy/${empresa_atualizar}/frontend
    if [ -f package-lock.json ]; then
      npm ci --force
    else
      npm install --force
    fi
    rm -rf build
    npm run build
    pm2 start /home/deploy/${empresa_atualizar}/frontend/server.js --name ${empresa_atualizar}-frontend --update-env --time
    pm2 save
  "

  sleep 2
}

#######################################
# cria .env e server.js do frontend
#######################################
frontend_set_env() {
  print_banner
  printf "${WHITE} 💻 Configurando variáveis de ambiente (frontend)...${GRAY_LIGHT}\n\n"
  sleep 2

  backend_url=$(echo "${backend_url/https:\/\/}")
  backend_url=${backend_url%%/*}
  backend_url="https://${backend_url}"

  # .env
  _run_as_deploy "
    cat > /home/deploy/${instancia_add}/frontend/.env <<'EOFENV'
REACT_APP_BACKEND_URL=${backend_url}
REACT_APP_HOURS_CLOSE_TICKETS_AUTO=24
EOFENV
  "

  # server.js
  _run_as_deploy "
    cat > /home/deploy/${instancia_add}/frontend/server.js <<'EOFSRV'
// simple express server to run frontend production build
const express = require('express');
const path = require('path');
const app = express();

app.use(express.static(path.join(__dirname, 'build')));
app.get('/*', function (req, res) {
  res.sendFile(path.join(__dirname, 'build', 'index.html'));
});

app.listen(${frontend_port});
EOFSRV
  "

  sleep 2
}

#######################################
# inicia pm2 do frontend
#######################################
frontend_start_pm2() {
  print_banner
  printf "${WHITE} 💻 Iniciando pm2 (frontend)...${GRAY_LIGHT}\n\n"
  sleep 2

  _run_as_deploy "mkdir -p /home/deploy/.pm2"

  if [ ! -f /etc/systemd/system/pm2-deploy.service ]; then
    sudo env PATH=$PATH:/usr/bin \
      /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u deploy --hp /home/deploy >/dev/null
  fi

  _run_as_deploy "
    cd /home/deploy/${instancia_add}/frontend
    pm2 start server.js --name ${instancia_add}-frontend --update-env --time
    pm2 save
  "

  sudo systemctl enable pm2-deploy.service >/dev/null 2>&1 || true
  sudo systemctl start  pm2-deploy.service >/dev/null 2>&1 || true

  sleep 2
}

#######################################
# configura nginx (frontend)
#######################################
frontend_nginx_setup() {
  print_banner
  printf "${WHITE} 💻 Configurando nginx (frontend)...${GRAY_LIGHT}\n\n"
  sleep 2

  frontend_hostname=$(echo "${frontend_url/https:\/\/}")

  sudo bash -lc "
cat > /etc/nginx/sites-available/${instancia_add}-frontend <<EOF
server {
  server_name ${frontend_hostname};

  location / {
    proxy_pass http://127.0.0.1:${frontend_port};
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

ln -sf /etc/nginx/sites-available/${instancia_add}-frontend /etc/nginx/sites-enabled/${instancia_add}-frontend
nginx -t && systemctl reload nginx
"

  sleep 2
}

