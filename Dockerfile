FROM wordpress:4.4-apache

RUN { \
	echo '#!/bin/bash'; \
	echo 'exec php /usr/local/bin/wp-cli.phar --allow-root "$@"'; \
} > /usr/local/bin/wp

# add WP-CLI
RUN curl -SL -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
		&& chmod +x wp-cli.phar \
		&& mv wp-cli.phar /usr/local/bin \
		&& chmod +x /usr/local/bin/wp

# add GIT
RUN apt-get update && apt-get install -y git-all && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /entrypoint.sh
