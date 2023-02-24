#!/bin/bash

echo "This script installs a new BookStack instance on a fresh Ubuntu 22.04 server."
echo "This script does not ensure system security."
echo ""

# Generate a path for a log file to output into for debugging
LOGPATH=$(realpath "bookstack_install_$(date +%s).log")

# Get the current user running the script
SCRIPT_USER="${SUDO_USER:-$USER}"

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A4 | grep 'inet ' | awk '{print $2}' | cut -f1  -d'/')

# Generate a password for the database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"

# The directory to install BookStack into
BOOKSTACK_DIR="/var/www/bookstack"

# Get the domain from the arguments (Requested later if not set)
DOMAIN=$1

# Prevent interactive prompts in applications
export DEBIAN_FRONTEND=noninteractive

# Echo out an error message to the command line and exit the program
# Also logs the message to the log file
function error_out() {
  echo "ERROR: $1" | tee -a "$LOGPATH" 1>&2
  exit 1
}

# Echo out an information message to both the command line and log file
function info_msg() {
  echo "$1" | tee -a "$LOGPATH"
}

# Run some checks before installation to help prevent messing up an existing
# web-server setup.
function run_pre_install_checks() {
  # Check we're running as root and exit if not
  if [[ $EUID -gt 0 ]]
  then
    error_out "This script must be ran with root/sudo privileges"
  fi

  # Check if nginx appears to be installed and exit if so
  #if [ -d "/etc/nginx/sites-enabled" ]
  #then
  #  error_out "This script is intended for a fresh server install, existing nginx config found, aborting install"
  #fi
}

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
function run_prompt_for_domain_if_required() {
  if [ -z "$DOMAIN" ]
  then
    info_msg ""
    info_msg "Enter the domain (or IP if not using a domain) you want to host BookStack on and press [ENTER]."
    info_msg "Examples: my-site.com or docs.my-site.com or ${CURRENT_IP}"
    read -r DOMAIN
  fi

  # Error out if no domain was provided
  if [ -z "$DOMAIN" ]
  then
    error_out "A domain must be provided to run this script"
  fi
}

# Install core system packages
function run_package_installs() {
  apt-get update
  apt-get install --no-install-recommends -y git unzip nginx php8.1 curl php8.1-curl php8.1-mbstring php8.1-ldap \
  php8.1-xml php8.1-zip php8.1-gd php8.1-mysql mysql-server-8.0
}

# Set up database
function run_database_setup() {
  # Set up RDS
  RDS_HOST="assignment2-rds.ceyucdq8yxkk.us-west-2.rds.amazonaws.com"
  RDS_PORT='3306'
  RDS_USERNAME='root'
  RDS_PASSWORD='password'
  mysql -h $RDS_HOST -P $RDS_PORT -u $RDS_USERNAME -p$RDS_PASSWORD -e "CREATE DATABASE bookstack;"
  echo 'Creating RDS Database'
}

# Download BookStack
function run_bookstack_download() {
  cd /var
  mkdir www
  cd /var/www || exit
  git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
}

# Install composer
function run_install_composer() {
  EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

  if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
  then
      >&2 echo 'ERROR: Invalid composer installer checksum'
      rm composer-setup.php
      exit 1
  fi

  php composer-setup.php --quiet
  rm composer-setup.php

  # Move composer to global installation
  mv composer.phar /usr/local/bin/composer
}

# Install BookStack composer dependencies
function run_install_bookstack_composer_deps() {
  cd "$BOOKSTACK_DIR" || exit
  export COMPOSER_ALLOW_SUPERUSER=1
  php /usr/local/bin/composer install --no-dev --no-plugins
}

