# openmsx-unapinet-openmsxnet-symbos-network-daemon
A network daemon for Symbos booting on OpenMSX with Unapinet / OpenMSXnet

<a href="https://msx.pics/image/xtAmE"><img src="https://msx.pics/images/2026/10/14/chrome_SDttw8OOsk.md.png" alt="chrome SDttw8OOsk" border="0"></a>

<a href="https://msx.pics/image/xt3Sd"><img src="https://msx.pics/images/2026/10/14/openmsx_ugEtMCID4e.md.png" alt="openmsx ugEtMCID4e" border="0"></a>

<a href="https://msx.pics/image/xtYXZ"><img src="https://msx.pics/images/2026/10/14/openmsx_zktvYtE5rj.md.png" alt="openmsx zktvYtE5rj" border="0"></a>


# SymbOS Network Daemon driver for the openMSXnet UNAPI bridge

Status, assembled and tested in a Z80 emulator against a model of the openMSXnet bridge (31 checks,
DNS, TCP client and server, UDP, link loss). Not yet run under SymbOS in openMSX. Driver version 0.1,
shown in the Driver tab as openMSXnet v0.1.

## Build
Same as the PicoVerse build, only the wrapper and the hardware file change.
Wrapper order, constants file, Dmn-Network-head.asm, Dmn-Network-libs.asm, Dmn-Network.asm
(the DRIVER 6 patched one, no further change), Dmn-Network-ONX.asm. Output netd-onx.exe.

| File | Purpose |
|---|---|
| Dmn-Network-_ONX.asm | wrapper, DRIVER 6, writes netd-onx.exe |
| Dmn-Network-ONX.asm | hardware layer for openMSXnet, replaces Dmn-Network-ESP.asm |

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

## Limits from openMSXnet
* 4 TCP and 4 UDP handles, no TLS, no raw IP, no ICMP in this driver.
* A TCP send waits inside the emulator until the host accepts the data (max 2 seconds), the
  emulated MSX stands still that long.
* Save states do not keep connections.
* A passive (server) socket accepts one connection and then becomes that connection.

## Note for the PicoVerse driver
The UNAPI TCP/IP spec numbers CLOSE_WAIT as 7 (9 is LAST_ACK). Dmn-Network-ESP.asm maps 9 to
"close wait" in lowtst, so a connection closed by the server shows as closed instead of close wait.
This driver uses 7. Worth checking against the ESP firmware.
