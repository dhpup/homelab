# How to Use Requestrr

Requestrr is a Discord bot that lets you request movies and TV shows directly from your Discord server. Your requests are automatically sent to Ombi, Sonarr, or Radarr for processing.

## Accessing Requestrr Web UI

You can access the Requestrr web interface at:

```
http://requestrr.homelab.local
```

Or via port forwarding:
```bash
kubectl port-forward -n requestrr svc/requestrr 4545:4545
# Then visit http://localhost:4545
```

## Discord Bot Setup

### 1. Invite the Bot to Your Discord Server

You need to generate an OAuth2 invite link using your Discord bot's credentials:

```
https://discord.com/api/oauth2/authorize?client_id=YOUR_CLIENT_ID&permissions=8&scope=bot
```

Replace `YOUR_CLIENT_ID` with the Discord Client ID you added to Bitwarden.

**Permissions breakdown:**
- `permissions=8` = Administrator (grants all permissions at once)
- `scope=bot` = Invite as a bot

### 2. Get Your Discord Channel IDs

To configure which channels Requestrr listens to, you need channel IDs:

1. Enable Developer Mode in Discord:
   - User Settings → App Settings → Advanced → Developer Mode (toggle on)

2. Right-click on a channel name and select "Copy Channel ID"
   - Save this ID for configuration

## Using Requestrr Commands

### Movie Requests

Request a movie using:
```
!request movie [Movie Title]
```

**Examples:**
```
!request movie The Matrix
!request movie Inception
!request movie Dune Part Two
```

### TV Show Requests

Request a TV show using:
```
!request show [Show Title]
```

**Examples:**
```
!request show The Office
!request show Breaking Bad
!request show Game of Thrones
```

### Seasons

Request specific seasons:
```
!request show [Show Title] [Season Number]
```

**Examples:**
```
!request show The Office 1
!request show Breaking Bad 3-5
!request show Stranger Things latest
```

## How It Works Behind the Scenes

1. **You send a request** in Discord using `!request movie Title` or `!request show Title`

2. **Requestrr bot receives it** and processes the request

3. **Request is submitted to**:
   - **Ombi** - First checks if available, handles user workflow
   - **Sonarr/Radarr** - Automatically searches for and downloads the content based on your indexers (Prowlarr)

4. **Download workflow**:
   - Prowlarr searches indexers for the content
   - Sonarr/Radarr downloads via qBittorrent (through gluetun VPN)
   - File is automatically organized to `/homelab-storage/tv/` or `/homelab-storage/movies/`

5. **Plex discovers it** and adds to your library (usually within hours)

6. **You stream it** from Plex!

## Configuration

### Web UI Settings

1. Visit `http://requestrr.homelab.local`

2. Configure:
   - **Discord Server Settings**: Select which server/channels to listen to
   - **Movie/TV Settings**: Enable/disable requests and set notification channels
   - **Connected Services**: Verify connections to Ombi, Sonarr, Radarr

### Adding/Modifying API Keys

If you need to update your API keys:

1. Go to your Bitwarden vault (https://vault.bitwarden.com)
2. Edit the `requestrr` item
3. Update the custom fields with new API keys
4. ExternalSecrets will automatically sync within 15 minutes
5. Requestrr pod will restart and pick up the new configuration

## Troubleshooting

### Bot not responding to commands

**Check if bot is connected to Discord:**
```bash
kubectl logs -n requestrr -f deploy/requestrr | grep -i discord
```

**Verify bot is in your server:**
- Go to your Discord server → Server Settings → Members
- Look for your bot name in the member list

**Check command prefix:**
- Default prefix is `!`
- Make sure you're typing `!request` not just `request`

### "No results found" errors

This usually means:
- **Movie/show doesn't exist** - Try searching on IMDb or TMDB
- **Indexer has no results** - Your Prowlarr indexers may not have that content
- **Sonarr/Radarr not responding** - Check their logs: `kubectl logs -n sonarr -f` or `kubectl logs -n radarr -f`

### Connection errors

**"Cannot connect to Ombi/Sonarr/Radarr"**
```bash
# Check if the services are running
kubectl get pods -n ombi
kubectl get pods -n sonarr
kubectl get pods -n radarr

# Check if API keys are correct
kubectl describe secret -n requestrr requestrr-discord-secrets
```

### Bot crashed or not responding

```bash
# Check pod status
kubectl get pods -n requestrr

# View recent logs
kubectl logs -n requestrr -f deploy/requestrr --tail=50

# Restart the pod
kubectl rollout restart deployment/requestrr -n requestrr
```

## Request Status Tracking

To check the status of your requests:

1. **Check Ombi**: `http://ombi.homelab.local`
   - Go to "Requests" to see pending requests

2. **Check Sonarr** (for TV shows): `http://sonarr.homelab.local`
   - Go to "Activity" → "Queue" to see downloading shows
   - Go to "Library" to see completed shows

3. **Check Radarr** (for movies): `http://radarr.homelab.local`
   - Go to "Activity" → "Queue" to see downloading movies
   - Go to "Library" to see completed movies

4. **Check Plex**: `http://localhost:32400`
   - Your newly imported content appears in "Recently Added"

## Advanced: Adding More Discord Channels

To make Requestrr listen to multiple channels:

1. Get channel IDs for each channel (see "Get Your Discord Channel IDs" above)
2. Visit `http://requestrr.homelab.local`
3. Go to Discord Settings
4. Add each channel ID to the notification/request channels

## Best Practices

1. **Test with a movie/show you know exists**: Try `!request movie The Matrix` first
2. **Check your indexers**: Make sure Prowlarr has working indexers configured
3. **Monitor downloads**: Watch Sonarr/Radarr activity to see download progress
4. **Keep API keys secure**: Never share your API keys or bot token
5. **Set expectations**: Large files can take hours to download depending on your ISP and indexer availability

## Example Full Workflow

```
User: !request movie Inception
     ↓
Requestrr: "Found 'Inception (2010)' - Sending to Radarr..."
     ↓
Radarr: Searches Prowlarr indexers for Inception
     ↓
Prowlarr: Returns top result from TorrentGalaxy
     ↓
qBittorrent: Downloads via ProtonVPN (gluetun)
     ↓
Radarr: Monitors download, verifies when complete
     ↓
Radarr: Renames and moves to /homelab-storage/movies/Inception/
     ↓
Plex: Scans library, adds to "Recently Added"
     ↓
User: Streams Inception from Plex! 🎉
```

## Need Help?

Check the logs:
```bash
# Requestrr logs
kubectl logs -n requestrr -f deploy/requestrr

# Sonarr logs
kubectl logs -n sonarr -f deploy/sonarr

# Radarr logs
kubectl logs -n radarr -f deploy/radarr

# Prowlarr logs
kubectl logs -n prowlarr -f deploy/prowlarr
```

For more info: https://github.com/darkalfx/requestrr
