# SymbOS Network Daemon driver for the openMSXnet UNAPI bridge

Status, v0.1 working under SymbOS in openMSX. Driver version 0.2 adds HTTPS, shown in the Driver tab as
openMSXnet v0.2. HTTPS needs an openMSX built with the TLS patch for openMSXnet (bridge version 5),
with an older openMSXnet build the driver works as before without TLS.

## Build
Same as the PicoVerse build, only the wrapper and the hardware file change.
Wrapper order, constants file, Dmn-Network-head.asm, Dmn-Network-libs.asm, Dmn-Network.asm
(the DRIVER 6 patched one, no further change), Dmn-Network-ONX.asm. Output netd-onx.exe.

| File | Purpose |
|---|---|
| Dmn-Network-_ONX.asm | wrapper, DRIVER 6, writes netd-onx.exe |
| Dmn-Network-ONX.asm | hardware layer for openMSXnet, replaces Dmn-Network-ESP.asm |

Switches in the wrapper, as for the PicoVerse build plus

| Switch | Meaning |
|---|---|
| TLSVERIFY equ 1 | 1 (default) = the server certificate is checked, 0 = encrypt only |

Both drivers can live in the same folder, each wrapper reads its own hardware file.

## Running
```
openmsx -machine Philips_NMS_8245 -ext Nextor213_IDE -ext unapinet
```
Boot SymbOS and start netd-onx.exe. UNAPINET.COM is NOT needed and should not be run before
SymbOS, the emulator device answers on the I/O ports by itself. It is only needed for Nextor
programs such as hget or telnet.

## How it works
* openMSXnet is a device inside openMSX on I/O ports 28h and 29h. Parameters go to 29h, the
  command byte to 28h, the command runs at once, 28h then reads 02 when the answer is waiting on 29h.
* No slot switching, no interrupt blocking, no waiting loops. Every call is finished when the OUT
  returns. Data moves with OTIR and INIR, TCP in chunks of 512 bytes.
* The bridge is found with its PING command (answer ABh). Without the extension the ports read FFh
  and the daemon shows "Adapter openMSXnet not found".
* At start all transient TCP and UDP handles of the bridge are closed, so a crashed earlier run
  cannot block the four handles.
* IP settings, the local IP comes from the host. Mask 255.255.255.0, gateway x.y.z.1 and DNS
  8.8.8.8 and 8.8.4.4 are filled in the way UNAPINET.COM does it. Names are resolved by the host.
* Every 5 seconds while online a PING checks the bridge, the status drops to "No IP" if it is gone.
* The Driver tab texts (frame title, adapter line, info line) are set by the driver at start, so
  the daemon and the i18n file stay the same as for the PicoVerse build. The slot and sub-slot
  boxes are still shown but have no meaning for openMSXnet.

## UDP
The bridge queues up to 16 datagrams per handle and UDP_RECV returns an empty header when nothing is
waiting, so the PicoVerse workaround (never UDP_STATE, poll every 2nd time) is not needed. The driver
asks UDP_RECV on every poll. Largest datagram 576 bytes, longer ones are cut by the bridge.

## HTTPS / TLS
Same rules as the PicoVerse driver, the TLS work is done by openMSX on the host (mbedTLS).
* A client connection to port 443, 8443, 465, 993 or 995 becomes a TLS connection (onx_tlsports),
  the program talks plain data. Server connections stay plain.
* The host name for SNI and the certificate check comes from the last four DNS answers (name and IP).
* TLSVERIFY 1 is the default here, unlike the PicoVerse build. The certificate is checked against
  the root certificates of the host computer (Windows certificate store, the system bundle on Linux
  and macOS), so nothing has to be installed. A connection by IP number without a previous name
  lookup has no host name, then only the certificate chain is checked and not the name (as the
  UNAPI spec does for a zero host name), and no SNI is sent, which some servers refuse.
* TLS only when the bridge reports version 5 or newer, the info line of the Driver tab shows
  "bridge v5, HTTPS" or "bridge v4, no TLS".
* The handshake shows as "opening", a failed one as a refused connection. openMSX writes the reason
  (and on success version and cipher) to its console output, start openmsx from a terminal to see it.
* TLS 1.2 and 1.3, no limit of one TLS connection like the ESP, all four handles can be TLS.

## Limits from openMSXnet
* 4 TCP and 4 UDP handles, no raw IP, no ICMP in this driver.
* A TCP send waits inside the emulator until the host accepts the data (max 2 seconds), the
  emulated MSX stands still that long.
* Save states do not keep connections.
* A passive (server) socket accepts one connection and then becomes that connection.

## Note for the PicoVerse driver
The UNAPI TCP/IP spec numbers CLOSE_WAIT as 7 (9 is LAST_ACK). Dmn-Network-ESP.asm maps 9 to
"close wait" in lowtst, so a connection closed by the server shows as closed instead of close wait.
This driver uses 7. Worth checking against the ESP firmware.
