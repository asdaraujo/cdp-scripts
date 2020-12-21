#!/bin/bash
set -u
set -e

read -p "Username: " username
read -p "Keystore password: " -s key_pwd
read -p "Confirm keystore password: " -s key_pwd_confirm
echo ""

if [[ $key_pwd != $key_pwd_confirm ]]; then
  echo "ERROR: Passwords do not match!"
  exit 1
fi

dn="/C=US/ST=CA/CN=${username}"
key_pem="./${username}-key.pem"
csr_pem="./${username}.csr"
cert_pem="./${username}-cert.pem"
cert_key_p12="./${username}.p12"
cert_key_p12_pem="./${username}.p12.pem"
keystore_jks="./${username}-keystore.jks"
keystore_pwd="$key_pwd"

if [[ -f $key_pem || -f $csr_pem || -f $cert_pem || -f $cert_key_p12 || -f $cert_key_p12_pem || -f $keystore_jks || -f $keystore_pwd ]]; then
  echo ""
  echo "WARNING: The files below will be overwritten:"
  ls -l "$key_pem" "$csr_pem" "$cert_pem" "$cert_key_p12" "$cert_key_p12_pem" "$keystore_jks" "$keystore_pwd" 2>/dev/null || true
  echo ""
  echo -n "Do you want to continue? (y/N) "
  read confirm
  if [[ $confirm != "y" && $confirm != "Y" ]]; then
    echo "Bye."
    exit 1
  fi
fi
rm -f "$key_pem" "$csr_pem" "$cert_pem" "$cert_key_p12" "$cert_key_p12_pem" "$keystore_jks" "$keystore_pwd" || true

# Create private key
openssl genrsa -des3 -out "${key_pem}" -passout pass:"${key_pwd}" 2048

# Generate CSR
openssl req\
  -new\
  -key "${key_pem}" \
  -subj "${dn}" \
  -out "${csr_pem}" \
  -passin pass:"${key_pwd}" \
  -config <( cat <<EOF
[ req ]
default_bits = 2048
default_md = sha256
distinguished_name = req_distinguished_name
req_extensions = v3_user_req
string_mask = utf8only

[ req_distinguished_name ]
countryName_default = XX
countryName_min = 2
countryName_max = 2
localityName_default = Default City
0.organizationName_default = Default Company Ltd
commonName_max = 64
emailAddress_max = 64

[ v3_user_req ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF
)

# Generate certificate
echo -n "Admin user: "
read admin_user
kinit "$admin_user"
ipa cert-request "${csr_pem}" --principal="${username}"

# Retrieve the certificate contents
echo -e "-----BEGIN CERTIFICATE-----\n$(ipa user-find "${username}" --all | grep Certificate: | tail -1 | awk '{print $NF}')\n-----END CERTIFICATE-----" | openssl x509 > "${cert_pem}"
kdestroy

# Generate PKCS12 store
openssl pkcs12 -export \
 -in "${cert_pem}" \
 -inkey <(openssl rsa -in "$key_pem" -passin pass:"$key_pwd") \
 -out "${cert_key_p12}" \
 -passout pass:"${keystore_pwd}" \
 -name "${username}"

# Generate PKCS12 store (PEM format)
openssl pkcs12 \
 -in ${cert_key_p12} \
 -out ${cert_key_p12_pem} \
 -passin pass:${keystore_pwd} \
 -passout pass:${keystore_pwd}

# Generate JKS store
keytool\
 -importkeystore\
 -alias ${username} \
 -srcstoretype PKCS12\
 -srckeystore ${cert_key_p12}\
 -destkeystore $keystore_jks\
 -srcstorepass $keystore_pwd\
 -deststorepass $keystore_pwd\
 -destkeypass $keystore_pwd

echo "File                 Format  Path"
echo "-------------------- ------- ------------------------------------"
echo "Key                  PEM     $key_pem"
echo "Certificate          PEM     $cert_pem"
echo "PKCS12 Key+Cert      DER     $cert_key_p12"
echo "PKCS12 Key+Cert      PEM     $cert_key_p12_pem"
echo "Keystore             JKS     $keystore_jks"
