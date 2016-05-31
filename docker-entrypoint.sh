#!/bin/bash
set -e

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ -n "$MYSQL_PORT_3306_TCP" ]; then
		if [ -z "$WORDPRESS_DB_HOST" ]; then
			WORDPRESS_DB_HOST='mysql'
		else
			echo >&2 'warning: both WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP found'
			echo >&2 "  Connecting to WORDPRESS_DB_HOST ($WORDPRESS_DB_HOST)"
			echo >&2 '  instead of the linked mysql container'
		fi
	fi

	if [ -z "$WORDPRESS_DB_HOST" ]; then
		echo >&2 'error: missing WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP environment variables'
		echo >&2 '  Did you forget to --link some_mysql_container:mysql or set an external db'
		echo >&2 '  with -e WORDPRESS_DB_HOST=hostname:port?'
		exit 1
	fi

	# if we're linked to MySQL and thus have credentials already, let's use them
	: ${WORDPRESS_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}
	if [ "$WORDPRESS_DB_USER" = 'root' ]; then
		: ${WORDPRESS_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
	fi
	: ${WORDPRESS_DB_PASSWORD:=$MYSQL_ENV_MYSQL_PASSWORD}
	: ${WORDPRESS_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-wordpress}}

	if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
		echo >&2 'error: missing required WORDPRESS_DB_PASSWORD environment variable'
		echo >&2 '  Did you forget to -e WORDPRESS_DB_PASSWORD=... ?'
		echo >&2
		echo >&2 '  (Also of interest might be WORDPRESS_DB_USER and WORDPRESS_DB_NAME.)'
		exit 1
	fi

	WEBSERVER_ROOT="$PWD"

	# default WORDPRESS_PATH to the WEBSERVER_ROOT if it is not set
	: ${WORDPRESS_PATH:=${WORDPRESS_PATH:-$WEBSERVER_ROOT}}

	if [ ! -e "${WEBSERVER_ROOT}/.htaccess" ]; then
		# NOTE: The "Indexes" option is disabled in the php:apache base image
		cat > "${WEBSERVER_ROOT}/.htaccess" <<-'EOF'
			# BEGIN WordPress
			<IfModule mod_rewrite.c>
			RewriteEngine On
			RewriteBase /
			RewriteRule ^index\.php$ - [L]
			RewriteCond %{REQUEST_FILENAME} !-f
			RewriteCond %{REQUEST_FILENAME} !-d
			RewriteRule . /index.php [L]
			</IfModule>
			# END WordPress
		EOF
		chown www-data:www-data "${WEBSERVER_ROOT}/.htaccess"
	fi

#	WORDPRESS_DEFAULT_PATH=$WORDPRESS_PATH
#	WORDPRESS_DEFAULT_DB_NAME=$WORDPRESS_DB_NAME
#	WORDPRESS_DEFAULT_DB_USER=$WORDPRESS_DB_USER
#	WORDPRESS_DEFAULT_DB_PASSWORD=$WORDPRESS_DB_PASSWORD
#	WORDPRESS_DEFAULT_DB_HOST=$WORDPRESS_DB_HOST
#	WORDPRESS_DEFAULT_TABLE_PREFIX=$WORDPRESS_TABLE_PREFIX

	WP_OPTIONS=(
		DB_NAME
		DB_USER
		DB_PASSWORD
		DB_HOST
		PATH
		TABLE_PREFIX
		DEBUG
	)

	# set defaults to be recalled later if necessary
	for option in "${WP_OPTIONS[@]}"; do
		eval WORDPRESS_DEFAULT_${option}=\$WORDPRESS_${option}

		eval echo "WORDPRESS_DEFAULT_${option}: \${WORDPRESS_DEFAULT_${option}}"
	done

	site_regex='^(WORDPRESS_SITE[0-9]*)'

	# get a unique list of sites from environment variables
	sites=$(echo "$(printenv)" | grep -Eio $site_regex | sort | uniq)

	# make sure we create at least the default site if none are explicitly specified
	if [ -z "$sites" ]; then
		sites=WORDPRESS_SITE
	fi

	while read -r line; do

		for option in "${WP_OPTIONS[@]}"; do
			# WORDPRESS_SITE_DB_NAME
			if [ ! -z $(eval echo \$${line}_${option}) ]; then
				eval WORDPRESS_${option}=\$${line}_${option}
			else
				# if not explicitly set, set it to the default
				eval WORDPRESS_${option}=\$WORDPRESS_DEFAULT_${option}
			fi
		done

		# WORDPRESS_SITE_PATH
		if [ ! -z $(eval echo \$${line}_PATH) ] && [ $(eval echo \$${line}_PATH) != '.' ]; then
			WORDPRESS_PATH=$(eval echo \$${line}_PATH)

			# Remove beginning slash if it exists
			if [ "${WORDPRESS_PATH:0:1}" == "/" ]; then
				WORDPRESS_PATH="${WORDPRESS_PATH:1}"
			fi

			# Remove ending slash if it exists
			if [ "${WORDPRESS_PATH:(-1)}" == "/" ]; then
				WORDPRESS_PATH="${WORDPRESS_PATH%?}"
			fi

			WORDPRESS_PATH="${WEBSERVER_ROOT}/${WORDPRESS_PATH}"
		else
			WORDPRESS_PATH=$WORDPRESS_DEFAULT_PATH
		fi

		echo ""
		echo "Settings for ${line}"
		echo "--------------------"
		echo "WORDPRESS_PATH: ${WORDPRESS_PATH}"
		echo "WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}"
		echo "WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}"
		echo "WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}"
		echo "WORDPRESS_DB_HOST: ${WORDPRESS_DB_HOST}"
		echo "WORDPRESS_TABLE_PREFIX: ${WORDPRESS_TABLE_PREFIX}"
		echo "WORDPRESS_DEBUG: ${WORDPRESS_DEBUG}"
		echo ""

		if [ ! -e "$WORDPRESS_PATH" ]; then
			mkdir -p "$WORDPRESS_PATH"
		fi

		cd "$WORDPRESS_PATH"

		if ! [ -e index.php -a -e wp-includes/version.php ]; then
			echo >&2 "WordPress not found in $(pwd) - copying now..."
			if [ "$(ls -A)" ]; then
				echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
				( set -x; ls -A; sleep 10 )
			fi
			tar cf - --one-file-system -C /usr/src/wordpress . | tar xf -
			echo >&2 "Complete! WordPress has been successfully copied to $(pwd)"
		fi

		# TODO handle WordPress upgrades magically in the same way, but only if wp-includes/version.php's $wp_version is less than /usr/src/wordpress/wp-includes/version.php's $wp_version

		# version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
		# https://github.com/docker-library/wordpress/issues/116
		# https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4
		sed -ri 's/\r\n|\r/\n/g' wp-config*

		if [ ! -e wp-config.php ]; then
			awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wp-config-sample.php > wp-config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}

