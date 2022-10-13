#!/bin/bash
#
# init-project.sh
# Description:
# Project specific initialization.

# Load logger
. .gp/bash/workspace-init-logger.sh

# BEGIN example code block - migrate database
# . .gp/bash/spinner.sh # COMMENT: Load spinner
# __migrate_msg="Migrating database"
# log_silent "$__migrate_msg" && start_spinner "$__migrate_msg"
# php artisan migrate
# err_code=$?
# if [ $err_code != 0 ]; then
#  stop_spinner $err_code
#  log -e "ERROR: Failed to migrate database"
# else
#  stop_spinner $err_code
#  log "SUCCESS: migrated database"
# fi
# END example code block - migrate database


. .gp/bash/workspace-init-logger.sh
# Parse arguments
while true; do
  case "$1" in
    -h|--help)
      show_help=true
      shift
      ;;
    -v|--verbose)
      set -x
      verbose=true
      shift
      ;;
    -*)
      echo "Error: invalid argument: '$1'" 1>&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

print_usage () {
  grep '^#/' <"$0" | cut -c 4-
  exit 1
}

if [ -n "$show_help" ]; then
  print_usage
else
  for x in "$@"; do
    if [ "$x" = "--help" ] || [ "$x" = "-h" ]; then
      print_usage
    fi
  done
fi



readonly APP_USER="gitpod"
readonly APP_NAME="snipeit"
readonly APP_PATH="/var/www/html/$APP_NAME"

apache_group="gitpod"
apachefile=/etc/apache2/sites-available/$APP_NAME.conf
progress () {
  spin[0]="-"
  spin[1]="\\"
  spin[2]="|"
  spin[3]="/"

  echo -n " "
  while kill -0 "$pid" > /dev/null 2>&1; do
    for i in "${spin[@]}"; do
      echo -ne "\\b$i"
      sleep .3
    done
  done
  echo ""
}

log () {
  if [ -n "$verbose" ]; then
    eval "$@" |& tee -a /var/log/snipeit-install.log
  else
    eval "$@" |& tee -a /var/log/snipeit-install.log >/dev/null 2>&1
  fi
}



create_virtualhost () {
  {
    echo "<VirtualHost *:80>"
    echo "  <Directory $APP_PATH/public>"
    echo "      Allow From All"
    echo "      AllowOverride All"
    echo "      Options -Indexes"
    echo "  </Directory>"
    echo ""
    echo "  DocumentRoot $APP_PATH/public"
    echo "  ServerName $fqdn"
    echo "</VirtualHost>"
  } >> "$apachefile"
}

create_user () {

  usermod -a -G "$apache_group" "$APP_USER"
}

run_as_app_user () {
  if ! hash sudo 2>/dev/null; then
      su -c "$@" $APP_USER
  else
      sudo -i -u $APP_USER "$@"
  fi
}



install_snipeit () {
  create_user

  echo "* Creating MariaDB Database/User."
  echo "* Please Input your MariaDB root password:"
  mysql -u root -p --execute="CREATE DATABASE snipeit;GRANT ALL PRIVILEGES ON snipeit.* TO snipeit@localhost IDENTIFIED BY '$mysqluserpw';"

  echo "* Cloning Snipe-IT from github to the web directory."
  log "git clone https://github.com/modamod/snipe-it $APP_PATH"

  echo "* Configuring .env file."
  cp "$APP_PATH/.env.example" "$APP_PATH/.env"

  #TODO escape SED delimiter in variables
  sed -i '1 i\#Created By Snipe-it Installer' "$APP_PATH/.env"
  sed -i "s|^\\(APP_TIMEZONE=\\).*|\\1$tzone|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_HOST=\\).*|\\1localhost|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_DATABASE=\\).*|\\1snipeit|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_USERNAME=\\).*|\\1snipeit|" "$APP_PATH/.env"
  sed -i "s|^\\(DB_PASSWORD=\\).*|\\1'$mysqluserpw'|" "$APP_PATH/.env"
  sed -i "s|^\\(APP_URL=\\).*|\\1http://$fqdn|" "$APP_PATH/.env"

  echo "* Setting permissions."
  for chmod_dir in "$APP_PATH/storage" "$APP_PATH/public/uploads"; do
    chmod -R 775 "$chmod_dir"
  done

  chown -R "$APP_USER":"$apache_group" "$APP_PATH"

  echo "* Running composer."
  # We specify the path to composer because CentOS lacks /usr/local/bin in $PATH when using sudo
  run_as_app_user /usr/local/bin/composer install --no-dev --prefer-source --working-dir "$APP_PATH"

  sudo chgrp -R "$apache_group" "$APP_PATH/vendor"

  echo "* Generating the application key."
  log "php $APP_PATH/artisan key:generate --force"

  echo "* Artisan Migrate."
  log "php $APP_PATH/artisan migrate --force"

  echo "* Creating scheduler cron."
  (run_as_app_user crontab -l ; echo "* * * * * /usr/bin/php $APP_PATH/artisan schedule:run >> /dev/null 2>&1") | run_as_app_user crontab -
}




