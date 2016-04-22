FROM wordpress:4.4-apache

# add WP-CLI
RUN { \
	echo '#!/bin/bash'; \
	echo 'exec php /usr/local/bin/wp-cli.phar --allow-root "$@"'; \
} > /usr/local/bin/wp

RUN curl -SL -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
		&& mv wp-cli.phar /usr/local/bin \
		&& chmod +x /usr/local/bin/wp /usr/local/bin/wp-cli.phar

# add GIT
RUN apt-get update && apt-get install -y git-all && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /entrypoint.sh
