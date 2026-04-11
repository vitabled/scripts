#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> Запуск скрипта настройки SSL для Remnawave/Remnanode...${NC}"

# 1. Определение директории (автоматически)
if [ -d "/opt/remnanode" ]; then
    BASE_DIR="/opt/remnanode"
elif [ -d "/opt/remnawave" ]; then
    BASE_DIR="/opt/remnawave"
else
    echo -e "${RED}Ошибка: Директория ноды не найдена!${NC}"
    exit 1
fi

CERT_DIR="$BASE_DIR/certbot"
echo -e "${GREEN}>>> Используется директория: $BASE_DIR${NC}"

# 2. ИНТЕРАКТИВНЫЙ ВВОД (Исправлено для curl | bash)
echo -e "${YELLOW}Пожалуйста, введите данные (ввод через /dev/tty):${NC}"

printf "Введите ваш домен (например, node.example.com): "
read -r DOMAIN < /dev/tty

printf "Введите ваш Email для Certbot: "
read -r EMAIL < /dev/tty

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo -e "${RED}Ошибка: Домен и Email обязательны!${NC}"
    exit 1
fi

# 3. Создание docker-compose для Certbot
mkdir -p "$CERT_DIR"
cat <<EOF > "$CERT_DIR/docker-compose.yml"
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
EOF

# 4. Освобождение порта 80
echo -e "${GREEN}>>> Подготовка порта 80...${NC}"
if command -v ufw > /dev/null; then
    sudo ufw allow 80/tcp > /dev/null
fi
# Убиваем процессы на 80 порту, если они есть
sudo fuser -k 80/tcp > /dev/null 2>&1

# 5. Получение сертификата
echo -e "${GREEN}>>> Получение сертификата...${NC}"
docker run --rm \
  -v "$CERT_DIR/certs:/etc/letsencrypt" \
  -v "$CERT_DIR/var-lib-letsencrypt:/var/lib/letsencrypt" \
  --network host \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

if [ $? -ne 0 ]; then
    echo -e "${RED}>>> Ошибка получения сертификата!${NC}"
    exit 1
fi

# 6. Автопродление (Cron)
CRON_JOB="0 0 28 * * cd $CERT_DIR && docker compose run --rm certbot renew && cd $BASE_DIR && docker compose restart"
(crontab -l 2>/dev/null | grep -v "certbot renew" ; echo "$CRON_JOB") | crontab -

# 7. Проброс в основной docker-compose.yml
MAIN_COMPOSE="$BASE_DIR/docker-compose.yml"
if [ -f "$MAIN_COMPOSE" ]; then
    if ! grep -q "etc/letsencrypt:ro" "$MAIN_COMPOSE"; then
        # Добавляем строку в секцию volumes
        sed -i "/volumes:/a \      - '$CERT_DIR/certs:/etc/letsencrypt:ro'" "$MAIN_COMPOSE"
        echo -e "${GREEN}>>> Пути добавлены в $MAIN_COMPOSE${NC}"
    fi

    # 8. Перезапуск
    echo -e "${GREEN}>>> Перезапуск ноды...${NC}"
    cd "$BASE_DIR" && docker compose down && docker compose up -d
    echo -e "${GREEN}>>> Готово! HTTPS настроен.${NC}"
else
    echo -e "${RED}Ошибка: Основной файл docker-compose не найден.${NC}"
fi
