# homeserver
docker-compose based home server
included services:
Heimdall - hompage dashboard
Sonarr - Tv show tracker and downloader
Radarr - Movie tracker and downloader
Jackett - Torrent indexer for Sonarr and Radarr
Transmission - Torrent client
Yacht - Docker container manager

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