EOPHP
			chown www-data:www-data wp-config.php
		fi

		# see http://stackoverflow.com/a/2705678/433558
		sed_escape_lhs() {
			echo "$@" | sed 's/[]\/$*.^|[]/\\&/g'
		}
		sed_escape_rhs() {
			echo "$@" | sed 's/[\/&]/\\&/g'
		}
		php_escape() {
			php -r 'var_export(('$2') $argv[1]);' "$1"
		}
		set_config() {
			key="$1"
			value="$2"
			var_type="${3:-string}"
			start="(['\"])$(sed_escape_lhs "$key")\2\s*,"
			end="\);"
			if [ "${key:0:1}" = '$' ]; then
				start="^(\s*)$(sed_escape_lhs "$key")\s*="
				end=";"
			fi
			sed -ri "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" wp-config.php
		}

		set_config 'DB_HOST' "$WORDPRESS_DB_HOST"
		set_config 'DB_USER' "$WORDPRESS_DB_USER"
		set_config 'DB_PASSWORD' "$WORDPRESS_DB_PASSWORD"
		set_config 'DB_NAME' "$WORDPRESS_DB_NAME"

		# allow any of these "Authentication Unique Keys and Salts." to be specified via
		# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
		UNIQUES=(
			AUTH_KEY
			SECURE_AUTH_KEY
			LOGGED_IN_KEY
			NONCE_KEY
			AUTH_SALT
			SECURE_AUTH_SALT
			LOGGED_IN_SALT
			NONCE_SALT
		)
		for unique in "${UNIQUES[@]}"; do
			eval unique_value=\$WORDPRESS_$unique
			if [ "$unique_value" ]; then
				set_config "$unique" "$unique_value"
			else
				# if not specified, let's generate a random value
				current_set="$(sed -rn "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" wp-config.php)"
				if [ "$current_set" = 'put your unique phrase here' ]; then
					set_config "$unique" "$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
				fi
			fi
		done

		if [ "$WORDPRESS_TABLE_PREFIX" ]; then
			set_config '$table_prefix' "$WORDPRESS_TABLE_PREFIX"
		fi

		if [ "$WORDPRESS_DEBUG" ]; then
			set_config 'WP_DEBUG' 1 boolean
		fi

		TERM=dumb php -- "$WORDPRESS_DB_HOST" "$WORDPRESS_DB_USER" "$WORDPRESS_DB_PASSWORD" "$WORDPRESS_DB_NAME" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

list($host, $port) = explode(':', $argv[1], 2);

$maxTries = 10;
do {
	$mysql = new mysqli($host, $argv[2], $argv[3], '', (int)$port);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);

if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($argv[4]) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

$mysql->close();
EOPHP

	done < <(echo "$sites")

	cd "$WEBSERVER_ROOT"

fi

exec "$@"
