# RogueBridge

![Preview del proyecto](roguebridge.png)

<p align="center">
  <strong>Desarrollado por Glitchboi</strong><br>
  Seguridad desde México para todos
</p>

![Estado](https://img.shields.io/badge/status-En_desarollo-gree)
![License](https://img.shields.io/badge/license-GNU_AGPLv3-blue)

---

## Descripción
  

`roguebridge.sh` levanta un **Access Point WiFi** para laboratorio/pentesting y configura **NAT** para dar salida a Internet a los clientes conectados. Además, trae un modo **MitM opcional** por redirección con `iptables` hacia un proxy local (por ejemplo Burp/mitmproxy), con **logging** a archivos para troubleshooting.

Incluye:

- Creación de AP con `hostapd` (WPA2-PSK).
- DHCP + DNS local con `dnsmasq`.
- NAT + forwarding con `iptables`.
- MitM opcional (scope `web` o `all`) redirigiendo tráfico TCP al puerto de tu proxy.
- Comando `status` para ver salud, PIDs y logs.

---
## Tabla de Contenidos

- [Instalación](#-instalación)
- [Uso](#-uso)
- [Detalles](#-detalles)
- [Contribuir](#-contribuir)
- [Créditos](#-créditos)

---

## Instalación

### Prerequisitos

Requiere (mínimo): `bash`, `iproute2`, `iptables`, `hostapd`, `dnsmasq`, `nmcli` (NetworkManager), `iw`, `grep`, `sed`, `awk`.

> Nota: el script **debe ejecutarse como root** (`sudo`).
### Pasos

Descarga el repositorio desde github

```bash
git clone https://github.com/Glitchboi-sudo/RogueBridge.git
```

Dale permisos de ejecución:
```bash
chmod +x pentest_ap.sh
```

---
## Uso

```bash
sudo ./pentest_ap.sh up
sudo ./pentest_ap.sh down
sudo ./pentest_ap.sh status
```

MitM:

```bash
sudo ./pentest_ap.sh mitm on 8080 web
sudo ./pentest_ap.sh mitm off
```

---
## Detalles

Valores por defecto:
- AP: `wlan0`
- WAN: `eth0`
- IP AP: `192.168.50.1/24`
- SSID: `PENTEST_AP`
- Pass: `admin123`
- Canal: `1`
- Proxy: `8080`

Logs en `/tmp/pentest_ap/logs/`.

---

## Contribuir  

Este proyecto no solo es un repositorio: es un espacio abierto para aprender, experimentar y construir juntos. **Buscamos activamente contribuciones**, ya sea en la parte técnica o incluso en la documentación.
 
- **En software:** Desde corrección de bugs, optimización de rendimiento, hasta mejoras en la legibilidad del código o documentación; todo aporte, grande o pequeño, suma muchísimo.

No necesitas ser experto para ayudar: si crees que algo puede explicarse mejor, que el código puede ser más claro, o que hay una forma más elegante de hacer algo, **cuéntanos o abre un Pull Request**.

---
## Créditos

Creado por:
- [Erik Alcantara](https://www.linkedin.com/in/erik-alc%C3%A1ntara-covarrubias-29a97628a/)