# Copy and update BookStack environment variables
function run_update_bookstack_env() {
  cd "$BOOKSTACK_DIR" || exit
  cp .env.example .env
  sed -i.bak "s@APP_URL=.*\$@APP_URL=http://$DOMAIN@" .env
  sed -i.bak "s/DB_HOST=.*$/DB_HOST=assignment2-rds.ceyucdq8yxkk.us-west-2.rds.amazonaws.com/" .env
  sed -i.bak 's/DB_PORT=.*$/DB_PORT=3306/' .env
  sed -i.bak 's/DB_DATABASE=.*$/DB_DATABASE=bookstack/' .env
  sed -i.bak "s/DB_USERNAME=.*$/DB_USERNAME=root/" .env
  sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=password/" .env
  # Generate the application key
  php artisan key:generate --no-interaction --force
}

# Run the BookStack database migrations for the first time
function run_bookstack_database_migrations() {
  cd "$BOOKSTACK_DIR" || exit
  php artisan migrate --no-interaction --force
}

# Set file and folder permissions
# Sets current user as owner user and www-data as owner group then
# provides group write access only to required directories.
# Hides the `.env` file so it's not visible to other users on the system.
function run_set_application_file_permissions() {
  cd "$BOOKSTACK_DIR" || exit
  chown -R "$SCRIPT_USER":www-data ./
  chmod -R 755 ./
  chmod -R 775 bootstrap/cache public/uploads storage
  chmod 740 .env

  # Tell git to ignore permission changes
  git config core.fileMode false
}

# Setup nginx with the needed modules and config
function run_configure_nginx() {
  # Set-up the required BookStack nginx config
  cat > /etc/nginx/sites-available/bookstack << EOL
server {
  listen 8080;
  listen [::]:8080;

  server_name localhost;

  root /var/www/bookstack/public;
  index index.php index.html;

  location / {
    try_files $uri $uri/ /index.php?$query_string;
  }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php8.1-fpm.sock;
  }
}


server {
  listen 80;
  listen [::]:80;

  server_name 34.211.43.116;

  root /var/www/html;
  index index.html;

  location /bookstack/ {
    proxy_pass http://localhost:8080/;
    proxy_redirect off;
  }

}
EOL
  # Create a symbolic link to the sites-enabled directory
  ln -s /etc/nginx/sites-available/bookstack /etc/nginx/sites-enabled/bookstack

  # Remove the default Nginx configuration file
  rm /etc/nginx/sites-available/default

  # Restart the Nginx service
  nginx -t
  service nginx restart

}

info_msg "This script logs full output to $LOGPATH which may help upon issues."
sleep 1

run_pre_install_checks
run_prompt_for_domain_if_required
info_msg ""
info_msg "Installing using the domain or IP \"$DOMAIN\""
info_msg ""
sleep 1

info_msg "[1/9] Installing required system packages... (This may take several minutes)"
run_package_installs >> "$LOGPATH" 2>&1

info_msg "[2/9] Preparing MySQL database..."
run_database_setup >> "$LOGPATH" 2>&1

info_msg "[3/9] Downloading BookStack to ${BOOKSTACK_DIR}..."
run_bookstack_download >> "$LOGPATH" 2>&1

info_msg "[4/9] Installing Composer (PHP dependency manager)..."
run_install_composer >> "$LOGPATH" 2>&1

info_msg "[5/9] Installing PHP dependencies using composer..."
run_install_bookstack_composer_deps >> "$LOGPATH" 2>&1

info_msg "[6/9] Creating and populating BookStack .env file..."
run_update_bookstack_env >> "$LOGPATH" 2>&1

info_msg "[7/9] Running initial BookStack database migrations..."
run_bookstack_database_migrations >> "$LOGPATH" 2>&1

info_msg "[8/9] Setting BookStack file & folder permissions..."
run_set_application_file_permissions >> "$LOGPATH" 2>&1

info_msg "[9/9] Configuring nginx server..."
run_configure_nginx >> "$LOGPATH" 2>&1

info_msg "----------------------------------------------------------------"
info_msg "Setup finished, your BookStack instance should now be installed!"
info_msg "- Default login email: admin@admin.com"
info_msg "- Default login password: password"
info_msg "- Access URL: http://$CURRENT_IP/ or http://$DOMAIN/"
info_msg "- BookStack install path: $BOOKSTACK_DIR"
info_msg "- Install script log: $LOGPATH"
info_msg "---------------------------------------------------------------"