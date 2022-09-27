#!/bin/bash
sudo rg 'Ban' swag/log/fail2ban/fail2ban.log
sudo docker exec -it swag fail2ban-client status
#sudo docker exec -it swag fail2ban-client status jellyfin 
sudo docker exec -it swag fail2ban-client status nginx-http-auth
sudo docker exec -it swag fail2ban-client status nginx-deny
sudo docker exec -it swag fail2ban-client status nginx-badbots
sudo docker exec -it swag fail2ban-client status nginx-botsearch
sudo docker exec -it swag fail2ban-client status nginx-unauthorized

