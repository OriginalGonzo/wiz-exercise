#!/bin/bash
set -e

wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
sudo apt-get update
sudo apt-get install -y mongodb-org=4.4.29 mongodb-org-server=4.4.29 mongodb-org-shell=4.4.29 mongodb-org-mongos=4.4.29 mongodb-org-tools=4.4.29

echo "mongodb-org hold" | sudo dpkg --set-selections
echo "mongodb-org-server hold" | sudo dpkg --set-selections
echo "mongodb-org-shell hold" | sudo dpkg --set-selections
echo "mongodb-org-mongos hold" | sudo dpkg --set-selections
echo "mongodb-org-tools hold" | sudo dpkg --set-selections

sudo mkdir -p /data/db
sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
sudo tee -a /etc/mongod.conf <<EOF
security:
  authorization: enabled
EOF

sudo systemctl start mongod
sudo systemctl enable mongod

sleep 5

mongosh admin --eval "
  db.createUser({
    user: 'admin',
    pwd: '${db_password}',
    roles: [ { role: 'userAdminAnyDatabase', db: 'admin' }, 'readWriteAnyDatabase' ]
  });
"

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install