#!/bin/sh
set -e

# Environment variables that are used if not empty:
#   SERVER_NAMES
#   LOCATION
#   AUTH_TYPE
#   REALM
#   USERNAME
#   PASSWORD
#   ANONYMOUS_METHODS
#   SSL_CERT
#   PUID
#   PGID
#   PUMASK
#   REQUEST_BODY_LIMIT

# Just in case this environment variable has gone missing.
HTTPD_PREFIX="${HTTPD_PREFIX:-/usr/local/apache2}"
PUID=${PUID:-1000}
PGID=${PGID:-1000}

# Configure vhosts.
if [ -n "$SERVER_NAMES" ]; then
    # Use first domain as Apache ServerName.
    SERVER_NAME="${SERVER_NAMES%%,*}"
    sed -i "s|ServerName .*|ServerName $SERVER_NAME|" "$HTTPD_PREFIX"/conf/sites-available/default*.conf

    # Replace commas with spaces and set as Apache ServerAlias.
    SERVER_ALIAS="$(printf '%s\n' "$SERVER_NAMES" | tr ',' ' ')"
    sed -i "/ServerName/a\ \ ServerAlias $SERVER_ALIAS" "$HTTPD_PREFIX"/conf/sites-available/default*.conf
else
    echo "ServerName localhost" >> "$HTTPD_PREFIX/conf/httpd.conf"
fi

# Configure dav.conf
if [ -n "$LOCATION" ]; then
    sed -i "s|Alias .*|Alias ${LOCATION//\//\\/} /var/lib/dav/data/|" "$HTTPD_PREFIX/conf/conf-available/dav.conf"
fi
if [ -n "$REALM" ]; then
    sed -i "s|AuthName .*|AuthName \"$REALM\"|" "$HTTPD_PREFIX/conf/conf-available/dav.conf"
else
    REALM="WebDAV"
fi
if [ -n "$AUTH_TYPE" ]; then
    # Only support "Basic" and "Digest".
    if [ "$AUTH_TYPE" != "Basic" ] && [ "$AUTH_TYPE" != "Digest" ]; then
        printf '%s\n' "$AUTH_TYPE: Unknown AuthType" 1>&2
        exit 1
    fi
    sed -i "s|AuthType .*|AuthType $AUTH_TYPE|" "$HTTPD_PREFIX/conf/conf-available/dav.conf"
fi

if [ -n "$REQUEST_BODY_LIMIT" ]; then
    if ! echo "$REQUEST_BODY_LIMIT" | grep -Eq '^[0-9]+$'; then
        echo "Error: REQUEST_BODY_LIMIT must be a positive integer." >&2
        exit 1
    fi

    echo "Setting LimitRequestBody to $REQUEST_BODY_LIMIT in dav.conf"

    if grep -q '^LimitRequestBody' "$HTTPD_PREFIX/conf/conf-available/dav.conf"; then
        echo "Existing LimitRequestBody found, updating..."
        sed -i "s/^LimitRequestBody .*/LimitRequestBody $REQUEST_BODY_LIMIT/" "$HTTPD_PREFIX/conf/conf-available/dav.conf"
    else
        echo "No existing LimitRequestBody, appending..."
        echo "LimitRequestBody $REQUEST_BODY_LIMIT" >> "$HTTPD_PREFIX/conf/conf-available/dav.conf"
    fi
fi

# Add password hash, unless "user.passwd" already exists (i.e., bind mounted).
if [ ! -e "/user.passwd" ]; then
    touch "/user.passwd"
    # Only generate a password hash if both username and password are given.
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        if [ "$AUTH_TYPE" = "Digest" ]; then
            HASH="$(printf '%s' "$USERNAME:$REALM:$PASSWORD" | md5sum | awk '{print $1}')"
            printf '%s\n' "$USERNAME:$REALM:$HASH" > /user.passwd
        else
            htpasswd -B -b -c "/user.passwd" "$USERNAME" "$PASSWORD"
        fi
    fi
fi

# If specified, allow anonymous access to specified methods.
if [ -n "$ANONYMOUS_METHODS" ]; then
    if [ "$ANONYMOUS_METHODS" = "ALL" ]; then
        sed -i "s/Require valid-user/Require all granted/" "$HTTPD_PREFIX/conf/conf-available/dav.conf"
    else
        ANONYMOUS_METHODS="$(printf '%s\n' "$ANONYMOUS_METHODS" | tr ',' ' ')"
        sed -i "/Require valid-user/a\ \ \ \ Require method $ANONYMOUS_METHODS" "$HTTPD_PREFIX/conf/conf-available/dav.conf"
    fi
fi

# If specified, generate a self-signed certificate.
if [ "${SSL_CERT:-none}" = "selfsigned" ]; then
    # Generate self-signed SSL certificate.
    if [ ! -e /privkey.pem ] || [ ! -e /cert.pem ]; then
        openssl req -x509 -newkey rsa:2048 -days 1000 -nodes \
            -keyout /privkey.pem -out /cert.pem -subj "/CN=${SERVER_NAME:-selfsigned}"
    fi
fi

# Enable SSL modules if a certificate is available.
if [ -e /privkey.pem ] && [ -e /cert.pem ]; then
    for i in http2 ssl socache_shmcb; do
        sed -i "/^#LoadModule ${i}_module.*/s/^#//" "$HTTPD_PREFIX/conf/httpd.conf"
    done
    ln -sf ../sites-available/default-ssl.conf "$HTTPD_PREFIX/conf/sites-enabled"
fi

# Create directory for Dav data and Dav lock database.
mkdir -p "/var/lib/dav/data"
touch "/var/lib/dav/DavLock"

# Run httpd as PUID:PGID
sed -i "s|^User .*|User #$PUID|" "$HTTPD_PREFIX/conf/httpd.conf"
sed -i "s|^Group .*|Group #$PGID|" "$HTTPD_PREFIX/conf/httpd.conf"

# Set correct ownership and permissions
chown "$PUID:$PGID" "/var/lib/dav/DavLock"
chmod 700 /var/lib/dav/data
chmod 600 /var/lib/dav/DavLock
chmod 600 /user.passwd

# Set umask if specified
if [ -n "$PUMASK" ]; then
    umask "$PUMASK"
fi

if ! apachectl configtest; then
    echo "[ERROR] Apache configuration test failed. Exiting." >&2
    exit 1
fi

exec "$@"