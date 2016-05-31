FROM wordpress:4.4-apache

# add GIT
RUN apt-get update \
	&& apt-get install -y git \
	&& apt-get install -y vim \
	&& rm -rf /var/lib/apt/lists/*

# add WP-CLI
RUN { \
	echo '#!/bin/bash'; \
	echo 'exec php /usr/local/bin/wp-cli.phar --allow-root "$@"'; \
} > /usr/local/bin/wp

RUN curl -SL -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
		&& mv wp-cli.phar /usr/local/bin \
		&& chmod +x /usr/local/bin/wp /usr/local/bin/wp-cli.phar

# set UID of www-data to 1000 as that's the default ID of files from host shared volumes
RUN usermod -u 1000 www-data

COPY docker-entrypoint.sh /entrypoint.sh
