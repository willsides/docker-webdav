FROM httpd:2.4.43-alpine

# These variables are inherited from the httpd:alpine image:
# ENV HTTPD_PREFIX /usr/local/apache2
# WORKDIR "$HTTPD_PREFIX"

# Copy in our configuration files.
COPY conf/ conf/

RUN set -ex; \
    # Create empty default DocumentRoot.
    mkdir -p "/var/www/html"; \
    # Create directories for Dav data and lock database.
    mkdir -p "/var/lib/dav/data"; \
    touch "/var/lib/dav/DavLock"; \
    \
    # Enable DAV modules.
    for i in dav dav_fs; do \
        sed -i -e "/^#LoadModule ${i}_module.*/s/^#//" "conf/httpd.conf"; \
    done; \
    \
    # Make sure authentication modules are enabled.
    for i in authn_core authn_file authz_core authz_user auth_basic auth_digest; do \
        sed -i -e "/^#LoadModule ${i}_module.*/s/^#//" "conf/httpd.conf"; \
    done; \
    \
    # Make sure other modules are enabled.
    for i in alias headers mime setenvif; do \
        sed -i -e "/^#LoadModule ${i}_module.*/s/^#//" "conf/httpd.conf"; \
    done; \
    \
    # Include enabled configs and sites.
    printf '%s\n' "Include conf/conf-enabled/*.conf" \
        >> "conf/httpd.conf"; \
    printf '%s\n' "Include conf/sites-enabled/*.conf" \
        >> "conf/httpd.conf"; \
    \
    # Enable dav and default site.
    mkdir -p "conf/conf-enabled"; \
    mkdir -p "conf/sites-enabled"; \
    ln -s ../conf-available/dav.conf "conf/conf-enabled"; \
    ln -s ../sites-available/default.conf "conf/sites-enabled"; \
    # Install openssl if we need to generate a self-signed certificate.
    apt-get update; \
    apt-get upgrade; \
    apt-get install -y \
    openssl \
    libapr1 \
    libapr1-dev \
    && rm -rf /var/lib/apt/lists/*;

# Adding entrypoint and updating permissions.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT [ "/usr/local/bin/docker-entrypoint.sh" ]

EXPOSE 80/tcp 443/tcp
CMD [ "httpd-foreground" ]
