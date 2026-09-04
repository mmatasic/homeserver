sudo docker exec -it otbr otbr-agent --version
sudo docker exec -it otbr ot-ctl state
sudo docker exec -it otbr ot-ctl dataset init new
sudo docker exec -it otbr ot-ctl dataset commit active
sudo docker exec -it otbr ot-ctl ifconfig up
sudo docker exec -it otbr ot-ctl thread start