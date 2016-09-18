#!/bin/sh
time=`date +'%m%d_%H:%M:%S'`
cd `dirname $0`

sudo mkdir -p /home/isucon/logs/${time}/mysql
sudo mkdir -p /home/isucon/logs/${time}/nginx
sudo mkdir -p /home/isucon/logs/${time}/unicorn

sudo mv /var/log/mysql/*.log /home/isucon/logs/${time}/mysql/
sudo mv /var/log/nginx/*.log /home/isucon/logs/${time}/nginx/
sudo mv /home/isucon/webapp/ruby/log/*.log /home/isucon/logs/${time}/unicorn/
sudo chown -R isucon:isucon /home/isucon/logs/${time}

for file in $(find /home/isucon/logs/${time}/nginx -maxdepth 1 -type f); do
	gzip $file
done

sudo systemctl restart nginx.service
sudo systemctl restart mysql.service
sudo systemctl restart isuda.ruby.service

git add .
git commit -m "${time}"
git push origin logs
