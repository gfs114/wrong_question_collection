#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <public-ip>" >&2
  exit 1
fi

server_ip="$1"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cert_dir="$(dirname "$script_dir")/certs"
mkdir -p "$cert_dir"

if [ ! -f "$cert_dir/ca.key" ] || [ ! -f "$cert_dir/ca.crt" ]; then
  openssl genrsa -out "$cert_dir/ca.key" 4096
  openssl req -x509 -new -sha256 -days 3650 \
    -key "$cert_dir/ca.key" \
    -out "$cert_dir/ca.crt" \
    -subj "/CN=Wrong Question Private CA"
fi

openssl genrsa -out "$cert_dir/server.key" 3072
openssl req -new \
  -key "$cert_dir/server.key" \
  -out "$cert_dir/server.csr" \
  -subj "/CN=$server_ip"

printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' \
  "$server_ip" > "$cert_dir/server.ext"

openssl x509 -req -sha256 -days 825 \
  -in "$cert_dir/server.csr" \
  -CA "$cert_dir/ca.crt" \
  -CAkey "$cert_dir/ca.key" \
  -CAcreateserial \
  -out "$cert_dir/server.crt" \
  -extfile "$cert_dir/server.ext"

rm -f "$cert_dir/server.csr" "$cert_dir/server.ext"
chmod 600 "$cert_dir/ca.key" "$cert_dir/server.key"
chmod 644 "$cert_dir/ca.crt" "$cert_dir/server.crt"
