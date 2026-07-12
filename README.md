# Intergas Xtend Raspberry Pi Proxy

Companion project voor de Intergas Xtend Home Assistant integratie:
https://github.com/pepijnnichting/intergas-xtend

Deze map bevat een praktische bridge-opzet voor gebruik met Home Assistant:

- De Raspberry Pi verbindt via wifi met de Intergas Xtend AP.
- De Raspberry Pi is via ethernet verbonden met je thuisnetwerk.
- Home Assistant praat met de Raspberry Pi (proxy), niet direct met de Xtend.
- De wifi-link gebruikt direct `wpa_supplicant` met een vast adres op het Xtend subnet, dus geen `NetworkManager`-profielen of `nmcli` reconnect-logica.

Zo kun je in de Intergas Xtend-integratie het IP-adres van de Pi invullen.

## Bestanden

- `install.sh`: installeert alles automatisch (aanbevolen).
- `xtend-connect.sh`: houdt de wifi-verbinding met de Xtend AP in stand via `wpa_supplicant`.
- `xtend-connect.service`: systemd-service voor wifi auto-reconnect.
- `xtend-proxy.nginx.conf`: nginx reverse proxy config.

## Vereisten op de Pi

- Raspberry Pi OS (of andere Linux met `systemd`)
- sudo rechten

## Snelle installatie (aanbevolen)

Run op de Raspberry Pi in deze map:

```sh
chmod +x install.sh
sudo ./install.sh --ssid "Xtend_xxxxxxxxxx" --password "je_xtend_wachtwoord"
```

Dit script doet automatisch:

- Installeert `nginx`, `wpasupplicant` en `iw`
- Kopieert bestanden naar `/opt/intergas-xtend-proxy`
- Maakt `/opt/intergas-xtend-proxy/.env`
- Installeert `xtend-connect.service`
- Activeert nginx config en herlaadt nginx
- Start en enabled `nginx` + `xtend-connect.service`

Optionele vlaggen:

```sh
sudo ./install.sh --ssid "Xtend_xxxxxxxxxx" --password "..." --country NL --check-interval 60 --force
```

## Handmatige installatie

Als je liever handmatig doet:

Installeer de vereiste pakketten:

```sh
sudo apt update
sudo apt install -y nginx wpasupplicant iw
```

Plaats de config:

```sh
sudo cp /opt/intergas-xtend-proxy/xtend-proxy.nginx.conf /etc/nginx/sites-available/xtend-proxy
sudo ln -sf /etc/nginx/sites-available/xtend-proxy /etc/nginx/sites-enabled/xtend-proxy
sudo rm -f /etc/nginx/sites-enabled/default
```

Controleer en herstart nginx:

```sh
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

Hiermee luistert de proxy op poort `8080` en forwardt zowel de API als de webinterface naar `10.20.30.1:80`.

## 1. Plaats de bestanden op de Pi

Voorbeeldlocatie:

```sh
sudo mkdir -p /opt/intergas-xtend-proxy
sudo cp install.sh xtend-connect.sh xtend-connect.service xtend-proxy.nginx.conf /opt/intergas-xtend-proxy/
sudo chown -R pi:pi /opt/intergas-xtend-proxy
cd /opt/intergas-xtend-proxy
chmod +x install.sh xtend-connect.sh
```

## 2. Maak `.env` aan

Maak `/opt/intergas-xtend-proxy/.env`:

```dotenv
# Wifi van de Xtend AP
WIFI_SSID=Xtend_xxxxxxxxxx
WIFI_PASSWORD=je_xtend_wachtwoord

# Optioneel: forceer wifi interface (bijv. wlan0)
# WIFI_INTERFACE=wlan0

# Optioneel maar aanbevolen als de Xtend op kanaal 12/13 zit (bijv. Nederland)
# WIFI_COUNTRY=NL

# Optioneel: Xtend host (default 10.20.30.1)
# XTEND_HOST=10.20.30.1

# Vast IP van de Pi aan de Xtend-kant
# XTEND_CLIENT_IP=10.20.30.2/24

# Optioneel voor connect-script
CHECK_INTERVAL=60
```

De Pi gebruikt standaard `10.20.30.2/24` op `wlan0` zodra de verbinding met de Xtend actief is. Daarmee is geen DHCP-client of NetworkManager-profiel nodig.

## 3. Installeer alleen de wifi-service

Kopieer unit files:

```sh
sudo cp /opt/intergas-xtend-proxy/xtend-connect.service /etc/systemd/system/
```

Pas eventueel `User=` en paden aan als je een andere locatie gebruikt.

Herlaad systemd en start wifi auto-reconnect:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now xtend-connect.service
```

## 4. Controle

Vind het LAN-IP van de Pi:

```sh
ip -4 addr show
```

Test vanaf je Home Assistant-machine of een andere host op je LAN:

```sh
curl "http://<PI_IP>:8080/api/stats/values?fields=79b3"
```

Open de Xtend webinterface via de proxy:

```sh
http://<PI_IP>:8080/
```

Health endpoint:

```sh
curl "http://<PI_IP>:8080/healthz"
```

## 5. Home Assistant integratie instellen

In de Intergas Xtend-integratie:

- Host: `<PI_IP>`
- Poort: `8080`

Daarna gaat Home Assistant via de Pi naar de Xtend.

## Logs / troubleshooting

```sh
journalctl -u xtend-connect.service -f
journalctl -u nginx -f
```

Als de proxy niet bereikbaar is:

- Controleer firewall op de Pi (poort 8080 open op LAN).
- Controleer of Pi wifi daadwerkelijk op Xtend SSID zit.
- Controleer of `10.20.30.1` bereikbaar is vanaf de Pi.
- Controleer of `wpa_supplicant` aanwezig is: `wpa_cli -v`

Als je eerder de oude `NetworkManager`-variant gebruikte, kun je oude profielen veilig verwijderen of negeren. Deze nieuwe setup gebruikt ze niet meer.

Als `journalctl -u xtend-connect.service -f` blijft melden dat geen verbinding tot stand komt:

- Voeg `WIFI_COUNTRY=NL` toe aan `.env` als de Xtend op kanaal 12 of 13 uitzendt.
- Herstart daarna de service.

```sh
sudo systemctl restart xtend-connect.service
```

Controleer daarna opnieuw de logs:

```sh
journalctl -u xtend-connect.service -f
```
