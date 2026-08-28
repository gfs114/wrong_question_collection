#!/bin/sh
set -eu
umask 077
mkdir -p /backup
export MYSQL_PWD="$DB_PASSWORD"

while true; do
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  temporary="/backup/.daily-${timestamp}.sql.tmp"
  daily="/backup/daily-${timestamp}.sql"
  mysqldump \
    --host="$DB_HOST" \
    --user="$DB_USER" \
    --single-transaction \
    --quick \
    --no-tablespaces \
    --set-gtid-purged=OFF \
    "$DB_NAME" > "$temporary"
  mv "$temporary" "$daily"
  find /backup -type f -name 'daily-*.sql' -mtime +7 -delete
  if [ "$(date -u +%u)" = "7" ]; then
    cp "$daily" "/backup/weekly-${timestamp}.sql"
    find /backup -type f -name 'weekly-*.sql' -mtime +28 -delete
  fi
  sleep 86400
done
