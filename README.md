# homeserver
docker-compose based home server
included services:
- Heimdall - hompage dashboard
- Sonarr - Tv show tracker and downloader
- Radarr - Movie tracker and downloader
- Bazzar - Subtitle auto downloader
- Jackett - Torrent indexer for Sonarr and Radarr
- Jellyfin - Movie and Tv show server
- Lidarr - Music tracker and downloader
- Deemix - Deezer downloader (Lidar download client, and indexer)
- Navidrome - Music server 
- Transmission - Torrent client
- Yacht - Docker container manager
- Swag - Reverse proxy and ssl cert manager
- Duckdns - public ip auto-update 
- Homeassistant - home automation
- Beets - music library management tool

## General docker-compose command reminder

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose stop

# Remove all services container
docker-compose down

# Check logs
docker-compose logs -f

# Rebuild and pull docker images
docker-compose build --pull --no-cache && docker-compose pull
```

