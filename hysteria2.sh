#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

# 2. Запрос данных у пользователя
read -p "Введите ваш домен (например, node.example.com): " DOMAIN
read -p "Введите ваш Email для Certbot: " EMAIL

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo -e "${RED}Ошибка: Домен и Email обязательны.${NC}"
    exit 1
fi

# 3. Подготовка папок и docker-compose для Certbot
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

cat <<EOF > docker-compose.yml
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
EOF

# 4. Работа с портом 80 (Открытие в UFW если есть)
echo -e "${GREEN}>>> Проверка порта 80...${NC}"
if command -v ufw > /dev/null; then
    sudo ufw allow 80/tcp > /dev/null
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
    echo -e "${RED}>>> Ошибка при получении сертификата. Проверьте, что порт 80 свободен и домен направлен на IP сервера.${NC}"
    exit 1
fi

# 6. Настройка автопродления (Cron)
CRON_JOB="0 0 28 * * cd $CERT_DIR && docker compose run --rm certbot renew && docker compose -f $BASE_DIR/docker-compose.yml restart"
(crontab -l 2>/dev/null | grep -v "certbot renew" ; echo "$CRON_JOB") | crontab -

echo -e "${GREEN}>>> Задача на продление добавлена в crontab.${NC}"

# 7. Обновление основного docker-compose.yml ноды
MAIN_COMPOSE="$BASE_DIR/docker-compose.yml"

if [ -f "$MAIN_COMPOSE" ]; then
    echo -e "${GREEN}>>> Обновление конфигурации ноды...${NC}"
    
    # Проверяем, нет ли уже этой строки, чтобы не дублировать
    if ! grep -q "/etc/letsencrypt:ro" "$MAIN_COMPOSE"; then
        # Используем sed для вставки тома в секцию volumes
        # Этот скрипт ищет строку 'volumes:' и добавляет после неё путь к сертификатам
        sed -i "/volumes:/a \      - '$CERT_DIR/certs:/etc/letsencrypt:ro'" "$MAIN_COMPOSE"
        echo -e "${GREEN}>>> Путь к сертификатам добавлен в volumes.${NC}"
    else
        echo -e "${GREEN}>>> Запись о сертификатах уже существует в docker-compose.yml.${NC}"
    fi
    
    # 8. Перезапуск ноды
    echo -e "${GREEN}>>> Перезапуск ноды...${NC}"
    cd "$BASE_DIR"
    docker compose down && docker compose up -d
    echo -e "${GREEN}>>> Готово! Нода перезапущена с SSL.${NC}"
else
    echo -e "${RED}Ошибка: Основной файл $MAIN_COMPOSE не найден для редактирования.${NC}"
fi
