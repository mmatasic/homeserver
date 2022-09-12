# music playlist helpers
##alternative finder
loops through m3u playlist and finds alternatives for all of the songs. User can select if he wants to replace the song in playlist.
### usage:
```bash
python3 playlist_alternative_finder.py path/to/m3uPlaylist.m3u

```
## missing checker
loops through all the playlists and checks if any files are missing. If file is missing, user can replace it with alternative found on disk, or if only one result is found, it's automatically replaced. 

### usage:
```bash
python3 playlist_missing_chwecker.py path/to/playlists
```
## requirements:
- fdfind (sudo apt install fdfind)
- python3
