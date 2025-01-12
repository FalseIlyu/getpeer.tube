#!/usr/bin/env sh

# This script builds PeerTube official docker stack in /var/peertube
#
# SHELL command: `curl https://getpeer.tube | sh`
#
# Source: https://github.com/kimsible/getpeer.tube

{
#################
### CONSTANTS ###
#################

# Default branch
if [ ! "$GIT_BRANCH" ]; then
  GIT_BRANCH="master"
fi

# Peertube: https raw url of docker production PeerTube setup
PEERTUBE_DOCKER_RAW_URL=https://raw.githubusercontent.com/kimsible/getpeer.tube/$GIT_BRANCH

# Docker: needs version matching with v3.3 Compose file format
# https://docs.docker.com/compose/compose-file/compose-versioning/
DOCKER_PREREQUISITE_RELEASE=17.06.01

# Docker Compose binary path
COMPOSE=/usr/local/bin/docker-compose

# PeerTube Working directory
WORKDIR=/var/peertube

# PeerTube CLI binary path
CLI=/usr/sbin/peertube

# PeerTube Service Path
SERVICE_PATH=/etc/systemd/system/peertube.service

# Colors
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Response Type
WARNING=${ORANGE}WARNING${NC}
ERROR=${RED}ERROR${NC}
OK=${GREEN}OK${NC}
DONE=${GREEN}done${NC}

#################
### FUNCTIONS ###
#################

# Test if a program is installed
has() {
  type "$1" > /dev/null 2>&1
}

curlf() {
  STATUSCODE=`curl -sSL --write-out "%{http_code}" $1 -o $2`
  [ "$STATUSCODE" -ne 200 ] && echo $ERROR && echo "${ORANGE}HTTP $STATUSCODE${NC} ${RED}$1${NC}" && exit 1
}

# Get latest file from GitHub raw
get_latest_file() {
  remote_path=$1
  local_path=$2
  curlf "$PEERTUBE_DOCKER_RAW_URL$remote_path" "$local_path"
}

# Get docker-compose release from GitHub
get_docker_compose() {
  release=$1
  download_url="https://github.com/docker/compose/releases/download/$release/docker-compose-`uname -s`-`uname -m`"
  curlf "$download_url" "$COMPOSE"
  chmod +x "$COMPOSE" # asign execution right
}

# Get latest release name from GitHub api
get_latest_release_name() {
  repo=$1
  api_url="https://api.github.com/repos/$repo/releases/latest"
  curl -sfL $api_url |
    grep '"tag_name":' |         # Get tag line
    sed -E 's/.*"([^"]+)".*/\1/' # Pluck JSON value
}

get_release_short() {
  release=$1
  release_short=`echo "${release%.*}"`
  echo "$release_short" | sed 's/v//g' # Remove prefix "v"
}

get_release_patch() {
  release=$1
  echo "${release##*.}"
}

get_release_major() {
  release=$1
  release_short=`get_release_short $release`
  echo "${release_short%.*}"
}

get_release_minor() {
  release=$1
  release_short=`get_release_short $release`
  echo "${release_short##*.}"
}

is_update() {
  current_release=$1
  latest_release=$2
  current_short=`get_release_short "$current_release"`
  latest_short=`get_release_short "$latest_release"`
  if [ "$current_short" = "$latest_short" ]; then
    current_patch=`get_release_patch "$current_release"`
    latest_patch=`get_release_patch "$latest_release"`
    [ "$latest_patch" -le "$current_patch" ] && true
  else
    latest_major=`get_release_major $latest_release`
    latest_minor=`get_release_minor $latest_release`
    current_major=`get_release_major $current_release`
    current_minor=`get_release_minor $current_release`
    [ "$latest_major" = "$current_major" ] && [ "$latest_minor" -le "$current_minor" ] && true || [ "$latest_major" -lt "$current_major" ] && true
  fi
}

get_current_release() {
  command=$1
  echo `$command` |grep -o -E "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"
}

validate_domain() {
  echo "$1" |grep -P -i '^[a-z0-9]{1}[a-z0-9.-]*[a-z0-9]{1}\.[a-z]{2}'
}

validate_email() {
  echo "$1" |grep -P -i '^[a-z0-9]+@[a-z0-9]+\.[a-z]{2}'
}

prompt() {
  read -p "What is your $1? " INPUT

  while [ -z "`validate_$1 $INPUT`" ]; do
    echo "${ERROR}: ${ORANGE}$INPUT${NC} is not a valid $1, please enter a valid one" >&2 # prompt error after failed
    read -p "What is your $1? " INPUT
  done

  echo $INPUT
}

#################
##### MAIN ######
#################

# Step 1
echo "Prerequisites \\"
missing_prerequisites=0

# root
uid=`id -u`
if [ "$uid" -ne 0 ]; then
  missing_prerequisites=1
  sudo_command="curl https://getpeer.tube -o getpt.sh && sudo -E sh getpt.sh"
  echo " $ERROR: must be run as root or sudoer user with ${ORANGE}$sudo_command${NC}"
else
  echo " root $OK"
fi

# systemd
if ! has "systemctl"; then
  missing_prerequisites=1
  echo " $ERROR:systemd is missing"
else
  echo " systemd $OK"
fi

# curl
if ! has "curl"; then
  missing_prerequisites=1
  echo " $ERROR: curl is missing"
else
  echo " curl $OK"
fi

# docker
if ! has "docker"; then
  missing_prerequisites=1
  echo " $ERROR: docker >= $DOCKER_PREREQUISITE_RELEASE is missing"
else
  docker_current_release=`get_current_release "docker -v"`
  if ! is_update "$docker_current_release" "$DOCKER_PREREQUISITE_RELEASE"; then
    missing_prerequisites=1
    echo " $ERROR: docker >= $DOCKER_PREREQUISITE_RELEASE is required, found $docker_current_release"
  else
    echo " docker $OK"
  fi
fi

# domain
if [ ! -z "$MY_DOMAIN" ]; then
  if [ -z "`validate_domain $MY_DOMAIN`" ]; then
    missing_prerequisites=1
    echo " $ERROR: ${ORANGE}$MY_DOMAIN${NC} is not a valid domain"
  fi
fi

# email
if [ ! -z "$MY_EMAIL_ADDRESS" ]; then
  if [ -z "`validate_email $MY_EMAIL_ADDRESS`" ]; then
    missing_prerequisites=1
    echo " $ERROR: ${ORANGE}$MY_EMAIL_ADDRESS${NC} is not a valid email"
  fi
fi

# Exit if not all prerequisites
if [ "$missing_prerequisites" -ne 0 ]; then exit 1; fi

# Check if a stack is alreay installed
if [ -f $WORKDIR/.env ] || [ -f $WORKDIR/docker-compose.yml ] || [ -f $WORKDIR/docker-volume ]; then
  # Step 2
  echo "\n${ORANGE}Docker stack already exists in $WORKDIR${NC}"
  echo "\nUpgrading ${GREEN}Compose${NC} and ${GREEN}CLI${NC} only \\"
  UPGRADE=1
fi

# No need to prompt domain/email and create docker user when upgrading
if [ -z "$UPGRADE" ]; then
  # Prompt $MY_DOMAIN if not defined
  if [ -z $MY_DOMAIN ]; then
    MY_DOMAIN=`prompt "domain"`
  fi

  # Prompt $MY_EMAIL_ADDRESS if not defined
  if [ -z $MY_EMAIL_ADDRESS ]; then
    MY_EMAIL_ADDRESS=`prompt "email"`
  fi

  # Display used environment variables
  echo " ${ORANGE}admin email${NC} → using ${GREEN}$MY_EMAIL_ADDRESS${NC}"
  echo " ${ORANGE}domain name${NC} → using ${GREEN}$MY_DOMAIN${NC}"

  # Step 2
  echo "\nPreparing environment \\"

  # Docker: make sure a non-root docker user system exists
  echo -n "Creating a non-root docker user system ... "
  useradd >/dev/null 2>&1 -r -M -g docker docker # redirect out message if user already exists
  echo $DONE
fi

# Other architectures than x86_64
if [ -z "`uname -a | grep -o "x86_64"`" ]; then
  echo "$WARNING: Compose Binary can't be installed on your architecture"
  COMPOSE="docker-compose"
  if ! has "$COMPOSE"; then
    echo "$ERROR: Unfortunately docker-compose is not installed on your system"
    exit 1
  else
    compose_current_release=`get_current_release "$COMPOSE -v"`
    echo " → using system version ${GREEN}$compose_current_release${NC}"
  fi
else
  # Install or upgrade docker-compose
  echo -n "Checking latest release of Compose     ... "
  compose_latest_release=`get_latest_release_name "docker/compose"`
  [ -z "$compose_latest_release" ] && echo "${RED}Cannot resolve GitHub releases URL${NC}" && exit 1
  echo $DONE

  if ! has "$COMPOSE"; then
    echo -n "Installing Docker Compose $compose_latest_release       ... "
    get_docker_compose "$compose_latest_release"
    echo $DONE
    echo " → into ${ORANGE}$COMPOSE${NC}"
  else
    compose_current_release=`get_current_release "$COMPOSE -v"`

    if ! is_update "$compose_current_release" "$compose_latest_release"; then
      echo -n "Upgrading Docker Compose               ... "
      get_docker_compose "$compose_latest_release"
      echo $DONE
      echo " → from $compose_current_release to ${GREEN}$compose_latest_release${NC}"
    else
      echo " → using current version ${GREEN}$compose_current_release${NC}"
    fi
  fi
fi

# Get latest peertube cli
echo -n "Installing CLI into ${ORANGE}$CLI${NC} ... "
rm -f $CLI
get_latest_file "/cli/peertube" "$CLI"
chmod +x $CLI
echo $DONE

# Stop here if upgrading docker-compose / CLI
if [ ! -z "$UPGRADE" ]; then
  echo "\n${GREEN}Docker Compose and the CLI are now successfully upgraded!${NC}\n"
  exit 1
fi

# Init workdir
echo -n "Creating ${ORANGE}$WORKDIR${NC}                 ... "
mkdir -p "$WORKDIR/docker-volume"
cd "$WORKDIR"
mkdir -p docker-volume/certbot # Init docker-volume and certbot directory
mkdir -p docker-volume/nginx # Init nginx directory
echo $DONE

# Randomize PostgreSQL username and password
echo -n "Generating PostgreSQL credentials      ... "

MY_POSTGRES_USERNAME="`head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10`"
MY_POSTGRES_PASSWORD=`date +%s | sha256sum | base64 | head -c 32`

echo $DONE

# Create / override .env
echo -n "Generating ${ORANGE}$WORKDIR/.env${NC}          ... "

cat <<EOT > .env
POSTGRES_USER=<MY POSTGRES USERNAME>
POSTGRES_PASSWORD=<MY POSTGRES PASSWORD>
POSTGRES_DB=peertube
PEERTUBE_DB_USERNAME=<MY POSTGRES USERNAME>
PEERTUBE_DB_PASSWORD=<MY POSTGRES PASSWORD>
PEERTUBE_DB_HOSTNAME=postgres
PEERTUBE_WEBSERVER_HOSTNAME=<MY DOMAIN>
PEERTUBE_TRUST_PROXY=["127.0.0.1", "loopback", "172.18.0.0/16"]
PEERTUBE_SMTP_HOSTNAME=postfix
PEERTUBE_SMTP_PORT=25
PEERTUBE_SMTP_FROM=noreply@<MY DOMAIN>
PEERTUBE_SMTP_TLS=false
PEERTUBE_SMTP_DISABLE_STARTTLS=false
PEERTUBE_ADMIN_EMAIL=<MY EMAIL ADDRESS>
POSTFIX_myhostname=<MY DOMAIN>
OPENDKIM_DOMAINS=<MY DOMAIN>=peertube
OPENDKIM_RequireSafeKeys=no
EOT

# Auto-fill .env file
sed -i -e "s/<MY EMAIL ADDRESS>/$MY_EMAIL_ADDRESS/g" .env
sed -i -e "s/<MY DOMAIN>/$MY_DOMAIN/g" .env
sed -i -e "s/<MY POSTGRES USERNAME>/$MY_POSTGRES_USERNAME/g" .env
sed -i -e "s/<MY POSTGRES PASSWORD>/$MY_POSTGRES_PASSWORD/g" .env

echo $DONE

# Copy nginx config
echo -n "Installing latest ${ORANGE}nginx${NC} config         ... "
get_latest_file "/nginx/peertube" "docker-volume/nginx/peertube"
echo $DONE

# Copy docker-compose files
echo -n "Installing latest ${ORANGE}compose${NC} file         ... "
get_latest_file "/docker/docker-compose.yml" "docker-compose.yml"
echo $DONE

# chown on workdir
echo -n "Assigning $WORKDIR ownership      ... "
chown -R docker:docker "$WORKDIR"
echo $DONE

# Create / override systemd service
echo -n "Generating systemd peertube.service    ... "

cat <<EOT > $SERVICE_PATH
[Unit]
Description=PeerTube daemon
Requires=docker.service
After=docker.service

[Service]
TimeoutStartSec=0
Restart=on-failure
StartLimitBurst=3
User=docker
Group=docker
WorkingDirectory=$WORKDIR
ExecStart=$COMPOSE up
ExecStop=$COMPOSE stop peertube

[Install]
WantedBy=multi-user.target
EOT

echo $DONE

# Enable peertube systemd service
echo -n "Enabling systemd peertube.service      ... "
systemctl >/dev/null 2>&1 daemon-reload # redirect out possible errors
systemctl >/dev/null 2>&1 enable peertube
echo $DONE

# Step 3 - Compose pull
echo "\nPulling docker images \\"
$COMPOSE pull

# Step 4 - Generate the first SSL certificate using Let's Encrypt
echo "\nGenerating SSL certificate using Let's Encrypt \\"
$CLI certbot:init

# Step 5 - Compose Up
echo "\nUp docker stack \\"
$CLI stack:up
systemctl start --no-block peertube # be sure start process does not block stdout

# Success message
cat <<EOF
                      ______                           _______         _
                 _   (_____ \                         (_______)       | |
  ____  _____  _| |_  _____) ) _____  _____   ____        _     _   _ | |__   _____
 / _  || ___ |(_   _)|  ____/ | ___ || ___ | / ___)      | |   | | | ||  _ \ | ___ |
( (_| || ____|  | |_ | |      | ____|| ____|| |     _    | |   | |_| || |_) )| ____|
 \___ ||_____)   \__)|_|      |_____)|_____)|_|    (_)   |_|   |____/ |____/ |_____)
(_____|

EOF

echo "${GREEN}The PeerTube docker stack is now successfully installed!${NC}"

cat <<EOF

Get your admin credentials and DKIM DNS TXT Record with:

EOF

echo "  ${ORANGE}$ peertube get-admin-credentials${NC}"
echo "  ${ORANGE}$ peertube postfix:get-dkim-record${NC}"

echo ""
}
