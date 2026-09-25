# Intergas Xtend Raspberry Pi Proxy

Dit project laat een Raspberry Pi tegelijk verbinding houden met de Wi-Fi access
point van een Intergas Xtend én de Xtend bereikbaar maken vanaf je thuisnetwerk.
Home Assistant praat met de Pi op poort `8080`; de Pi proxy't vervolgens naar de
Xtend op `10.20.30.1`.

De Wi-Fi-interface wordt exclusief beheerd door `wpa_supplicant`. Gebruik voor
de Pi dus bij voorkeur ethernet voor je normale thuisnetwerkverbinding.

## Wat de installer doet

- installeert `nginx`, `wpasupplicant` en `iw`;
- schrijft de configuratie met alleen root-leesrechten naar
  `/opt/intergas-xtend-proxy/.env`;
- installeert en start de Wi-Fi-monitor als systemd-service;
- configureert nginx op poort `8080` zonder bestaande nginx-sites te verwijderen.

## Installatie

Kopieer deze repository naar de Raspberry Pi en voer uit:

```sh
sudo ./install.sh --ssid "Xtend_xxxxxxxxxx" --password "jouw_xtend_wachtwoord" --country NL
```

Bij een volgende installatie behoudt het script de huidige configuratie. Geef
alleen `--force` mee wanneer je de opgeslagen waarden bewust wilt overschrijven.

Beschikbare opties:

```text
--interface wlan0         Kies de Wi-Fi-interface expliciet
--country NL              Landcode; aanbevolen voor kanalen 12 en 13
--check-interval 60       Controle-interval in seconden (minimaal 5)
--client-ip 10.20.30.2/24 Vast adres van de Pi op het Xtend-netwerk
--force                   Overschrijf de bestaande configuratie zonder vraag
```

Het Wi-Fi-wachtwoord moet een normale WPA/WPA2-passphrase van 8–63 tekens zijn.
Gebruik geen aanhalingstekens of shell-escaping in de waarden: de installer
slaat precies de opgegeven tekst op.

## Home Assistant

Gebruik in de Intergas Xtend-integratie:

- Host: het LAN-IP-adres van de Raspberry Pi
- Poort: `8080`

Test vanaf een apparaat op je LAN:

```sh
curl http://<PI_IP>:8080/healthz
curl "http://<PI_IP>:8080/api/stats/values?fields=79b3"
```

De webinterface van de Xtend is beschikbaar op `http://<PI_IP>:8080/`.

## Configuratie en onderhoud

De configuratie staat in `/opt/intergas-xtend-proxy/.env`. Het is een eenvoudig
`KEY=value`-bestand. Ondersteunde sleutels zijn `WIFI_SSID`, `WIFI_PASSWORD`,
`WIFI_INTERFACE`, `WIFI_COUNTRY`, `CHECK_INTERVAL`, `XTEND_HOST` en
`XTEND_CLIENT_IP`. Opmerkingen beginnen met `#`; andere of dubbele sleutels
worden bewust geweigerd zodat typefouten meteen zichtbaar zijn.

Na een handmatige wijziging:

```sh
sudo systemctl restart xtend-connect.service
sudo journalctl -u xtend-connect.service -f
```

Controleer de complete status met:

```sh
sudo systemctl status xtend-connect.service nginx
```

Als de verbinding niet opkomt, controleer dan eerst of de interface bestaat
(`iw dev`), stel zo nodig `WIFI_INTERFACE=wlan0` in en controleer de landcode.
De service logt de exacte reden en probeert daarna automatisch opnieuw.
