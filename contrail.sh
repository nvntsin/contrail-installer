# proto is https or ssh
#! /bin/bash

# Contrail NFV
# ------------
if [[ $EUID -eq 0 ]]; then
    echo "You are running this script as root."
    echo "Cut it out."
    exit 1
fi
# Save trace setting
TOP_DIR=`pwd`
CONTRAIL_USER=$(whoami)
source functions
source localrc

if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
    ENABLED_SERVICES=named,dns,redis,cass,zk,ifmap,disco,apiSrv,schema,svc-mon,control,collector,analytics-api,query-engine,agent,redis-w,ui-jobs,ui-webs
else
    ENABLED_SERVICES=named,dns,redis,cass,zk,ifmap,disco,apiSrv,schema,svc-mon,control,collector,analytics-api,query-engine,agent,redis-w
fi

# Determine what system we are running on. This provides ``os_VENDOR``,
# ``os_RELEASE``, ``os_UPDATE``, ``os_PACKAGE``, ``os_CODENAME``
# and ``DISTRO``
GetDistro

BS_FL_CONTROLLERS_PORT=${BS_FL_CONTROLLERS_PORT:-localhost:80}
BS_FL_OF_PORT=${BS_FL_OF_PORT:-6633}

# Cassandra JAVA Memory Options
CASS_MAX_HEAP_SIZE=${CASS_MAX_HEAP_SIZE:-1G}
CASS_HEAP_NEWSIZE=${CASS_HEAP_NEWSIZE:-200M}
GIT_BASE=${GIT_BASE:-git://github.com}
CONTRAIL_BRANCH=${CONTRAIL_BRANCH:-master}
NEUTRON_PLUGIN_BRANCH=${NEUTRON_PLUGIN_BRANCH:-CONTRAIL_BRANCH}
Q_META_DATA_IP=${Q_META_DATA_IP:-127.0.0.1}
ZK_VER=${ZK_VER:-3.4.6}

unset LANG
unset LANGUAGE
LC_ALL=C
export LC_ALL

# Set up logging level
CONTRAIL_REPO_PROTO=${CONTRAIL_REPO_PROTO:-ssh}
CONTRAIL_SRC=${CONTRAIL_SRC:-/opt/stack/contrail}
LOG_DIR=${LOG_DIR:-$TOP_DIR/log/screens}
LOG_LEVEL=${LOG_LEVEL:-3}
CONTRAIL_ADMIN_USERNAME=${CONTRAIL_ADMIN_USERNAME:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-contrail123}
CONTRAIL_ADMIN_TENANT=${CONTRAIL_ADMIN_TENANT:-admin}
CFGM_IP=${SERVICE_HOST:-127.0.0.1}
if [[ "$CFGM_IP" == "localhost" ]] ; then
    CFGM_IP="127.0.0.1"
fi
USE_CERTS=${USE_CERTS:-false}
MULTI_TENANCY=${MULTI_TENANCY:-false}
PUPPET_SERVER=${PUPPET_SERVER:-''}

RABBIT_IP=${RABBIT_IP:-$CFGM_IP}
CASSANDRA_IP=${CASSANDRA_IP:-'localhost'}
OPENSTACK_IP=${OPENSTACK_IP:-$CFGM_IP}
COLLECTOR_IP=${COLLECTOR_IP:-$CFGM_IP}
DISCOVERY_IP=${DISCOVERY_IP:-$CFGM_IP}
CONTROL_IP=${CONTROL_IP:-$CFGM_IP}
IFMAP_IP=${IFMAP_IP:-$CFGM_IP}
COMPUTE_HOST_IP=${COMPUTE_HOST_IP:-127.0.0.1}

CASSANDRA_IP_LIST=${CASSANDRA_IP_LIST:-127.0.0.1}
COLLECTOR_IP_LIST=${COLLECTOR_IP_LIST:-$CFGM_IP}
ZOOKEEPER_IP_LIST=${ZOOKEEPER_IP_LIST:-127.0.0.1}
CONTROL_IP_LIST=${CONTROL_IP_LIST:-$CONTROL_IP}
DNS_IP_LIST=${DNS_IP_LIST:-$CONTROL_IP}

CONTRAIL_DEFAULT_INSTALL=${CONTRAIL_DEFAULT_INSTALL:-True}
LAUNCHPAD_REPO=${LAUNCHPAD_BRANCH:-snapshots}

USE_DISCOVERY=${USE_DISCOVERY:-False}

RABBIT_USER=${RABBIT_USER:-rabbitcontrail}

TARGET=${TARGET:-production}
SCONS_ARGS="--opt=$TARGET"

NB_JOBS=${NB_JOBS:-1}
if [ $NB_JOBS -gt 1 ]; then
    SCONS_ARGS="-j$NB_JOBS $SCONS_ARGS"
fi

if [[ "$RECLONE" == "True" ]]; then
    echo "Recloning the contrail again"
    sudo rm .stage.txt
fi
function generate_env {
    local srvcnt=$(echo $ENABLED_SERVICES | tr -cd , | wc -c)
    srvcnt=$((srvcnt+1))
    echo "NUM_ENABLED_SERVICES=$srvcnt" > taskrc
}

#Setup root access with sudoers
function setup_root_access {
    # We're not **root**, make sure ``sudo`` is available
    is_package_installed sudo || install_package sudo

    # UEC images ``/etc/sudoers`` does not have a ``#includedir``, add one
    sudo grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers

    # Set up devstack sudoers
    TEMPFILE=`mktemp`
    echo "$CONTRAIL_USER ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    # Some binaries might be under /sbin or /usr/sbin, so make sure sudo will
    # see them by forcing PATH
    echo "Defaults:$CONTRAIL_USER secure_path=/sbin:/usr/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin" >> $TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_contrail_sh

    grep -q `hostname` /etc/hosts ||
        echo "127.0.0.1 `hostname`" | sudo tee -a /etc/hosts
    grep -q `whoami` /etc/hosts ||
        echo "127.0.0.1 `whoami`" | sudo tee -a /etc/hosts
}

# Draw a spinner so the user knows something is happening
function spinner() {
    local delay=0.75
    local spinstr='/-\|'
    printf "..." >&3
    while [ true ]; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b" >&3
    done
}
    
# Echo text to the log file, summary log file and stdout
# echo_summary "something to say"
function echo_summary() {
        echo -e $@ >&6
}

# Echo text only to stdout, no log files
# echo_nolog "something not for the logs"
function echo_nolog() {
    echo $@ >&3
}

#echo messages redirected to stderr with echo_msg
#echo_msg "something to say"
function echo_msg() {
    echo -e $@ >&2
}

    

function setup_logging() { 
    # Set up logging for ``contrail.sh``
    # Set ``LOGFILE`` to turn on logging
    # Append '.xxxxxxxx' to the given name to maintain history
    # where 'xxxxxxxx' is a representation of the date the file was created
    TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT:-"%F-%H%M%S"}
    if [[ -n "$LOGFILE" || -n "$LOG_DIR" ]]; then
        LOGDAYS=${LOGDAYS:-7}
        CURRENT_LOG_TIME=$(date "+$TIMESTAMP_FORMAT")
    fi

    if [[ -n "$LOGFILE" ]]; then
        # First clean up old log files.  Use the user-specified ``LOGFILE``
        # as the template to search for, appending '.*' to match the date
        # we added on earlier runs.
        LOGDIR=$(dirname "$LOGFILE")
        LOGFILENAME=$(basename "$LOGFILE")
        mkdir -p $LOGDIR
        mkdir -p $LOG_DIR
        find $LOGDIR -maxdepth 1 -name $LOGFILENAME.\* -mtime +$LOGDAYS -exec rm {} \;
        LOGFILE=$LOGFILE.${CURRENT_LOG_TIME}
        SUMFILE=$LOGFILE.${CURRENT_LOG_TIME}.summary

        # Redirect output according to config

        # Copy stdout to fd 3

	#summary statements into LOGFILE,SUMMARY LOG File and console
	#Always stderr into logfile,console.
	#For LOG_LEVEL 1 stdout into logfile.
	#For LOG_LEVEL 2 stdout into logfile.xtrace enabled.
	#For LOG_LEVEL 3 stdout into logfile,console.xtrace enabled
       
        exec 6> >( tee -a "${SUMFILE}" "${LOGFILE}" )
        exec 3>&1
        exec 2> >( awk '
                      {
                          cmd ="date +\"%Y-%m-%d %H:%M:%S \""
                          cmd | getline now
                          close("date +\"%Y-%m-%d %H:%M:%S \"")
                          sub(/^/, now)
                          print
                          fflush()
               }' | tee -a "${LOGFILE}" )

        if [ $LOG_LEVEL -eq 1 ];then
            exec 1> >( awk '
                    {
                        cmd ="date +\"%Y-%m-%d %H:%M:%S \""
                        cmd | getline now
                        close("date +\"%Y-%m-%d %H:%M:%S \"")
                        sub(/^/, now)
                        print
                        fflush()
	            }' | tee -a "${LOGFILE}">/dev/null) 
	 
	elif [ $LOG_LEVEL -eq 2 ]; then
                exec 1> >( awk '
                        {
                            cmd ="date +\"%Y-%m-%d %H:%M:%S \""
                            cmd | getline now
                            close("date +\"%Y-%m-%d %H:%M:%S \"")
                            sub(/^/, now)
                            print
                            fflush()
                        }' | tee -a "${LOGFILE}">/dev/null)
                set -x 
 
        elif [ $LOG_LEVEL -eq 3 ]; then
                exec 1> >( awk '
                        {
                            cmd ="date +\"%Y-%m-%d %H:%M:%S \""
                            cmd | getline now
                            close("date +\"%Y-%m-%d %H:%M:%S \"")
                            sub(/^/, now)
                            print
                            fflush()
                        }' | tee -a "${LOGFILE}" )
                set -x 
        fi

        echo_summary "contrail.sh log $LOGFILE"
        # Specified logfile name always links to the most recent log
        ln -sf $LOGFILE $LOGDIR/$LOGFILENAME
        ln -sf $SUMFILE $LOGDIR/$LOGFILENAME.summary
    else
        # Set up output redirection without log files
        # Copy stdout to fd 3
        exec 3>&1
        # Throw away stdout and stderr
        exec 1>/dev/null 2>&1
        # Always send summary fd to original stdout
        exec 6>&3
    fi
}

setup_logging

function download_redis {
    echo "Downloading dependencies"
    if is_ubuntu; then
        if ! which redis-server > /dev/null 2>&1 ; then
            sudo apt-get -y install redis-server
            sudo service redis-server stop
        fi
    else
        if ! which redis-server > /dev/null 2>&1 ; then
            yum_install redis
            sudo service redis-server stop
        fi
    fi
}

function download_node_for_npm {
    # install node which brings npm that's used in fetch_packages.py
    if ! which node > /dev/null 2>&1 || ! which npm > /dev/null 2>&1 ; then
        # download nodejs if building from source or centos
        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]] || [[ ! is_ubuntu ]]; then
            contrail_cwd_root=$(pwd)
            cd $CONTRAIL_SRC/third_party    
            contrail_cwd=$(pwd)
            cd node-v0.10.35
            ./configure; make; sudo make install
            cd ${contrail_cwd}
            rm -rf node-v0.10.35.tar.gz
            rm -rf node-v0.10.35
            cd ${contrail_cwd_root}
        else
            apt_get install nodejs=0.10.35-1contrail1
        fi
    fi
}

function download_dependencies {
    echo "Downloading dependencies"
    if is_ubuntu; then
        apt_get update
        apt_get install python-setuptools
        apt_get install python-novaclient
        apt_get install curl
	    if [[ "$DISTRO" != "trusty" ]]; then
            apt_get install chkconfig
        else
            apt_get install sysv-rc-conf
        fi
        apt_get install screen
        apt_get install default-jdk javahelper
        apt_get install libcommons-codec-java libhttpcore-java liblog4j1.2-java
	    apt_get install python-software-properties
        sudo -E add-apt-repository -y cloud-archive:havana
        sudo -E add-apt-repository -y ppa:opencontrail
        apt_get update

        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
            apt_get install patch scons flex bison make vim unzip
            apt_get install libexpat-dev libgettextpo0 libcurl4-openssl-dev
            apt_get install python-dev autoconf automake build-essential libtool protobuf-compiler libprotobuf-dev
            apt_get install libevent-dev libxml2-dev libxslt-dev librdkafka-dev
            apt_get install uml-utilities
            apt_get install python-software-properties
            apt_get install python-lxml python-redis python-jsonpickle
            apt_get install ant debhelper 
            apt_get install linux-headers-$(uname -r)
            apt_get install libipfix-dev
            apt_get install python-docker-py
            apt_get install libzookeeper-mt2 libzookeeper-mt-dev
            apt_get install libpcap-dev
            apt_get install python-sseclient
            download_cassandra_cpp_drivers
        fi	
        apt_get install libvirt-bin
        apt_get install python-neutron
        if [[ ${DISTRO} =~ (trusty) ]]; then
            apt_get install software-properties-common
            apt_get install libboost-dev libboost-chrono-dev libboost-date-time-dev
            apt_get install libboost-filesystem-dev libboost-program-options-dev
            apt_get install libboost-python-dev libboost-regex-dev libboost-system-dev
            apt_get install libboost-thread-dev libcurl4-openssl-dev google-mock
            apt_get install libgoogle-perftools-dev liblog4cplus-dev libtbb-dev
            apt_get install libhttp-parser-dev libxml2-dev libicu-dev
        fi
        if [ "$INSTALL_PROFILE" = "ALL" ]; then
            apt_get install rabbitmq-server
            apt_get install python-kombu
        fi
        apt_get install python-sphinx
        # ping requirements
        apt_get install sshpass expect
    else
        yum_install wget

        #comment to be updated #harsha # the epel 7 repository is added for installation of packages not commonly available
        if ! rpm -q epel-release-7-5.noarch.rpm ; then
            wget https://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
            sudo rpm -Uvh epel-release-7-5.noarch.rpm
        fi
       
        yum_install patch scons flex bison make vim bzip2 unzip
        yum_install expat-devel gettext-devel curl-devel
        yum_install gcc-c++ python-devel autoconf automake libtool
        yum_install protobuf-compiler protobuf protobuf-devel
        yum_install libevent libevent-devel libcurl-devel libxml2-devel libxslt-devel
        yum_install openssl-devel boost-devel tbb-devel
        yum_install libvirt
        yum_install python-setuptools net-tools 
        yum_install python-lxml 
        yum_install libpcap libpcap-devel
        yum_install curl
        yum_install chkconfig screen 
        yum_install erlang
        yum_install python-sphinx
        yum_install python-kombu

        #disabling firewall port for rabbitmq
        yum_install rabbitmq-server
        sudo firewall-cmd --permanent --add-port=5672/tcp
        sudo firewall-cmd --reload
        sudo setsebool -P nis_enabled 1 
        sudo service rabbitmq-server start
        sudo chkconfig rabbitmq-server on
     
        #added for installing python-neutron
        wget ftp://ftp.pbone.net/mirror/ftp.scientificlinux.org/linux/scientific/7.0/x86_64/os/Packages/kernel-devel-3.10.0-123.el7.x86_64.rpm
        wget https://repos.fedorapeople.org/repos/openstack/openstack-juno/rdo-release-juno-1.noarch.rpm
        sudo rpm -Uvh rdo-release-juno-1.noarch.rpm
        yum_install python-neutron

        # for installing kenel-devel
        wget ftp://ftp.pbone.net/mirror/ftp.scientificlinux.org/linux/scientific/7.0/x86_64/os/Packages/kernel-devel-3.10.0-123.el7.x86_64.rpm
        sudo yum -y --nogpgcheck localinstall kernel-devel-3.10.0-123.el7.x86_64.rpm

        # installing open-jdk 7
        wget ftp://fr2.rpmfind.net/linux/centos/7.0.1406/updates/x86_64/Packages/java-1.7.0-openjdk-1.7.0.71-2.5.3.1.el7_0.x86_64.rpm
        sudo yum -y --nogpgcheck localinstall java-1.7.0-openjdk-1.7.0.71-2.5.3.1.el7_0.x86_64.rpm
 
    fi
    
}

function download_python_dependencies {
    echo "Downloading python dependencies"
    # api server requirements
    # sudo pip install gevent==0.13.8 geventhttpclient==1.0a thrift==0.8.0
    # sudo easy_install -U distribute
    if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
        pip_install gevent==1.0 geventhttpclient==1.0a thrift
        pip_install netifaces fabric argparse
        pip_install bottle
        pip_install uuid psutil
        pip_install netaddr bitarray 
        pip_install --upgrade redis
    fi
    pip_install -U setuptools
    pip_install amqp
    #Updating the rootwrap fetched by python-neutron
    pip_install -U oslo.rootwrap
    
    #Updating the rootwrap fetched by python-neutron
    pip_install -U oslo.rootwrap

    if [ "$INSTALL_PROFILE" = "ALL" ]; then
        pip_install pycassa stevedore xmltodict python-keystoneclient
        pip_install kazoo pyinotify
        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then    
            pip_install stevedore==1.0.0.0a1
        fi 
    fi

    pip_install --upgrade six
    pip_install cassandra-driver kafka
}

function repo_initialize {
    echo "Initializing repo"
    if [ ! -d $CONTRAIL_SRC/.repo ]; then
        git config --global --get user.name || git config --global user.name "Anonymous"
        git config --global --get user.email || git config --global user.email "anonymous@nowhere.com"
        if [ "$CONTRAIL_REPO_PROTO" == "ssh" ]; then
            if [ $CONTRAIL_BRANCH ];then
                repo init -u git@github.com:juniper/contrail-vnc -b $CONTRAIL_BRANCH
                rev_original="refs\/heads\/master"
                rev_new="refs\/heads\/"$CONTRAIL_BRANCH 
	        sed -i "s/$rev_original/$rev_new/" .repo/manifest.xml
            else
                repo init -u git@github.com:juniper/contrail-vnc
            fi    
        else
            if [ $CONTRAIL_BRANCH ];then
                repo init -u https://github.com/juniper/contrail-vnc -b $CONTRAIL_BRANCH
                rev_original="refs\/heads\/master"
                rev_new="refs\/heads\/"$CONTRAIL_BRANCH 
	        sed -i "s/$rev_original/$rev_new/" .repo/manifest.xml
            else
                repo init -u https://github.com/juniper/contrail-vnc 
            fi
            sed -i 's/fetch=".."/fetch=\"https:\/\/github.com\/juniper\/\"/' .repo/manifest.xml
        fi
    fi
}

function repo_initialize_backup {
    echo "Initializing repo"
    if [ ! -d $CONTRAIL_SRC/.repo ]; then
        git config --global --get user.name || git config --global user.name "Anonymous"
        git config --global --get user.email || git config --global user.email "anonymous@nowhere.com"
        if [ "$CONTRAIL_REPO_PROTO" == "ssh" ]; then
            if [ $CONTRAIL_BRANCH ];then
                repo init -u git@github.com:Juniper/contrail-vnc -b $CONTRAIL_BRANCH
                rev_original="refs\/heads\/master"
                rev_new="refs\/heads\/"$CONTRAIL_BRANCH 
	        sed -i "s/$rev_original/$rev_new/" .repo/manifest.xml
            else
                repo init -u git@github.com:Juniper/contrail-vnc 
            fi
        else
            if [ $CONTRAIL_BRANCH ];then
                repo init -u https://github.com/Juniper/contrail-vnc -b $CONTRAIL_BRANCH
                rev_original="refs\/heads\/master"
                rev_new="refs\/heads\/"$CONTRAIL_BRANCH 
	        sed -i "s/$rev_original/$rev_new/" .repo/manifest.xml
            else
                repo init -u https://github.com/Juniper/contrail-vnc 
            fi
            sed -i 's/fetch=".."/fetch=\"https:\/\/github.com\/Juniper\/\"/' .repo/manifest.xml
        fi
    fi
}

function download_cassandra_cpp_drivers {
    echo "Downloading cassanadra CPP drivers"
    if is_ubuntu; then
        wget http://downloads.datastax.com/cpp-driver/ubuntu/14.04/cassandra/v2.2.0/cassandra-cpp-driver_2.2.0-1_amd64.deb
        wget http://downloads.datastax.com/cpp-driver/ubuntu/14.04/cassandra/v2.2.0/cassandra-cpp-driver-dev_2.2.0-1_amd64.deb
        wget http://downloads.datastax.com/cpp-driver/ubuntu/14.04/dependencies/libuv/v1.7.5/libuv_1.7.5-1_amd64.deb
        sudo dpkg -i cassandra-cpp-driver_2.2.0-1_amd64.deb cassandra-cpp-driver-dev_2.2.0-1_amd64.deb libuv_1.7.5-1_amd64.deb
    fi
}

function download_cassandra {
    echo "Downloading cassanadra"
    if ! which cassandra > /dev/null 2>&1 ; then
        if is_ubuntu; then
            apt_get install python-software-properties
            sudo -E add-apt-repository -y ppa:nilarimogard/webupd8
            apt_get update
            apt_get install launchpad-getkeys

            # use oracle Java 7 instead of OpenJDK
            sudo -E add-apt-repository -y ppa:webupd8team/java
            apt_get update
            echo debconf shared/accepted-oracle-license-v1-1 select true | \
            sudo debconf-set-selections
            echo debconf shared/accepted-oracle-license-v1-1 seen true | \
            sudo debconf-set-selections
            yes | apt_get install oracle-java7-installer

            # See http://wiki.apache.org/cassandra/DebianPackaging
            echo "deb http://www.apache.org/dist/cassandra/debian 20x main" | \
            sudo tee /etc/apt/sources.list.d/cassandra.list
            gpg --keyserver pgp.mit.edu --recv-keys F758CE318D77295D
            gpg --export --armor F758CE318D77295D | sudo apt-key add -
            gpg --keyserver pgp.mit.edu --recv-keys 2B5C1B00
            gpg --export --armor 2B5C1B00 | sudo apt-key add -

            apt_get update
            apt_get install --force-yes cassandra

            # fix cassandra's stack size issues
            
            # test_install_cassandra_patch

            # don't start cassandra at boot.  I'll screen_it later
            sudo service cassandra stop
            sudo update-rc.d -f cassandra remove
        elif [ ! -d $CONTRAIL_SRC/third_party/apache-cassandra-2.1.2-bin ]; then
            contrail_cwd=$(pwd)
            cd $CONTRAIL_SRC/third_party
            wget http://repo1.maven.org/maven2/org/apache/cassandra/apache-cassandra/2.1.2/apache-cassandra-2.1.2-bin.tar.gz
            tar xvzf apache-cassandra-2.1.2-bin.tar.gz
            cd ${contrail_cwd}
        fi
    fi
}

function download_zookeeper {
    echo "Downloading zookeeper"
    if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
        contrail_cwd=$(pwd)
        cd $CONTRAIL_SRC/third_party
        cd zookeeper-${ZK_VER}
        cp conf/zoo_sample.cfg conf/zoo.cfg
        cd ${contrail_cwd}
    elif [ ! -d $CONTRAIL_SRC/third_party/zookeeper-${ZK_VER} ]; then
        contrail_cwd=$(pwd)
        cd $CONTRAIL_SRC/third_party
        wget http://apache.mirrors.hoobly.com/zookeeper/zookeeper-${ZK_VER}/zookeeper-${ZK_VER}.tar.gz
        tar xvzf zookeeper-${ZK_VER}.tar.gz
        cd zookeeper-${ZK_VER}
        cp conf/zoo_sample.cfg conf/zoo.cfg
        cd ${contrail_cwd}
    fi
}

function download_ncclient {
    # ncclient
    echo "Downloading ncclient"
    if ! python -c 'import ncclient' >/dev/null 2>&1; then
        contrail_cwd=$(pwd)
        cd $CONTRAIL_SRC/third_party
        pip_install ncclient-v0.3.2.tar.gz
        cd ${contrail_cwd}
    fi
}

#added this for source installation
function setup_libipfix() {
  echo "installing libipfix third_party"
  contrail_cwd=$(pwd)
  cd $THIRDPARTY_SRC
  git clone https://github.com/tubav/libipfix.git
  cd libipfix
  /bin/bash configure
  make
  sudo make install
  cd ${contrail_cwd}
}


function build_contrail() {
    
    echo_summary "-----------------------BUILD PHASE STARTED------------------------"
    validstage_atoption "build"
    [[ $? -eq 1 ]] && invalid_option_exit "build"
    C_UID=$( id -u )
    C_GUID=$( id -g )
    sudo mkdir -p /var/log/contrail
    sudo chown -R $C_UID:$root /var/log/contrail
    sudo chmod -R 664 /var/log/contrail/*
	
    #Generates and adds ssh-key to github.com account for contrail repo sync

    rm /home/$CONTRAIL_USER/.ssh/id_rsa*
    ssh-keygen -b 4096 -t rsa -f /home/$CONTRAIL_USER/.ssh/id_rsa -q -N ""
    eval "$(ssh-agent -s)"
    ssh-add /home/$CONTRAIL_USER/.ssh/id_rsa
    curl -u "nxpvcpe:8fa373c4cc8495e636ad13f0d70cb23a4f912f5f" --data "{\"title\":\"`echo $CONTRAIL_USER`_`date +%d%m%y`\",\"key\":\"`cat /home/$CONTRAIL_USER/.ssh/id_rsa.pub`\"}" https://api.github.com/user/keys
    ssh -o StrictHostKeyChecking=no -T git@github.com

    #checking whether previous execution stage of script is at started then
    #only allow to get the dependencies
    if [[ $(read_stage) == "started" ]]; then
        # dependencies
        download_dependencies 
        change_stage "started" "Dependencies"
    fi
   
 
    # basic dependencies
    if ! which repo > /dev/null 2>&1 ; then
	wget http://commondatastorage.googleapis.com/git-repo-downloads/repo
        chmod 0755 repo
	sudo mv repo /usr/bin
    fi

    source install_pip.sh
    /bin/bash install_pip.sh
        
    if [[ $(read_stage) == "Dependencies" ]]; then
        download_python_dependencies
        change_stage "Dependencies" "python-dependencies"
    fi

    sudo mkdir -p $CONTRAIL_SRC
    sudo chown $C_UID:$C_GUID $CONTRAIL_SRC

    THIRDPARTY_SRC=${THIRDPARTY_SRC:-$CONTRAIL_SRC/third_party}
    sudo mkdir -p $THIRDPARTY_SRC
    sudo chown $C_UID:$C_GUID $THIRDPARTY_SRC

    contrail_cwd=$(pwd)
    cd $CONTRAIL_SRC
    if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then    
        if [[ $(read_stage) == "python-dependencies" ]]; then
            repo_initialize
            change_stage "python-dependencies" "repo-init"
        fi
   
        if [[ $(read_stage) == "repo-init" ]]; then
            repo sync
            ret_val=$?
            [[ $ret_val -ne 0 ]] && echo "repo sync failed" && exit $ret_val
            change_stage "repo-init" "repo-sync"
        fi

        if [[ $(read_stage) == "repo-sync" ]]; then
            python third_party/fetch_packages.py
            python third_party/fetch_packages.py --file $contrail_cwd/installer.xml 
            change_stage "repo-sync" "fetch-packages"
        fi

        (cd third_party/thrift-*; touch configure.ac README ChangeLog; autoreconf --force --install)
       
        
        if is_fedora && [[ ! -d $THIRDPARTY_SRC/libipfix ]]; then
            setup_libipfix
        fi

        if [ "$INSTALL_PROFILE" = "ALL" ]; then
            if [[ $(read_stage) == "fetch-packages" ]]; then
                sudo scons $SCONS_ARGS
                ret_val=$?
                [[ $ret_val -ne 0 ]] && exit $ret_val
                change_stage "fetch-packages" "Build"
            fi
        elif [ "$INSTALL_PROFILE" = "COMPUTE" ]; then
            if [[ $(read_stage) == "fetch-packages" ]]; then
                sudo scons $SCONS_ARGS controller/src/vnsw
                sudo scons $SCONS_ARGS vrouter
                ret_val=$?
                [[ $ret_val -ne 0 ]] && exit $ret_val
                change_stage "fetch-packages" "Build"          
            fi
        else
            echo_msg "Selected profile is neither ALL nor COMPUTE"
            exit
        fi
    else	
        sudo -E add-apt-repository -y ppa:opencontrail/$LAUNCHPAD_REPO
        apt_get update
        change_stage "python-dependencies" "Build"
    fi 
	
    if [ "$INSTALL_PROFILE" = "ALL" ]; then
            download_redis
            download_node_for_npm
    fi
    echo_summary "-----------------------BUILD PHASE ENDED---------------------------"

 
}

function rabbit_setuser {
    local user="$1" pass="$2" found="" out=""
    out=$(sudo rabbitmqctl list_users) ||
        { echo "failed to list users" 1>&2; return 1; }
    found=$(echo "$out" | awk '$1 == user { print $1 }' "user=$user")
    if [ "$found" = "$user" ]; then
        sudo rabbitmqctl change_password "$user" "$pass" ||
            { echo "failed changing pass for '$user'" 1>&2; return 1; }
    else
        sudo rabbitmqctl add_user "$user" "$pass" ||
            { echo "failed changing pass for $user"; return 1; }
    fi
    sudo rabbitmqctl set_permissions "$user" ".*" ".*" ".*"
    sudo rabbitmqctl set_vm_memory_high_watermark 0.2
}

function install_contrail() {
  
    echo_summary "-----------------------INSTALL PHASE STARTED------------------------" 
    validstage_atoption "install"
    [[ $? -eq 1 ]] && invalid_option_exit "install"
    cd $CONTRAIL_SRC
    if [ "$INSTALL_PROFILE" = "ALL" ]; then
        if [[ $(read_stage) == "Build" ]] || [[ $(read_stage) == "install" ]]; then
            if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then 
                sudo scons $SCONS_ARGS --root=/ install
                ret_val=$?
                [[ $ret_val -ne 0 ]] && exit $ret_val
                cd ${contrail_cwd}

                # install contrail modules
                echo "Installing contrail modules"
                pip_install --upgrade --no-deps $(find $CONTRAIL_SRC/build/$TARGET -name "*.tar.gz" -print)
                pip_install $(find $CONTRAIL_SRC/build/$TARGET -name "*.tar.gz" -print)


                # install VIF driver
                setup_develop $CONTRAIL_SRC/openstack/nova_contrail_vif
                # install Neutron OpenContrail plugin
                setup_develop $CONTRAIL_SRC/openstack/neutron_plugin/
  
                # install neutron patch after VNC api is built and installed
                # test_install_neutron_patch

   
                # get ifmap
                #download_ifmap_irond
                cd $CONTRAIL_SRC
                sudo chown -R `whoami`:`whoami` build/
                if is_ubuntu; then
                    sudo -E make -f packages.make package-ifmap-server  
                    sudo cp $CONTRAIL_SRC/build/packages/ifmap-server/build/irond.jar $CONTRAIL_SRC/build/packages/ifmap-server  
                else
                    cd third_party
                    wget http://trust.f4.hs-hannover.de/download/iron/archive/irond-0.3.0-bin.zip
                    unzip irond-0.3.0-bin.zip
                fi
                
                # ncclient
                download_ncclient
 
                contrail_cwd=$(pwd)
    		cd $CONTRAIL_SRC
    		sed -ie "s/config\.discoveryService\.enable.*$/config\.discoveryService\.enable = false;/" contrail-web-core/config/config.global.js
    		sed -ie "s:config\.featurePkg\.webController\.path.*$:config\.featurePkg\.webController\.path = '$CONTRAIL_SRC/contrail-web-controller';:" contrail-web-core/config/config.global.js
    		cd contrail-web-core
    		make fetch-pkgs-prod
    		make dev-env REPO=webController
    		cd ${contrail_cwd}

            else
		# install contrail modules
                echo "Installing contrail modules"
                apt_get install contrail-config 
                apt_get install python-contrail 
                apt_get install contrail-utils 
                apt_get install contrail-control 
                apt_get install contrail-analytics 
                apt_get install contrail-lib 
                apt_get install python-contrail-vrouter-api 
                apt_get install contrail-vrouter-utils 
                apt_get install contrail-vrouter-source 
                apt_get install contrail-vrouter-dkms 
                apt_get install contrail-vrouter-agent 
                apt_get install neutron-plugin-contrail 
                apt_get install contrail-config-openstack
                #apt_get install neutron-plugin-contrail-agent contrail-config-openstack
                apt_get install contrail-nova-driver 
                apt_get install contrail-web-core 
                apt_get install contrail-web-controller
                apt_get install ifmap-server 
                apt_get install python-ncclient
                apt_get install contrail-dns

		#Updating the messaging installed by python-nova
                # pip_install -U oslo.messaging
                # contrail neutron plugin installs ini file as root
                sudo chown -R `whoami`:`whoami` /etc/neutron
            fi
            # get cassandra
            download_cassandra
            rabbit_setuser "$RABBIT_USER" "$RABBIT_PASSWORD"
            download_zookeeper
            change_stage "Build" "install"
            
       fi
    elif [ "$INSTALL_PROFILE" = "COMPUTE" ]; then
        if [[ $(read_stage) == "Build" ]] || [[ $(read_stage) == "install" ]]; then
            if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
                sudo scons $SCONS_ARGS --root=/ controller/src/vnsw install
                sudo scons $SCONS_ARGS --root=/ vrouter install
                sudo scons $SCONS_ARGS --root=/ openstack/nova_contrail_vif install
                ret_val=$?
                [[ $ret_val -ne 0 ]] && exit $ret_val
                cd ${contrail_cwd}

                # install contrail modules
                echo "Installing contrail modules"
                pip_install --upgrade $(find $CONTRAIL_SRC/build/$TARGET -name "*.tar.gz" -print)

                # install VIF driver
                pip_install $CONTRAIL_SRC/build/noarch/nova_contrail_vif/dist/nova_contrail_vif*.tar.gz

            else
		cd ${contrail_cwd}		
		# install contrail modules
                echo "Installing contrail modules"
                apt_get install contrail-config contrail-lib contrail-utils
                apt_get install contrail-vrouter-utils contrail-vrouter-agent 
                apt_get install contrail-vrouter-source contrail-vrouter-dkms contrail-nova-driver  
            fi

            change_stage "Build" "install"         
        fi
    else
        echo_msg "Selected profile is neither ALL nor COMPUTE"
        exit
    fi
    echo_summary "-----------------------INSTALL PHASE ENDED-------------------------"
}

function apply_patch() { 
    local patch="$1"
    local dir="$2"
    local sudo="$3"
    local patch_applied="${dir}/$(basename ${patch}).appled"

    # run patch, ignore previously applied patches, and return an
    # error if patch says "fail"
    [ -d "$dir" ] || die "No such directory $dir"
    [ -f "$patch" ] || die "No such patch file $patch"
    if [ -e "$patch_applied" ]; then
	echo "Patch $(basename $patch) was previously applied in $dir"
    else
	echo "Installing patch $(basename $patch) in $dir..."
	if $sudo patch -p0 -N -r - -d "$dir" < "$patch" 2>&1 | grep -i fail; then
	    die "Failed to apply $patch in $dir"
	else
	    sudo touch "$patch_applied"
	    true
	fi
    fi
}

function test_install_cassandra_patch() { 
    apply_patch $TOP_DIR/cassandra-env.sh.patch /etc/cassandra sudo
}

# take over physical interface
function insert_vrouter() {
    source /etc/contrail/contrail-compute.conf
    EXT_DEV=$dev
    if [ -e $VHOST_CFG ]; then
	source $VHOST_CFG
    else
	DEVICE=vhost0
        IPADDR=$(sudo ifconfig $EXT_DEV | sed -ne 's/.*inet [[addr]*]*[: ]*\([0-9.]*\).*/\1/i p')
        NETMASK=$(sudo ifconfig $EXT_DEV | sed -ne 's/.*[[net]*]*mask[: *]\([0-9.]*\).*/\1/i p')

    fi
    # don't die in small memory environments
    if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
        sudo insmod $CONTRAIL_SRC/vrouter/$kmod vr_flow_entries=2048 vr_oflow_entries=256 vr_bridge_entries=256
        if [[ $? -eq 1 ]] ; then 
            exit 1
        fi
        echo "Creating vhost interface: $DEVICE."
        VIF=$CONTRAIL_SRC/build/$TARGET/vrouter/utils/vif
    else    
        vrouter_pkg_version=$(zless /usr/share/doc/contrail-vrouter-agent/changelog.gz )
        vrouter_pkg_version=${vrouter_pkg_version#* (*}
        vrouter_pkg_version=${vrouter_pkg_version%*)*}        
        sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
        sudo insmod /var/lib/dkms/vrouter/$vrouter_pkg_version/build/$kmod vr_flow_entries=4096 vr_oflow_entries=512 vr_bridge_entries=128
        if [[ $? -eq 1 ]] ; then 
            exit 1
        fi
        echo "Creating vhost interface: $DEVICE."
        VIF=/usr/bin/vif
    fi 
    
    DEV_MAC=$(cat /sys/class/net/$dev/address)
    sudo $VIF --create $DEVICE --mac $DEV_MAC \
        || echo "Error creating interface: $DEVICE"

    echo "Adding $dev to vrouter"
    sudo $VIF --add $dev --mac $DEV_MAC --vrf 0 --vhost-phys --type physical \
	|| echo "Error adding $dev to vrouter"

    echo "Adding $DEVICE to vrouter"
    sudo $VIF --add $DEVICE --mac $DEV_MAC --vrf 0 --xconnect $dev --type vhost \
	|| echo "Error adding $DEVICE to vrouter"

    if is_ubuntu; then

	# copy eth0 interface params, routes, and dns to a new
	# interfaces file for vhost0
	(
	cat <<EOF
iface $dev inet manual

iface $DEVICE inet static
EOF
	sudo ifconfig $dev | perl -ne '
/HWaddr\s*([a-f\d:]+)/i    && print(" hwaddr $1\n");
/inet addr:\s*([\d.]+)/i && print(" address $1\n");
/Bcast:\s*([\d.]+)/i     && print(" broadcast $1\n");
/Mask:\s*([\d.]+)/i      && print(" netmask $1\n");
'
	sudo route -n | perl -ane '$F[7]=="'$dev'" && ($F[3] =~ /G/) && print(" gateway $F[1]\n")'

	perl -ne '/^nameserver ([\d.]+)/ && push(@dns, $1); 
END { @dns && print(" dns-nameservers ", join(" ", @dns), "\n") }' /etc/resolv.conf
) >/tmp/interfaces

	# bring down the old interface
	# and bring it back up with no IP address
	sudo ifdown $dev
	sudo ifconfig $dev 0 up

	# bring up vhost0
	sudo ifup -i /tmp/interfaces $DEVICE
	echo "Sleeping 10 seconds to allow link state to settle"
	sleep 10
	sudo ifup -i /tmp/interfaces $dev
    else
        sudo ifdown $dev 
        sleep 10
        sudo ifup $DEVICE         
        sleep 10
    fi
}

function test_insert_vrouter ()
{
    if lsmod | grep -q vrouter; then 
	echo "vrouter module already inserted."
    else
	insert_vrouter
	echo "vrouter kernel module inserted."
    fi
}

function pywhere() {
    module=$1
    python -c "import $module; import os; print os.path.dirname($module.__file__)"
}

function stop_contrail_services() {

    services=(supervisor-analytics supervisor-control supervisor-config supervisor-vrouter contrail-analytics-api contrail-control contrail-query-engine contrail-vrouter-agent contrail-api contrail-discovery contrail-schema contrail-webui-jobserver contrail-collector contrail-dns contrail-svc-monitor contrail-webui-webserver ifmap-server)
    for service in ${services[@]} 
    do
        sudo service $service stop
    done
}

function restart_contrail() {
    stop_contrail
    start_contrail "do not reset"
}

function start_contrail() {

    # if $1 is set do not reset the config
    if [ -z "$1" ]; then
        RESET_CONFIG="--reset_config"
    else
        RESET_CONFIG=""
    fi

    if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then 
        PROV_MS_PATH="$CONTRAIL_SRC/controller/src/config/utils"
    else
        PROV_MS_PATH="/usr/share/contrail-utils"
    fi

    mkdir -p $TOP_DIR/status/contrail/
    pid_count=`ls $TOP_DIR/status/contrail/*.pid|wc -l`
    if [[ $pid_count != 0 ]]; then
        echo "contrail is already running to restart use contrail.sh stop and contrail.sh start"
        exit 
    fi
 
    #to overwrite the PROMPT_COMMAND lines for screens
    sudo sed -i'' '27,28 s/^/#/' /etc/bashrc

    # save screen settings
    SAVED_SCREEN_NAME=$SCREEN_NAME
    SCREEN_NAME="contrail"
    screen -d -m -S $SCREEN_NAME -t shell -s /bin/bash
    sleep 1
    # Set a reasonable status bar
    if [ -z "$SCREEN_HARDSTATUS" ]; then
        SCREEN_HARDSTATUS='%{= .} %-Lw%{= .}%> %n%f %t*%{= .}%+Lw%< %-=%{g}(%{d}%H/%l%{g})'
    fi 
    screen -r $SCREEN_NAME -X hardstatus alwayslastline "$SCREEN_HARDSTATUS"
    echo_summary "-----------------------STARTING CONTRAIL---------------------------"
    # vrouter
    if is_service_enabled agent; then
        test_insert_vrouter
    fi

    if [ "$INSTALL_PROFILE" = "ALL" ]; then
        if is_ubuntu; then
            REDIS_CONF="/etc/redis/redis.conf"
            CASS_PATH="/usr/sbin/cassandra"
        else
            REDIS_CONF="/etc/redis.conf"
            CASS_PATH="$CONTRAIL_SRC/third_party/apache-cassandra-2.1.2/bin/cassandra"
        fi

        if [[ "$CONTRAIL_DEFAULT_INSTALL" == "True" ]]; then
            stop_contrail_services
        fi
        # launch ...
        redis-cli flushall
        screen_it redis "sudo redis-server $REDIS_CONF"

        screen_it cass "sudo MAX_HEAP_SIZE=$CASS_MAX_HEAP_SIZE HEAP_NEWSIZE=$CASS_HEAP_NEWSIZE $CASS_PATH -f"

        screen_it zk  "cd $CONTRAIL_SRC/third_party/zookeeper-${ZK_VER}; ./bin/zkServer.sh start"

	if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
            if is_ubuntu; then
                screen_it ifmap "cd $CONTRAIL_SRC/build/packages/ifmap-server; java -jar ./irond.jar"
            else
                screen_it ifmap "cd $CONTRAIL_SRC/third_party/irond-0.3.0-bin; java -jar ./irond.jar"
            fi
        else
            screen_it ifmap "cd /usr/share/ifmap-server; sudo java -jar ./irond.jar" 
        fi
        sleep 2

        RABBIT_OPTS="--rabbit_user ${RABBIT_USER} --rabbit_password ${RABBIT_PASSWORD} --rabbit_server ${RABBIT_IP}"

        # find the directory where vnc_cfg_api_server was installed and start vnc_cfg_api_server.py
        screen_it apiSrv "$(which contrail-api) --conf_file /etc/contrail/contrail-api.conf $RESET_CONFIG $RABBIT_OPTS"
        echo "Waiting for api-server to start..."
        if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- http://${SERVICE_HOST}:8082; do sleep 1; done"; then
            echo "api-server did not start"
            exit 1
        fi
        sleep 2

        # discovery must start after api server because latter creates cassandra CF needed by discovery
        screen_it disco "$(which contrail-discovery) --conf_file /etc/contrail/contrail-discovery.conf"
        sleep 2

        # earlier releases (2.x for example) schema didn't handle rabbit options
        echo "$CONTRAIL_BRANCH" | grep -q "^R2" || echo "$LAUNCHPAD_BRANCH" | grep -q "^r2"
        if [ $? == 0 ]; then
            screen_it schema "$(which contrail-schema) --conf_file /etc/contrail/contrail-schema.conf"
        else
            screen_it schema "$(which contrail-schema) --conf_file /etc/contrail/contrail-schema.conf $RABBIT_OPTS"
        fi
        screen_it svc-mon "$(which contrail-svc-monitor) --conf_file /etc/contrail/svc-monitor.conf"

        #source /etc/contrail/control_param.conf
        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
            screen_it control "export LD_LIBRARY_PATH=$CONTRAIL_SRC/build/lib:/usr/lib; sudo $CONTRAIL_SRC/build/$TARGET/control-node/contrail-control --conf_file /etc/contrail/contrail-control.conf ${CERT_OPTS} ${LOG_LOCAL}"
        else
            screen_it control "export LD_LIBRARY_PATH=/usr/lib; sudo /usr/bin/contrail-control --conf_file /etc/contrail/contrail-control.conf ${CERT_OPTS} ${LOG_LOCAL}"
        fi

        # collector/vizd
        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
            screen_it collector "sudo LD_LIBRARY_PATH=$CONTRAIL_SRC/build/lib:/usr/local/lib $CONTRAIL_SRC/build/$TARGET/analytics/vizd --conf_file /etc/contrail/contrail-collector.conf"
        else
            screen_it collector "sudo PATH=$PATH:/usr/bin LD_LIBRARY_PATH=/usr/lib /usr/bin/contrail-collector"
        fi
        sleep 2

        #opserver_param  
        screen_it analytics-api "$(which contrail-analytics-api) -c /etc/contrail/contrail-analytics-api.conf"
        sleep 2

        #qed_param
        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then  
            screen_it query-engine "sudo LD_LIBRARY_PATH=$CONTRAIL_SRC/build/lib $CONTRAIL_SRC/build/$TARGET/query_engine/qed"
        else
            screen_it query-engine "sudo PATH=$PATH:/usr/bin LD_LIBRARY_PATH=/usr/lib /usr/bin/contrail-query-engine"
        fi
        sleep 2

        admin_user=${CONTRAIL_ADMIN_USERNAME:-"admin"}
        admin_passwd=${ADMIN_PASSWORD:-"contrail123"}
        admin_tenant=${CONTRAIL_ADMIN_TENANT:-"admin"}

        # dns
        screen_it dns "/usr/bin/contrail-dns --conf_file /etc/contrail/dns/contrail-dns.conf"
        screen_it named "sudo /usr/bin/contrail-named -f -c /etc/contrail/dns/contrail-named.conf"

        #provision control
        python $PROV_MS_PATH/provision_control.py --api_server_ip $SERVICE_HOST --api_server_port 8082 --host_name $HOSTNAME --host_ip $CONTROL_IP --router_asn 64512 --oper add --admin_user $admin_user --admin_password $admin_passwd --admin_tenant_name $admin_tenant

        # Provision Vrouter - must be run after API server and schema transformer are up
        sleep 2
        #changed because control_param.conf is commented
        python $PROV_MS_PATH/provision_vrouter.py --host_name `hostname` --host_ip $CONTROL_IP --api_server_ip $SERVICE_HOST --oper add --admin_user $admin_user --admin_password $admin_passwd --admin_tenant_name $admin_tenant

    elif [ "$INSTALL_PROFILE" = "COMPUTE" ]; then
        admin_user=${CONTRAIL_ADMIN_USERNAME:-"admin"}
        admin_passwd=${ADMIN_PASSWORD:-"contrail123"}
        admin_tenant=${CONTRAIL_ADMIN_TENANT:-"admin"}
        #changed because control_param.conf is commented
        python $PROV_MS_PATH/provision_vrouter.py --host_name `hostname` --host_ip $COMPUTE_HOST_IP --api_server_ip $SERVICE_HOST --oper add --admin_user $admin_user --admin_password $admin_passwd --admin_tenant_name $admin_tenant
    fi

    # agent
    if [ $CONTRAIL_VGW_INTERFACE -a $CONTRAIL_VGW_PUBLIC_SUBNET -a $CONTRAIL_VGW_PUBLIC_NETWORK ]; then
        sudo sysctl -w net.ipv4.ip_forward=1
        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
            sudo $CONTRAIL_SRC/build/$TARGET/vrouter/utils/vif --create $CONTRAIL_VGW_INTERFACE --mac 00:00:5e:00:01:00
        else
            sudo /usr/bin/vif --create $CONTRAIL_VGW_INTERFACE --mac 00:01:00:5e:00:00
        fi            
        sudo ifconfig $CONTRAIL_VGW_INTERFACE up
        sudo route add -net $CONTRAIL_VGW_PUBLIC_SUBNET dev $CONTRAIL_VGW_INTERFACE
    fi
    source /etc/contrail/contrail-compute.conf
    #sudo mkdir -p $(dirname $VROUTER_LOGFILE)
    mkdir -p $TOP_DIR/bin
    
    # make a fake contrail-version when contrail isn't installed by yum
    if ! contrail-version >/dev/null 2>&1; then
	cat >$TOP_DIR/bin/contrail-version <<EOF2
#! /bin/sh
cat <<EOF
Package                                Version                 Build-ID | Repo | RPM Name
-------------------------------------- ----------------------- ----------------------------------
contrail-analytics                     1-1304082216        148                                    
openstack-dashboard.noarch             2012.1.3-1.fc17     updates                                
contrail-agent                         1-1304091654        contrail-agent-1-1304091654.x86_64     
EOF
EOF2
    fi
    chmod a+x $TOP_DIR/bin/contrail-version
    
    if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then
        cat > $TOP_DIR/bin/vnsw.hlpr <<END
#! /bin/bash
PATH=$TOP_DIR/bin:$PATH
LD_LIBRARY_PATH=$CONTRAIL_SRC/build/lib $CONTRAIL_SRC/build/$TARGET/vnsw/agent/contrail/contrail-vrouter-agent --config_file=/etc/contrail/contrail-vrouter-agent.conf --DEFAULT.log_file=/var/log/vrouter.log 
END
  
    else
        cat > $TOP_DIR/bin/vnsw.hlpr <<END
#! /bin/bash
PATH=$TOP_DIR/bin:$PATH
LD_LIBRARY_PATH=/usr/lib /usr/bin/contrail-vrouter-agent --config_file=/etc/contrail/contrail-vrouter-agent.conf --DEFAULT.log_file=/var/log/vrouter.log 
END
    fi
    chmod a+x $TOP_DIR/bin/vnsw.hlpr
    screen_it agent "sudo $TOP_DIR/bin/vnsw.hlpr"

    # set up a proxy route in contrail from 169.254.169.254:80 to
    # my metadata server at port 8775
    if [ "$INSTALL_PROFILE" = "ALL" ]; then
        python $PROV_MS_PATH/provision_linklocal.py \
            --linklocal_service_name metadata \
	    --linklocal_service_ip 169.254.169.254 \
	    --linklocal_service_port 80 \
	    --ipfabric_service_ip $Q_META_DATA_IP \
	    --ipfabric_service_port 8775 \
	    --oper add

	screen_it redis-w "sudo redis-server /etc/contrail/redis-webui.conf"

        if [[ "$CONTRAIL_DEFAULT_INSTALL" != "True" ]]; then 
            screen_it ui-jobs "cd $CONTRAIL_SRC/contrail-web-core; sudo node jobServerStart.js"
            screen_it ui-webs "cd $CONTRAIL_SRC/contrail-web-core; sudo node webServerStart.js"
        else
            sudo service contrail-webui-webserver start
            sudo service contrail-webui-jobserver start
            echo "Waiting for webui to start..."
            if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= curl -s http://${SERVICE_HOST}:8080; do sleep 1; done"; then
                echo "webui did not start"
                exit 1
            fi
        fi
    fi


    # restore saved screen settings
    SCREEN_NAME=$SAVED_SCREEN_NAME
    return
}

function configure_contrail() {
    echo_summary "-----------------------CONFIGURE PHASE STARTED----------------------"
    validstage_atoption "configure"
    [[ $? -eq 1 ]] && invalid_option_exit "configure"

    C_UID=$( id -u )
    C_GUID=$( id -g )
    sudo mkdir -p /var/log/contrail
    sudo chown -R $C_UID:root /var/log/contrail
    sudo chmod -R 664 /var/log/contrail/*

    # process gateway configuration if present
    #contrail_gw_interface=""
    # if [ $CONTRAIL_VGW_INTERFACE -a $CONTRAIL_VGW_PUBLIC_SUBNET -a $CONTRAIL_VGW_PUBLIC_NETWORK   ];    then
    #     contrail_gw_interface="--vgw_interface $CONTRAIL_VGW_INTERFACE --vgw_public_subnet $CONTRAIL_VGW_PUBLIC_SUBNET --vgw_public_network $CONTRAIL_VGW_PUBLIC_NETWORK"
    # fi

    # create config files
    # export passwords in a subshell so setup_contrail can pick them up but they won't leak later
    #(export ADMIN_PASSWORD CONTRAIL_ADMIN_USERNAME SERVICE_TOKEN CONTRAIL_ADMIN_TENANT && 
    #python $TOP_DIR/setup_contrail.py --physical_interface=$PHYSICAL_INTERFACE --cfgm_ip $SERVICE_HOST $contrail_gw_interface
    # )

    #defaults loading && setup devstack
    sudo mkdir -p /etc/contrail
    sudo mkdir -p /etc/sysconfig/network-scripts    
    sudo chown -R `whoami` /etc/contrail
    sudo find /etc/contrail -type f -exec chmod 664 {} \;
    sudo find /etc/contrail -type d -exec chmod 775 {} \;
    sudo chown -R `whoami` /etc/sysconfig/network-scripts
    sudo chmod  ug+w /etc/sysconfig/network-scripts/*
    cd $TOP_DIR  
    sh setup_devstack.sh 
    #un-comment if required after review
    #KEYSTONE_IP=${KEYSTONE_IP:-127.0.0.1}
    #CONTRAIL_ADMIN_TOKEN=${CONTRAIL_ADMIN_TOKEN:-''}
    
    #all arguments should be added with defaults  

    #all the functions in contrail_config_functions
    source contrail_config_functions

    #invoke functions to change the files
    if [ "$INSTALL_PROFILE" = "ALL" ]; then
        replace_cassandra_conf
        replace_api_server_conf
        replace_contrail_plugin_conf
        replace_contrail_schema_conf
        replace_svc_monitor_conf
        replace_discovery_conf
        replace_vnc_api_lib_conf
        replace_ContrailPlugin_conf
        replace_contrail_control_conf
        replace_contrail_collector_conf
        replace_contrail_analytics_api_conf
        replace_contrail_dns_conf
        replace_irond_basic_auth_users
    fi	        
    replace_contrail_compute_conf
    replace_contrail_vrouter_agent_conf
    write_ifcfg-vhost0
    write_default_pmac 
    write_qemu_conf
    fixup_config_files
    echo_summary "-----------------------CONFIGURE PHASE ENDED-----------------------"
}

function init_contrail() {
    :
}

function check_contrail() {
    :
}

function clean_contrail() {
    echo_summary "-----------------------CLEAN PHASE STARTED-------------------------"
    python clean.py --conf_file 
    echo_summary "-----------------------CLEAN PHASE ENDED---------------------------"

}

function stop_contrail() {
    SAVED_SCREEN_NAME=$SCREEN_NAME
    SCREEN_NAME="contrail"
    SCREEN=$(which screen)
    if [[ -n "$SCREEN" ]]; then
        SESSION=$(screen -ls | awk '/[0-9].contrail/ { print $1 }')
        if [[ -n "$SESSION" ]]; then
            screen -X -S $SESSION quit
        fi
    fi
    (cd $CONTRAIL_SRC/third_party/zookeeper-${ZK_VER}; ./bin/zkServer.sh stop)
    echo_summary "-----------------------STOPPING CONTRAIL--------------------------"
    if [ "$INSTALL_PROFILE" = "ALL" ]; then
        screen_stop redis
        screen_stop cass
        screen_stop zk
        screen_stop ifmap
        screen_stop disco
        screen_stop apiSrv
        screen_stop schema
        screen_stop svc-mon
        screen_stop control
        screen_stop collector
        screen_stop analytics-api
        screen_stop query-engine
        screen_stop named
        screen_stop dns
        screen_stop redis-w
        screen_stop ui-jobs
        screen_stop ui-webs
    fi
    screen_stop agent  
    rm $TOP_DIR/status/contrail/*.failure /dev/null 2>&1
    cmd=$(lsmod | grep vrouter)
    if [ $? == 0 ]; then
        cmd=$(sudo rmmod vrouter)
        if [ $? == 0 ]; then
            source /etc/contrail/contrail-compute.conf
            if is_ubuntu; then
                sudo ifdown  $dev
                sudo ifup    $dev
                sudo ifdown vhost0
                
            else
                sudo rm -f /etc/sysconfig/network-scripts/ifcfg-vhost0
                sudo service network restart 
            fi
        fi
    fi
    if [ $CONTRAIL_VGW_PUBLIC_SUBNET ]; then
        sudo route del -net $CONTRAIL_VGW_PUBLIC_SUBNET dev $CONTRAIL_VGW_INTERFACE
    fi
    if [ $CONTRAIL_VGW_INTERFACE ]; then
        sudo tunctl -d $CONTRAIL_VGW_INTERFACE
    fi
    # restore saved screen settings
    SCREEN_NAME=$SAVED_SCREEN_NAME
    return
}

function all_contrail() {
    if [[ $(read_stage) != "Build" ]] && [[ $(read_stage) != "install" ]]; then
        build_contrail
        install_contrail
    elif [[ $(read_stage) == "Build" ]]; then 
        install_contrail
    fi
    if [[ $(read_stage) == "install" ]]; then
        configure_contrail
       start_contrail
    fi
}

# Kill background processes on exit
trap clean EXIT
clean() {
    local r=$?
    echo "exited with status :$r"
    exit $r
}

#keyboard interrupt

trap interrupt SIGINT
interrupt() {
    local r=$?
    if [[ $(read_stage) == "python-dependencies" ]]; then
        if [[ -d $CONTRAIL_SRC/.repo ]];then
            sudo rm -r $CONTRAIL_SRC/.repo
        fi
    fi
    echo "keyboard interrupt"
    exit $r
}

#=================================
[[ $(read_stage) == "nofile" ]] && write_stage "started"
OPTION=$1
ARGS_COUNT=$#
setup_root_access
generate_env

if is_fedora && [[ "$CONTRAIL_DEFAULT_INSTALL" != "False" ]]; then
   echo_msg "only source installation of contrail in fedora is supported  exiting..."
   exit 1
fi

if [ $ARGS_COUNT -eq 0 ];
then 
    all_contrail
elif [ $ARGS_COUNT -eq 1 ] && [ "$OPTION" == "install" ] || [ "$OPTION" == "start" ] || [ "$OPTION" == "configure" ] || [ "$OPTION" == "clean" ] || [ "$OPTION" == "stop" ] || [ "$OPTION" == "build" ] || [ "$OPTION" == "restart" ];
then
    ${OPTION}_contrail
else
    echo_msg "Usage ::contrail.sh [option]"
    echo_msg "contrail.sh(Without any option executes 1.build,2.install,3.configure,4.start phases)"
    echo_msg "ex:contrail.sh install"
    echo_msg "[options]:"
    echo_msg "build"
    echo_msg "install"
    echo_msg "start"
    echo_msg "stop"
    echo_msg "configure"
    echo_msg "clean"
    echo_msg "restart"

fi
# Fin
# ===

if [[ -n "$LOGFILE" ]]; then
    exec 1>&3
    # Force all output to stdout and logs now
    exec 1> >( tee -a "${LOGFILE}" ) 2>&1
else
    # Force all output to stdout now
    exec 1>&3
fi


