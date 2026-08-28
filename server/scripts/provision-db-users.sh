#!/bin/sh
set -eu

for value in "$DB_NAME" "$DB_RUNTIME_USER" "$DB_BACKUP_USER"; do
  case "$value" in
    ''|*[!A-Za-z0-9_]*)
      echo "Database names and users must contain only letters, digits, and underscores" >&2
      exit 1
      ;;
  esac
done

for value in "$DB_RUNTIME_PASSWORD" "$DB_BACKUP_PASSWORD"; do
  case "$value" in
    *[!A-Za-z0-9_-]*|'')
      echo "Runtime and backup passwords must be alphanumeric with optional _ or -" >&2
      exit 1
      ;;
  esac
  if [ "${#value}" -lt 32 ]; then
    echo "Runtime and backup passwords must contain at least 32 characters" >&2
    exit 1
  fi
done

export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
mysql --protocol=socket --user=root <<SQL
CREATE USER IF NOT EXISTS '${DB_RUNTIME_USER}'@'%' IDENTIFIED BY '${DB_RUNTIME_PASSWORD}';
ALTER USER '${DB_RUNTIME_USER}'@'%' IDENTIFIED BY '${DB_RUNTIME_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DB_NAME}\`.* TO '${DB_RUNTIME_USER}'@'%';

CREATE USER IF NOT EXISTS '${DB_BACKUP_USER}'@'%' IDENTIFIED BY '${DB_BACKUP_PASSWORD}';
ALTER USER '${DB_BACKUP_USER}'@'%' IDENTIFIED BY '${DB_BACKUP_PASSWORD}';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON \`${DB_NAME}\`.* TO '${DB_BACKUP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