rename_default_vhost () {
    log "mv /etc/apache2/sites-enabled/000-default.conf /etc/apache2/sites-enabled/111-default.conf"
    log "mv /etc/apache2/sites-enabled/snipeit.conf /etc/apache2/sites-enabled/000-snipeit.conf"
}


if [[ -f /etc/debian_version || -f /etc/lsb-release ]]; then
  distro="$(lsb_release -is)"
  version="$(lsb_release -rs)"
  codename="$(lsb_release -cs)"
elif [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  distro="$(source /etc/os-release && echo "$ID")"
  # shellcheck disable=SC1091
  version="$(source /etc/os-release && echo "$VERSION_ID")"
  #Order is important here.  If /etc/os-release and /etc/centos-release exist, we're on centos 7.
  #If only /etc/centos-release exist, we're on centos6(or earlier).  Centos-release is less parsable,
  #so lets assume that it's version 6 (Plus, who would be doing a new install of anything on centos5 at this point..)
  #/etc/os-release properly detects fedora
elif [ -f /etc/centos-release ]; then
  distro="centos"
  version="6"
else
  distro="unsupported"
fi

echo '
       _____       _                  __________
      / ___/____  (_)___  ___        /  _/_  __/
      \__ \/ __ \/ / __ \/ _ \______ / /  / /
     ___/ / / / / / /_/ /  __/_____// /  / /
    /____/_/ /_/_/ .___/\___/     /___/ /_/
                /_/
'

echo ""
echo "  Welcome to Snipe-IT Inventory Installer for CentOS, Rocky, Fedora, Debian and Ubuntu!"
echo ""
readonly fqdn="$(hostname --fqdn)"
mysqluserpw="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c16; echo)"


  ubuntu)
# Install for Ubuntu 18.04
tzone=$(cat /etc/timezone)

echo -n "* Updating installed packages."
log "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade" & pid=$!
progress

echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
PACKAGES="mariadb-server mariadb-client apache2 libapache2-mod-php php php-mcrypt php-curl php-mysql php-gd php-ldap php-zip php-mbstring php-xml php-bcmath curl git unzip"
install_packages

echo "* Configuring Apache."
create_virtualhost
log "phpenmod mcrypt"
log "phpenmod mbstring"
log "a2enmod rewrite"
log "a2ensite $APP_NAME.conf"
rename_default_vhost

set_hosts

echo "* Starting MariaDB."
log "systemctl start mariadb.service"

echo "* Securing MariaDB."
/usr/bin/mysql_secure_installation

install_snipeit

echo "* Restarting Apache httpd."
log "systemctl restart apache2"


echo ""
echo "  ***Open http://$fqdn to login to Snipe-IT.***"
echo ""
echo ""
echo "* Cleaning up..."
rm -f snipeit.sh
rm -f install.sh
echo "* Finished!"
sleep 1
