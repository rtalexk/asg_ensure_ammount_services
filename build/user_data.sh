#!/bin/bash

yum update -y

# Download code
wget https://github.com/rtalexk/elb_classic/archive/master.zip
unzip master.zip
rm -f master.zip

# install Node.js
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.34.0/install.sh | bash

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

. ~/.nvm/nvm.sh
nvm install 10

which node
which nodejs

# Install code
cd elb_application-master
npm install

# Install Nginx
amazon-linux-extras install nginx1.12 -y

# Configure Nginx Proxy
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
cp ./build/nginx.conf /etc/nginx/nginx.conf
service nginx restart

# Start Nginx on server restart
chkconfig nginx on

# Run project
npm start
