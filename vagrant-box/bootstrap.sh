#!/bin/bash -ex
ERL_TOP=/home/vagrant/.kerl/installs/current
ERL_BUILD_DIR=/home/vagrant/.kerl/installs/r160b03
ERL_VERSION=R16B03
ERL_BUILD=r160b03

# language
echo -e 'LC_ALL="en_US.UTF-8"' >> /etc/default/locale

# update
apt-get update -yq > /dev/null

# install dependencies
apt-get install wget build-essential openssl git libncurses5-dev autoconf \
    linux-headers-$(uname -r) m4 curl libssl-dev unixodbc-dev flex -y

# clean
apt-get clean
apt-get autoremove -y

# install kerl
curl -sSO https://raw.githubusercontent.com/spawngrid/kerl/master/kerl

mv kerl /usr/local/bin/
chmod 775 /usr/local/bin/kerl

# bash_completion kerl
curl -sSON https://raw.githubusercontent.com/spawngrid/kerl/master/bash_completion/kerl
mv kerl /etc/bash_completion.d/

# create file configure kerl
cat > /home/vagrant/.kerlrc <<EOF
    KERL_INSTALL_MANPAGES=yes
    KERL_CONFIGURE_OPTIONS="--enable-threads --enable-smp-support\
--enable-kernel-poll --enable-hipe --enable-shared-zlib\
--enable-dynamic-ssl-lib --with-ssl"
EOF

# install erlang
sudo -Hu vagrant /usr/local/bin/kerl build $ERL_VERSION $ERL_BUILD
sudo -Hu vagrant /usr/local/bin/kerl install $ERL_BUILD $ERL_BUILD_DIR

# link build in current
ln -s $ERL_BUILD_DIR $ERL_TOP

# install rebar
wget https://raw.githubusercontent.com/wiki/rebar/rebar/rebar && chmod 775 rebar
mv rebar /usr/local/bin

# activate erlang version
echo -e  ". /home/vagrant/.kerl/installs/current/activate" >> .bash_profile
