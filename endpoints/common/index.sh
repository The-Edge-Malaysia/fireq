#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export DBUS_SESSION_BUS_ADDRESS=/dev/null
export PATH=./node_modules/.bin/:$PATH

root=$(pwd)
name=${name:-liveblog}
host=${host:-localhost}
repo=/opt/$name
repo_remote=${repo_remote:-'https://github.com/liveblog/liveblog.git'}
repo_ref=${repo_ref:-'heads/master'}
repo_sha=${repo_sha:-''}
repo_pr=${repo_pr:-''}
env=$repo/env
envfile=$repo/envfile
action=${action:-do_install}

_envfile_append() {
    cat <<EOF
# Liveblog custom
S3_THEMES_PREFIX=
EOF
}

_envfile() {
    MONGO_URI=${MONGO_URI:-"mongodb://localhost/${db_name}"}
    LEGAL_ARCHIVE_URI=${LEGAL_ARCHIVE_URI:-"${MONGO_URI}_la"}
    ARCHIVED_URI=${ARCHIVED_URI:-"${MONGO_URI}_ar"}
    CONTENTAPI_MONGO_URI=${CONTENTAPI_MONGO_URI:-"${MONGO_URI}_ca"}

    ELASTICSEARCH_URL=${ELASTICSEARCH_URL:-"http://localhost:9200"}
    ELASTICSEARCH_INDEX=${ELASTICSEARCH_INDEX:-"${name}"}
    CONTENTAPI_ELASTICSEARCH_INDEX=${CONTENTAPI_ELASTICSEARCH_INDEX:-"${ELASTICSEARCH_INDEX}_ca"}

    set +x
    config=../etc/${name}.sh
    [ -f $config ] && . $config

    . $root/common/envfile.tpl > $envfile
    echo "$(_envfile_append)" >> $envfile
    set -x

    if [ -n "$SUPERDESK_TESTING" ]; then
        echo SUPERDESK_TESTING=True  >> $envfile
        echo CELERY_ALWAYS_EAGER=True  >> $envfile
    fi
}

_repo() {
    [ -d $repo ] && rm -rf $repo
    mkdir $repo
    cd $repo
    git init
    git remote add origin $repo_remote

    if [ -n "$repo_pr" ]; then
        git fetch origin $repo_ref/merge: || git fetch origin $repo_ref/head:
        # TODO: use latest sha for now
        git checkout FETCH_HEAD
    else
        git fetch origin $repo_ref:
        git checkout ${repo_sha:-FETCH_HEAD}
    fi
}

_venv() {
    python3 -m venv $env
    echo "set -a +x; . $envfile; set +a" >> $env/bin/activate
    _activate
    pip install -U pip wheel
}

_activate() {
    . $env/bin/activate
    set -x
}

_supervisor_append() { :; }
_supervisor() {
    supervisor_tpl=${supervisor_tpl:-"$root/common/supervisor.tpl"}

    apt-get -y install supervisor

    logs=/var/log/$name
    [ -d $logs ] || mkdir $logs

    path=/etc/supervisor/conf.d/${name}.conf
    . $supervisor_tpl > $path
    echo "$(_supervisor_append)" >> $path
    systemctl enable supervisor
    systemctl restart supervisor
}

_npm() {
    # node & npm
    curl -sL https://deb.nodesource.com/setup_7.x | sudo -E bash -
    apt-get install -y nodejs
    [ -f /usr/bin/node ] || ln -s /usr/bin/nodejs /usr/bin/node

    npm --version
    node --version
}

_repo_client() {
    echo $repo/client
}

_nginx_locations() { :; }
_nginx() {
    nginx_tpl=${nginx_tpl:-"$root/common/nginx.tpl"}
    nginx_ssl=$([ -n "$nginx_ssl" ] && echo 's' || echo '')
    nginx_static="$(_repo_client)/dist"

    wget -qO - http://nginx.org/keys/nginx_signing.key | sudo apt-key add -
    echo "deb http://nginx.org/packages/ubuntu/ xenial nginx" \
        > /etc/apt/sources.list.d/nginx.list

    apt-get -y update
    apt-get -y install nginx

    path=/etc/nginx/conf.d
    cp $root/common/nginx-params.conf $path/params.conf
    echo "$(_nginx_locations)" > $path/locations
    . $nginx_tpl > $path/default.conf

    cd $nginx_static
    sed -i \
        -e "s|http://localhost:5000|https://$host|" \
        -e "s|ws://localhost:5100|wss://$host/ws|" \
        -e 's|iframely:{key:""}|iframely:{key:"'$IFRAMELY_KEY'"}|' \
        -e 's|raven:{dsn:""}|raven:{dsn:"'$SENTRY_DSN_PUBLIC'"}|' \
        app.bundle.*.js

    systemctl enable nginx
    systemctl restart nginx
}

do_init() {
    apt-get -y install --no-install-recommends \
    git python3 python3-dev python3-venv \
    build-essential libffi-dev \
    libtiff5-dev libjpeg8-dev zlib1g-dev \
    libfreetype6-dev liblcms2-dev libwebp-dev \
    curl libfontconfig libssl-dev

    locale-gen en_US.UTF-8

    _repo
    _envfile
}

do_backend() {
    _venv
    cd $repo/server
    pip install -U -r requirements.txt
}

do_frontend() {
    _activate
    _npm

    cd $(_repo_client)
    npm install grunt-cli bower
    time npm install
    time bower --allow-root install
    time grunt build --server='http://localhost:5000/api' --ws='ws://localhost:5100' --force
    echo "\033[0m"
}

do_prepopulate() {
    _activate
    cd $repo/server
    python manage.py app:initialize_data
    python manage.py users:create -u admin -p admin -e 'admin@example.com' --admin true
    python manage.py register_local_themes
}

do_finish() { :; }

do_services() {
    apt-get -y install software-properties-common

    #elasticsearch
    wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
    echo "deb http://packages.elastic.co/elasticsearch/1.7/debian stable main" \
        > /etc/apt/sources.list.d/elastic.list

    #mongodb
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv EA312927
    echo "deb http://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/3.2 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-3.2.list

    #redis
    add-apt-repository -y ppa:chris-lea/redis-server

    #install
    apt-get -y update
    apt-get -y install --no-install-recommends \
        openjdk-8-jre-headless \
        elasticsearch \
        mongodb-org-server \
        redis-server

    # tune elasticsearch
    config='/etc/elasticsearch/elasticsearch.yml'
    [ -f "${config}.bak" ] || mv $config $config.bak
    cat << EOF > $config
$pattern
network.bind_host: 0.0.0.0
node.local: true
discovery.zen.ping.multicast: false
EOF

    # tune mongo
    config=/etc/mongod.conf
    [ -f "${config}.bak" ] || mv $config $config.bak
    cat << EOF > $config
storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true
  engine: wiredTiger

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 0.0.0.0
EOF

    services="elasticsearch.service mongod.service redis-server.service"
    systemctl enable $services
    systemctl restart $services
}

do_install() {
    # don't need unexpected apt-get running
    echo 'APT::Periodic::Enable "0";' > /etc/apt/apt.conf.d/10periodic

    apt-get -y autoremove --purge ntpdate
    apt-get -y update

    do_init

    frontend=${frontend-1}
    backend=${backend-1}

    [ -n "$services" ] && do_services
    [ -n "$backend" ] && do_backend
    [ -n "$frontend" ] && do_frontend
    [ -n "$prepopulate" ] && do_prepopulate

    do_finish

    _supervisor
    _nginx
    apt-get -y clean
}