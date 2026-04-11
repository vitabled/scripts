#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}>>> Запуск скрипта настройки SSL для Remnawave/Remnanode...${NC}"

# 1. Определение директории
if [ -d "/opt/remnanode" ]; then
    BASE_DIR="/opt/remnanode"
elif [ -d "/opt/remnawave" ]; then
    BASE_DIR="/opt/remnawave"
else
    echo -e "${RED}Ошибка: Директория /opt/remnanode или /opt/remnawave не найдена!${NC}"
    exit 1
fi

CERT_DIR="$BASE_DIR/certbot"
echo -e "${GREEN}>>> Используется директория: $BASE_DIR${NC}"

# 2. Запрос данных (с использованием /dev/tty для работы через curl | bash)
echo -e "${YELLOW}Пожалуйста, введите данные ниже:${NC}"
# Читаем ввод напрямую из терминала
printf "Введите ваш домен (например, node.example.com): "
read -r DOMAIN < /dev/tty
printf "Введите ваш Email для Certbot: "
read -r EMAIL < /dev/tty

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo -e "${RED}Ошибка: Домен и Email обязательны для получения сертификата!${NC}"
    exit 1
fi

# 3. Подготовка папок и docker-compose для Certbot
mkdir -p "$CERT_DIR"
cd "$CERT_DIR" || exit

cat <<EOF > docker-compose.yml
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
EOF

# 4. Работа с портом 80
echo -e "${GREEN}>>> Проверка порта 80...${NC}"
if command -v ufw > /dev/null; then
    sudo ufw allow 80/tcp > /dev/null
fi
# Принудительно освобождаем порт, если он занят (опционально)
if command -v fuser > /dev/null; then
    sudo fuser -k 80/tcp > /dev/null 2>&1
fi

# 5. Получение сертификата
echo -e "${GREEN}>>> Получение сертификата для $DOMAIN...${NC}"
docker run --rm \
  -v "$CERT_DIR/certs:/etc/letsencrypt" \
  -v "$CERT_DIR/var-lib-letsencrypt:/var/lib/letsencrypt" \
  --network host \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}>>> Сертификат успешно получен!${NC}"
else
    echo -e "${RED}>>> Ошибка при получении сертификата.${NC}"
    exit 1
fi

# 6. Настройка автопродления (Cron)
# Удаляем старые задачи с renew, если они были, и добавляем новую
CRON_JOB="0 0 28 * * cd $CERT_DIR && docker compose run --rm certbot renew && docker compose -f $BASE_DIR/docker-compose.yml restart"
(crontab -l 2>/dev/null | grep -v "certbot renew" ; echo "$CRON_JOB") | crontab -

# 7. Обновление основного docker-compose.yml ноды
MAIN_COMPOSE="$BASE_DIR/docker-compose.yml"

if [ -f "$MAIN_COMPOSE" ]; then
    echo -e "${GREEN}>>> Обновление конфигурации ноды...${NC}"
    
    if ! grep -q "/etc/letsencrypt:ro" "$MAIN_COMPOSE"; then
        # Ищем строку volumes: и вставляем путь к сертификатам под ней
        sed -i "/volumes:/a \      - '$CERT_DIR/certs:/etc/letsencrypt:ro'" "$MAIN_COMPOSE"
        echo -e "${GREEN}>>> Путь к сертификатам добавлен в volumes.${NC}"
    else
        echo -e "${YELLOW}>>> Запись о сертификатах уже существует в docker-compose.yml.${NC}"
    fi
    
    # 8. Перезапуск ноды
    echo -e "${GREEN}>>> Перезапуск ноды...${NC}"
    cd "$BASE_DIR" || exit
    docker compose down && docker compose up -d
    echo -e "${GREEN}>>> Все операции завершены успешно!${NC}"
else
    echo -e "${RED}Ошибка: Файл $MAIN_COMPOSE не найден.${NC}"
fi
