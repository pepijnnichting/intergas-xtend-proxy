# Intergas Xtend Raspberry Pi Proxy

Deze map bevat een praktische bridge-opzet voor gebruik met Home Assistant:

- De Raspberry Pi verbindt via wifi met de Intergas Xtend AP.
- De Raspberry Pi is via ethernet verbonden met je thuisnetwerk.
- Home Assistant praat met de Raspberry Pi (proxy), niet direct met de Xtend.

Zo kun je in de Intergas Xtend-integratie het IP-adres van de Pi invullen.

## Bestanden

- `xtend-connect.sh`: houdt de wifi-verbinding met de Xtend AP in stand.
- `xtend-connect.service`: systemd-service voor wifi auto-reconnect.
- `xtend-proxy.sh`: HTTP reverse proxy voor de Xtend API.
- `xtend-proxy.service`: systemd-service voor de proxy.

## Vereisten op de Pi

- Raspberry Pi OS (of andere Linux met `systemd`)
- `python3`
- `NetworkManager` + `nmcli` (voor `xtend-connect.sh`)

## 1. Plaats de scripts op de Pi

Voorbeeldlocatie:

```sh
sudo mkdir -p /opt/intergas-xtend-proxy
sudo cp xtend-*.sh xtend-*.service /opt/intergas-xtend-proxy/
sudo chown -R pi:pi /opt/intergas-xtend-proxy
cd /opt/intergas-xtend-proxy
chmod +x xtend-connect.sh xtend-proxy.sh
```

## 2. Maak `.env` aan

Maak `/opt/intergas-xtend-proxy/.env`:

```dotenv
# Wifi van de Xtend AP
WIFI_SSID=Xtend_xxxxxxxxxx
WIFI_PASSWORD=je_xtend_wachtwoord

# Proxy luistert op LAN van de Pi
LISTEN_HOST=0.0.0.0
LISTEN_PORT=8080

# Xtend endpoint (standaard)
XTEND_HOST=10.20.30.1
XTEND_PORT=80
ALLOWED_PATH=/api/stats/values

# Optioneel voor connect-script
CHECK_INTERVAL=60
```

## 3. Installeer services

Kopieer unit files:

```sh
sudo cp /opt/intergas-xtend-proxy/xtend-connect.service /etc/systemd/system/
sudo cp /opt/intergas-xtend-proxy/xtend-proxy.service /etc/systemd/system/
```

Pas in beide unit files eventueel `User=` en paden aan als je een andere locatie gebruikt.

Herlaad systemd en start:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now xtend-connect.service
sudo systemctl enable --now xtend-proxy.service
```

## 4. Controle

Vind het LAN-IP van de Pi:

```sh
ip -4 addr show
```

Test vanaf je Home Assistant-machine of een andere host op je LAN:

```sh
curl "http://<PI_IP>:8080/api/stats/values?fields=0001"
```

Health endpoint:

```sh
curl "http://<PI_IP>:8080/healthz"
```

## 5. Home Assistant integratie instellen

In de Intergas Xtend-integratie:

- Host: `<PI_IP>`
- Poort: `8080` (of jouw `LISTEN_PORT`)

Daarna gaat Home Assistant via de Pi naar de Xtend.

## Logs / troubleshooting

```sh
journalctl -u xtend-connect.service -f
journalctl -u xtend-proxy.service -f
```

Als de proxy niet bereikbaar is:

- Controleer firewall op de Pi (poort 8080 open op LAN).
- Controleer of Pi wifi daadwerkelijk op Xtend SSID zit.
- Controleer of `XTEND_HOST=10.20.30.1` bereikbaar is vanaf de Pi.
