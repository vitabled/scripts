#!/bin/bash

# Цвета для удобства
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Настройка SSL сертификата для Remnawave/Remnanode ===${NC}"

# 1. Проверка пути установки
if [ -d "/opt/remnanode" ]; then
    BASE_DIR="/opt/remnanode"
elif [ -d "/opt/remnawave" ]; then
    BASE_DIR="/opt/remnawave"
else
    echo -e "${RED}Ошибка: Директория ноды не найдена в /opt/remnanode или /opt/remnawave${NC}"
    exit 1
fi

# 2. Интерактивный сбор данных
echo -e "${YELLOW}Введите данные для получения сертификата:${NC}"
read -p "Домен (например, node.example.com): " DOMAIN
read -p "Email для уведомлений Let's Encrypt: " EMAIL

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo -e "${RED}Ошибка: Домен и Email не могут быть пустыми!${NC}"
    exit 1
fi

# 3. Создание структуры Certbot
CERT_DIR="$BASE_DIR/certbot"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo -e "${GREEN}Создание конфигурации Certbot...${NC}"
cat <<EOF > docker-compose.yml
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
EOF

# 4. Освобождение порта 80
echo -e "${YELLOW}Проверка порта 80...${NC}"
if command -v ufw > /dev/null; then
    sudo ufw allow 80/tcp > /dev/null
fi

# Останавливаем потенциальные процессы на 80 порту (на всякий случай)
fuser -k 80/tcp > /dev/null 2>&1

# 5. Первичное получение сертификата
echo -e "${GREEN}Запуск Certbot для домена $DOMAIN...${NC}"
docker run --rm \
  -v "$CERT_DIR/certs:/etc/letsencrypt" \
  -v "$CERT_DIR/var-lib-letsencrypt:/var/lib/letsencrypt" \
  --network host \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

if [ $? -ne 0 ]; then
    echo -e "${RED}Критическая ошибка: Не удалось получить сертификат.${NC}"
    exit 1
fi

# 6. Настройка автопродления в Cron
CRON_JOB="0 0 28 * * cd $CERT_DIR && docker compose run --rm certbot renew && cd $BASE_DIR && docker compose restart"
(crontab -l 2>/dev/null | grep -v "certbot renew" ; echo "$CRON_JOB") | crontab -
echo -e "${GREEN}Задача автопродления добавлена в crontab (каждое 28 число).${NC}"

# 7. Инъекция сертификатов в основной docker-compose.yml ноды
MAIN_COMPOSE="$BASE_DIR/docker-compose.yml"

if [ -f "$MAIN_COMPOSE" ]; then
    echo -e "${YELLOW}Настройка проброса сертификатов в ноду...${NC}"
    
    # Проверяем, не добавлен ли уже этот Volume
    if grep -q "etc/letsencrypt:ro" "$MAIN_COMPOSE"; then
        echo -e "${GREEN}Конфигурация уже содержит пути к сертификатам.${NC}"
    else
        # Ищем секцию volumes внутри remnanode/remnawave и добавляем путь
        # Используем простую замену: ищем 'volumes:' и добавляем строку после неё
        sed -i "/volumes:/a \      - '$CERT_DIR/certs:/etc/letsencrypt:ro'" "$MAIN_COMPOSE"
        echo -e "${GREEN}Пути к сертификатам добавлены в $MAIN_COMPOSE${NC}"
    fi

    # 8. Перезапуск основного приложения
    echo -e "${GREEN}Перезапуск контейнеров...${NC}"
    cd "$BASE_DIR"
    docker compose down && docker compose up -d
    echo -e "${GREEN}Все готово! Проверьте работу ноды по HTTPS.${NC}"
else
    echo -e "${RED}Файл $MAIN_COMPOSE не найден. Проброс томов не выполнен.${NC}"
fi
