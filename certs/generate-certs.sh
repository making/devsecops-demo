#!/bin/bash
set -ex

ROOT_DOMAIN=$1
SSL_FILE=sslconf-${ROOT_DOMAIN}.conf

cd /certs
rm -f *.crt *.csr *.key *.srl ${SSL_FILE}

# Generate SSL Config with SANs
cat > ${SSL_FILE} <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[req_distinguished_name]
countryName_default = JP
stateOrProvinceName_default = Tokyo
localityName_default = Minato-ku
organizationalUnitName_default = IK.AM
[ v3_req ]
# Extensions to add to a certificate request
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.${ROOT_DOMAIN}
EOF

# Create CA certificate
openssl req -new -nodes -out ca.csr \
 -keyout ca.key -subj "/CN=@making/O=IK.AM/C=JP"
chmod og-rwx ca.key

openssl x509 -req -in ca.csr -days 3650 \
 -extfile /etc/ssl/openssl.cnf -extensions v3_ca \
 -signkey ca.key -out ca.crt

# Create Server certificate signed by CA
openssl req -new -nodes -out server.csr \
 -keyout server.key -subj "/CN=${ROOT_DOMAIN}" -extensions v3_req
chmod og-rwx server.key

openssl x509 -req -in server.csr -days 3650 \
 -CA ca.crt -CAkey ca.key -CAcreateserial \
 -out server.crt -extensions v3_req -extfile ${SSL_FILE}

rm -f *.csr *.srl ${SSL_FILE}