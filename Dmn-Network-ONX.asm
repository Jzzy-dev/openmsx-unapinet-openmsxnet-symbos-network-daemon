;@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
;@                                                                            @
;@   SymbOS Network Daemon - hardware layer for the openMSXnet UNAPI bridge   @
;@   (antxiko/openMSXnet, openMSX extension "unapinet", I/O ports 28h/29h)    @
;@   Runs inside the DRIVER=6 frame of the daemon, it replaces                @
;@   Dmn-Network-ESP.asm and offers the same labels to the daemon.            @
;@                                                                            @
;@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
;
; In WinAPE 1.0.13 no colon may appear inside a comment, so none is used here.
;
; THE BRIDGE (from UnapiNet.cc and UnapiNetWire.hh of openMSXnet)
;   * port 29h write = append one parameter byte
;   * port 28h write = command byte, the command runs at once inside the emulator
;   * port 28h read  = status, 00 ok, 01 error, 02 result data waiting
;   * port 29h read  = next result byte
;   Every command is finished when OUT (28h) returns, there is nothing to wait for.
;   Writing a parameter while an old result is unread throws the old result away,
;   so a half read answer can never block the next command.
;   Without the extension the ports read FFh, which is never status 02, so every
;   command simply fails and the daemon reports no hardware.
;
; NO SLOT SWITCHING
;   The bridge is pure I/O. Nothing is mapped, interrupts stay on, data can be read
;   straight from the own bank. UNAPINET.COM is not needed under SymbOS, the
;   emulator device answers on the ports from power on.
;
; IP SETTINGS
;   The bridge only knows the local IP of the host. Mask 255.255.255.0, gateway x.y.z.1
;   and DNS 8.8.8.8 / 8.8.4.4 are filled in the same way UNAPINET.COM does it. DNS
;   names are resolved by the host (getaddrinfo), so these values are only shown.

onx_cmd         equ #28         ;write command, read status
onx_dat         equ #29         ;write parameter, read result
onx_stdata      equ 2           ;status, result data waiting

onx_c_ping      equ #00         ;answer ABh
onx_c_dnsq      equ #01
onx_c_dnss      equ #02
onx_c_tcpopen   equ #03
onx_c_tcpsend   equ #04
onx_c_tcprecv   equ #05
onx_c_tcpclose  equ #06
onx_c_tcpstate  equ #07
onx_c_tcpabort  equ #08
onx_c_udpopen   equ #09
onx_c_udpclose  equ #0a
onx_c_udpsend   equ #0c
onx_c_localip   equ #0d
onx_c_udprecv   equ #0f
onx_c_querycap  equ #10

onx_blen        equ 512         ;TCP bounce buffer (the bridge takes up to 4096 per call)
esp_udpmax      equ 576         ;largest datagram payload handled
esp_udpmaxl     equ #40         ;576 = #0240
esp_udpmaxh     equ #02
esp_sta_delay   equ 3


;==============================================================================
;### STATE ####################################################################
;==============================================================================

; names starting with esp_ are kept where the daemon (DRIVER=6) reads them
esp_sta_tx      db 0            ;TX and RX hold counters for the lights, the daemon
esp_sta_rx      db 0            ;counts them down, keep these two together
esp_ssidchg     db 0            ;1 = the info line of the driver tab changed

esp_conn        ds low_sockmax  ;bridge TCP handle per daemon socket, 0 = none
esp_uconn       ds low_sockmax  ;bridge UDP handle per daemon socket, 0 = none

onx_dnsst       db 0            ;0 idle, 1 pending, 2 ok, 3 failed
esp_dnsres      ds 4            ;last DNS result
onx_chkcnt      db 250          ;link check divider

onx_st          ds 12           ;TCP_STATE answer, state, avail(2), reason,
                                ;remote IP(4), remote port(2), local port(2)
onx_buf         ds onx_blen     ;bounce buffer for bank copies


;==============================================================================
;### LOW LEVEL ################################################################
;==============================================================================

;### ONXCMD -> run a bridge command, the parameters are already written
;### Input      A=command
;### Output     ZF=1 result data waiting on port 29h, ZF=0 error or no bridge
;### Destroyed  AF
onxcmd  out (onx_cmd),a
        in a,(onx_cmd)
        cp onx_stdata
        ret

;### ONXOUT -> write DE bytes from HL to the parameter port
;### ONXINP -> read  DE bytes from the result port to HL
;### Destroyed  AF,BC,DE,HL
onxout  ld a,d
        or a
        jr z,onxout1
        ld bc,onx_dat           ;B=0 means 256 bytes
        otir
        dec d
        jr onxout
onxout1 ld a,e
        or a
        ret z
        ld b,a
        ld c,onx_dat
        otir
        ret

onxinp  ld a,d
        or a
        jr z,onxinp1
        ld bc,onx_dat
        inir
        dec d
        jr onxinp
onxinp1 ld a,e
        or a
        ret z
        ld b,a
        ld c,onx_dat
        inir
        ret

;### ONXPING -> is the bridge there
;### Output     CF=0 yes, CF=1 no
onxping ld a,onx_c_ping
        call onxcmd
        scf
        ret nz
        in a,(onx_dat)
        cp #ab
        scf
        ret nz
        or a
        ret

;### ONXCL0 -> close all transient connections of one kind (handle 0)
;### Input      A=command (TCP_CLOSE or UDP_CLOSE)
onxcl0  push af
        xor a
        out (onx_dat),a
        pop af
        call onxcmd
        ret nz
        in a,(onx_dat)
        ret

;### ONXSLT -> HL=address of the esp_conn  entry of socket A
;### ONXUSL -> HL=address of the esp_uconn entry of socket A
;### Destroyed  AF (BC,DE are kept)
onxslt  ld hl,esp_conn
onxsl0  add l
        ld l,a
        adc h
        sub l
        ld h,a
        ret
onxusl  ld hl,esp_uconn
        jr onxsl0

;### ONXTXT -> copy the 0 terminated text HL to DE (terminator included)
onxtxt  ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,onxtxt
        ret


;==============================================================================
;### INIT, IP SETTINGS, POLLING ###############################################
;==============================================================================

onxtxad db "Adapter: openMSXnet UNAPI bridge",0     ;max 40 characters
onxtxnf db "Adapter: openMSXnet not found",0
onxtxfr db "openMSXnet v"
        db low_vermaj+48
        db "."
        db low_vermin+48
        db 0                                        ;max 18 characters
onxtxin db "Host network, bridge v"
onxtxiv db "?",0
onxtxno db "Bridge not answering",0

;### LOWINI -> hardware init / configuration
;### Input      A=0 init hardware, other values (MAC, IP data) are ignored
;### Output     CF=1 -> bridge not found (A=0 only)
;### Destroyed  AF,BC,DE,HL,IX,IY
lowini  or a
        jr z,lowini0
        or a
        ret
lowini0 xor a
        ld (onx_dnsst),a
        ld hl,esp_conn
        ld de,esp_conn+1
        ld bc,low_sockmax*2-1   ;esp_conn and esp_uconn
        ld (hl),a
        ldir
        ld a,255
        ld (esp_uown),a
        ld hl,onxtxfr           ;frame title of the driver tab
        ld de,statxtfre
        call onxtxt
        call onxping
        jr nc,lowini1
        ld hl,onxtxnf
        ld de,statxttxa
        call onxtxt
        ld hl,onxtxno
        call onxinf
        scf
        ret
lowini1 ld hl,onxtxad
        ld de,statxttxa
        call onxtxt
        ld a,onx_c_tcpclose     ;connections left behind by an earlier run
        call onxcl0
        ld a,onx_c_udpclose
        call onxcl0
        ld a,onx_c_querycap     ;second byte = bridge version
        call onxcmd
        jr nz,lowini2
        in a,(onx_dat)
        in a,(onx_dat)
        and 15
        add 48
        cp 58
        jr c,lowini3
        add 7
lowini3 ld (onxtxiv),a
lowini2 ld hl,onxtxin
        call onxinf
        or a
        ret

;### ONXINF -> HL=text for the info line of the driver tab
onxinf  ld de,statxttxr
        call onxtxt
        ld a,1
        ld (esp_ssidchg),a
        ret

;### ESPIPS -> local IP from the host, the rest like UNAPINET.COM
;### Output     CF=1 on failure
;### Destroyed  AF,BC,DE,HL
onxipt  db 255,255,255,0                        ;subnet mask
onxdnt  db 8,8,8,8, 8,8,4,4                     ;primary and secondary DNS
espips  ld a,onx_c_localip
        call onxcmd
        scf
        ret nz
        ld hl,net_ipaadr
        ld bc,4*256+onx_dat
        inir
        ld hl,onxipt
        ld de,net_ipaadr+4
        ld bc,4
        ldir
        ld hl,net_ipaadr        ;gateway = x.y.z.1
        ld de,net_ipaadr+8
        ld bc,3
        ldir
        ld a,1
        ld (de),a
        ld hl,onxdnt
        ld de,net_dnspri
        ld bc,8
        ldir
        or a
        ret

;### ESPPOL -> called by netpol, finishes DNS and checks the bridge now and then
;### Destroyed  AF,BC,DE,HL,IX,IY
esppol  ld a,(onx_dnsst)
        cp 1
        call z,onxdnp
        ld a,(net_status)
        inc a                   ;255 = online
        ret nz
        ld hl,onx_chkcnt
        dec (hl)
        ret nz
        ld (hl),250             ;about every 5 seconds
        call onxping
        ret nc
        ld a,1                  ;bridge gone, back to "no IP", NETIPS brings it back
        jp netini0


;==============================================================================
;### TCP ######################################################################
;==============================================================================

;### LOWTOP -> open TCP socket
;### Input      A=socket, E=0 client / 1 server, IX=param block
;###            (IX+0)=local port, (IX+2..5)=remote IP (octet order), (IX+6)=remote port
;### Output     CF=0 ok, CF=1 A=error
;### Destroyed  AF,BC,DE,HL,IX,IY
lowtop  ld c,a                  ;C=socket
        ld a,(ix+2):out (onx_dat),a     ;remote IP, network order
        ld a,(ix+3):out (onx_dat),a
        ld a,(ix+4):out (onx_dat),a
        ld a,(ix+5):out (onx_dat),a
        ld a,(ix+6):out (onx_dat),a     ;remote port, little endian
        ld a,(ix+7):out (onx_dat),a
        ld a,(ix+0):out (onx_dat),a     ;local port
        ld a,(ix+1):out (onx_dat),a
        xor a
        out (onx_dat),a                 ;timeout, not used by the bridge
        out (onx_dat),a
        ld a,e
        and 1                           ;flags bit 0 = passive
        out (onx_dat),a
        ld a,onx_c_tcpopen
        call onxcmd
        jr nz,lowtop9
        in a,(onx_dat)                  ;handle 1-4, 0 = failed
        or a
        jr z,lowtop9
        ld b,a
        ld a,c
        call onxslt
        ld (hl),b
        or a
        ret
lowtop9 ld a,neterrcon
        scf
        ret

;### ONXTSQ -> TCP_STATE of one bridge handle into onx_st
;### Input      A=handle
;### Output     CF=0 ok, CF=1 no answer
;### Destroyed  AF,BC,HL
onxtsq  out (onx_dat),a
        ld a,onx_c_tcpstate
        call onxcmd
        scf
        ret nz
        ld hl,onx_st
        ld bc,12*256+onx_dat
        inir
        or a
        ret

;### LOWTST -> TCP status of a socket
;### Input      A=socket
;### Output     A=status (+128=data received), BC=received bytes available,
;###            IX,IY=remote IP, DE=remote port
;### Destroyed  F,HL
;  Bridge states as in the UNAPI TCP/IP spec - 0 closed, 1 listen, 2 syn sent,
;  3 syn received, 4 established, 7 close wait (remote side has closed).
lowtst  call onxslt
        ld a,(hl)
        or a
        jr z,lowtstc            ;no bridge connection
        call onxtsq
        jr c,lowtstc
        ld a,(onx_st+0)
        ld b,sckstatcl
        or a:jr z,lowtst3       ;0 closed
        ld b,sckstatli
        cp 1:jr z,lowtst3       ;1 listen
        ld b,sckstatop
        cp 2:jr z,lowtst3       ;2 syn sent
        cp 3:jr z,lowtst3       ;3 syn received
        ld b,sckstates
        cp 4:jr z,lowtst3       ;4 established
        ld b,sckstatcw
        cp 7:jr z,lowtst3       ;7 close wait
        ld b,sckstatcl          ;anything else = closing
lowtst3 ld a,b
        ld bc,(onx_st+1)        ;bytes available
        ld ix,(onx_st+4)        ;remote IP
        ld iy,(onx_st+6)
        ld de,(onx_st+8)        ;remote port
        ld l,a
        ld a,b
        or c
        ld a,l
        ret z
        set 7,a                 ;data waiting
        ret
lowtstc ld a,sckstatcl
        ld bc,0
        ld ix,0
        ld iy,0
        ld de,0
        ret

;### LOWTTX -> TCP send
;### Input      A=socket, BC=length, E,HL=source (E=bank)
;### Output     BC=sent bytes, HL=remaining bytes (ZF=1 -> all sent)
;### Destroyed  AF,DE,IX,IY
lowttx  ld (lowttxs),a
        ld a,e
        ld (lowttxb),a
        ld (lowttxl),bc
        ld (lowttxa),hl
        ld bc,0
        ld (lowttxd),bc         ;sent so far
lowttx1 ld bc,(lowttxl)
        ld a,b
        or c
        jr z,lowttx8
        ld hl,onx_blen
        or a
        sbc hl,bc
        jr nc,lowttx2           ;remaining fits into one chunk
        ld bc,onx_blen
lowttx2 ld (lowttxc),bc
        ld a,(lowttxs)
        call onxslt
        ld a,(hl)
        or a
        jr z,lowttx8            ;no bridge connection
        ld (lowttxn),a
        ld a,(App_BnkNum)       ;bank copy - A=(dest*16)+src, HL=src, DE=dest
        add a:add a:add a:add a
        ld hl,lowttxb
        add (hl)
        ld hl,(lowttxa)
        ld de,onx_buf
        ld bc,(lowttxc)
        rst #20:dw jmp_bnkcop
        ld a,(lowttxn)
        out (onx_dat),a         ;handle
        ld a,(lowttxc+0)
        out (onx_dat),a         ;length, little endian
        ld a,(lowttxc+1)
        out (onx_dat),a
        ld hl,onx_buf
        ld de,(lowttxc)
        call onxout
        ld a,onx_c_tcpsend
        call onxcmd
        jr nz,lowttx8
        in a,(onx_dat)          ;0 = sent
        or a
        jr nz,lowttx8
        ld a,esp_sta_delay
        ld (esp_sta_tx),a       ;TX light
        ld bc,(lowttxc)
        ld hl,(lowttxd):add hl,bc:ld (lowttxd),hl
        ld hl,(lowttxa):add hl,bc:ld (lowttxa),hl
        ld hl,(lowttxl):or a:sbc hl,bc:ld (lowttxl),hl
        jp lowttx1
lowttx8 ld bc,(lowttxd)
        ld hl,(lowttxl)
        ld a,h
        or l
        ret
lowttxs db 0
lowttxn db 0
lowttxb db 0
lowttxl dw 0
lowttxa dw 0
lowttxd dw 0
lowttxc dw 0

;### LOWTRX -> TCP receive          LOWTSK -> TCP skip (discard)
;### Input      A=socket, BC=length, E,HL=destination (E=bank)
;### Output     BC=bytes REMAINING in the socket afterwards
;### Destroyed  AF,DE,HL,IX,IY
lowtsk  ld d,1
        jr lowtrx0
lowtrx  ld d,0
lowtrx0 ld (lowtrxm),de         ;D=mode (1=skip), E=bank
        ld (lowtrxs),a
        ld (lowtrxl),bc
        ld (lowtrxa),hl
lowtrx1 ld bc,(lowtrxl)
        ld a,b
        or c
        jp z,lowtrx9
        ld hl,onx_blen
        or a
        sbc hl,bc
        jr nc,lowtrx2
        ld bc,onx_blen
lowtrx2 ld (lowtrxc),bc         ;chunk size requested
        ld a,(lowtrxs)
        call onxslt
        ld a,(hl)
        or a
        jr z,lowtrx9
        out (onx_dat),a         ;handle
        ld a,c
        out (onx_dat),a         ;maximum length, little endian
        ld a,b
        out (onx_dat),a
        ld a,onx_c_tcprecv
        call onxcmd
        jr nz,lowtrx9
        in a,(onx_dat)          ;delivered length
        ld e,a
        in a,(onx_dat)
        ld d,a
        or e
        jr z,lowtrx9            ;nothing delivered
        ld hl,(lowtrxc)         ;never more than asked for
        or a
        sbc hl,de
        jr c,lowtrx9
        ld (lowtrxn),de
        ld hl,onx_buf
        call onxinp
        ld a,esp_sta_delay
        ld (esp_sta_rx),a       ;RX light
        ld a,(lowtrxm+1)        ;mode (1=skip)
        or a
        jr nz,lowtrx5           ;skip mode - discard, no copy
        ld a,(App_BnkNum)
        ld e,a                  ;E=own bank (source)
        ld a,(lowtrxm+0)        ;A=caller bank (destination)
        add a:add a:add a:add a
        add e                   ;A=(dest*16)+src
        ld hl,onx_buf
        ld de,(lowtrxa)
        ld bc,(lowtrxn)
        rst #20:dw jmp_bnkcop
lowtrx5 ld bc,(lowtrxn)
        ld hl,(lowtrxa):add hl,bc:ld (lowtrxa),hl
        ld hl,(lowtrxl):or a:sbc hl,bc:ld (lowtrxl),hl
        ld hl,(lowtrxc)
        or a
        sbc hl,bc
        jp z,lowtrx1            ;full chunk delivered -> maybe more
lowtrx9 ld a,(lowtrxs)          ;remaining bytes = ask the bridge
        call onxslt
        ld a,(hl)
        ld bc,0
        or a
        ret z
        call onxtsq
        ld bc,0
        ret c
        ld bc,(onx_st+1)
        ret
lowtrxm dw 0                    ;low=bank (E), high=mode (D)
lowtrxs db 0
lowtrxl dw 0
lowtrxa dw 0
lowtrxc dw 0
lowtrxn dw 0

;### LOWTCL -> close (graceful)      LOWTDC -> disconnect (abort)
;### Input      A=socket
;### Output     A=0
lowtdc  ld c,onx_c_tcpabort
        jr lowtcl0
lowtcl  ld c,onx_c_tcpclose
lowtcl0 call onxslt
        ld a,(hl)
        ld (hl),0
        or a
        ret z                   ;nothing open on the bridge
        out (onx_dat),a
        ld a,c
        call onxcmd
        jr nz,lowtcl9
        in a,(onx_dat)
lowtcl9 xor a
        ret

;### LOWTFL -> flush - the bridge sends at once
lowtfl  or a
        ret


;==============================================================================
;### UDP ######################################################################
;==============================================================================
; One datagram is held in esp_urxb until the application receives or skips it,
; one at a time for all UDP sockets, the others wait in the bridge (up to 16 per
; socket). UDP_RECV answers with an empty header when nothing is waiting, so no
; UDP_STATE call is needed.

esp_uown        db 255          ;socket that owns the datagram in esp_urxb, 255 = none
esp_urxip       ds 4            ;sender IP     \  filled in one go by the
esp_urxpo       dw 0            ;sender port    > 8 byte UDP_RECV header,
esp_urxn        dw 0            ;data length   /  keep the order
onx_usck        db 0
onx_ucn         db 0
lowutxb         db 0
lowutxa         dw 0
esp_utxl        dw 0
lowurxb         db 0
lowurxa         dw 0
esp_utxb        ds esp_udpmax
esp_urxb        ds esp_udpmax

;### LOWUOP -> open UDP socket
;### Input      A=socket, IX=parameter block, (IX+0)=local port
;### Output     CF=0 ok, CF=1 A=error
;### Destroyed  AF,BC,DE,HL,IX
lowuop  ld c,a
        ld a,(ix+0)
        out (onx_dat),a
        ld a,(ix+1)
        out (onx_dat),a
        ld a,onx_c_udpopen
        call onxcmd
        jr nz,lowuop9
        in a,(onx_dat)          ;handle 1-4, 0 = none free
        or a
        jr z,lowuop8
        ld b,a
        ld a,c
        call onxusl
        ld (hl),b
        or a
        ret
lowuop8 ld a,neterrsfr
        scf
        ret
lowuop9 ld a,neterrcon
        scf
        ret
lowuop0 equ lowuop

;### LOWUCL -> close UDP socket
;### Input      A=socket
;### Output     A=0
lowucl  ld c,a
        ld a,(esp_uown)
        cp c
        jr nz,lowucl1
        ld a,255                ;drop its waiting datagram
        ld (esp_uown),a
lowucl1 ld a,c
        call onxusl
        ld a,(hl)
        ld (hl),0
        or a
        ret z
        out (onx_dat),a
        ld a,onx_c_udpclose
        call onxcmd
        jr nz,lowucl9
        in a,(onx_dat)
lowucl9 xor a
        ret

;### LOWUTX -> send a datagram
;### Input      A=socket, HL=data, E=data bank, BC=length, IX=destination (IP 4 bytes, port 2 bytes)
;### Output     CF=0 sent, CF=1 A=error
;### Destroyed  AF,BC,DE,HL,IX,IY
lowutx  ld (onx_usck),a
        ld a,e
        ld (lowutxb),a
        ld (esp_utxl),bc
        ld (lowutxa),hl
        ld hl,esp_udpmax
        or a
        sbc hl,bc
        ld a,neterrdln          ;datagram too large
        jr c,lowutxe
        ld a,(onx_usck)
        call onxusl
        ld a,(hl)
        or a
        jr z,lowutxc            ;no bridge connection
        ld (onx_ucn),a
        ld bc,(esp_utxl)
        ld a,b
        or c
        jr z,lowutx0
        ld a,(App_BnkNum)       ;data from the caller's bank, A=(dest*16)+src
        add a:add a:add a:add a
        ld hl,lowutxb
        add (hl)
        ld hl,(lowutxa)
        ld de,esp_utxb
        rst #20:dw jmp_bnkcop
lowutx0 ld a,(onx_ucn)
        out (onx_dat),a         ;handle
        push ix
        pop hl
        ld bc,6*256+onx_dat     ;IP (network order) and port (little endian)
        otir
        ld a,(esp_utxl+0)
        out (onx_dat),a         ;length, little endian
        ld a,(esp_utxl+1)
        out (onx_dat),a
        ld hl,esp_utxb
        ld de,(esp_utxl)
        call onxout
        ld a,onx_c_udpsend
        call onxcmd
        jr nz,lowutxc
        in a,(onx_dat)          ;0 = sent
        or a
        jr nz,lowutxc
        ld a,esp_sta_delay
        ld (esp_sta_tx),a       ;TX light
        or a
        ret
lowutxc ld a,neterrcon
lowutxe scf
        ret

;### ONXURCV -> fetch the oldest datagram of bridge handle (onx_ucn) into esp_urxb
;### Output     CF=0 got one (esp_urxip, esp_urxpo, esp_urxn filled), CF=1 nothing
onxurcv ld a,(onx_ucn)
        out (onx_dat),a
        ld a,esp_udpmaxl
        out (onx_dat),a
        ld a,esp_udpmaxh
        out (onx_dat),a
        ld a,onx_c_udprecv
        call onxcmd
        scf
        ret nz
        ld hl,esp_urxip         ;IP(4), port(2), length(2)
        ld bc,8*256+onx_dat
        inir
        ld de,(esp_urxn)
        ld a,d
        or e
        scf
        ret z                   ;nothing waiting
        ld hl,esp_udpmax        ;the bridge cuts to the asked size, check anyway
        or a
        sbc hl,de
        ret c
        ld hl,esp_urxb
        call onxinp
        or a
        ret

;### LOWUST -> status of a UDP socket
;### Input      A=socket
;### Output     A=status, 3 idle, +128 datagram waiting
;###            BC=its length, IX,IY=sender IP, DE=sender port
;### Destroyed  F,HL
lowust  ld (onx_usck),a
        ld c,a
        ld a,(esp_uown)
        cp c
        jr z,lowust5            ;a datagram of this socket is waiting
        inc a
        jr nz,lowusti           ;the buffer holds the datagram of another socket
        ld a,c
        call onxusl
        ld a,(hl)
        or a
        jr z,lowusti
        ld (onx_ucn),a
        call onxurcv
        jr c,lowusti
        ld a,(onx_usck)
        ld (esp_uown),a
lowust5 ld bc,(esp_urxn)
        ld ix,(esp_urxip+0)
        ld iy,(esp_urxip+2)
        ld de,(esp_urxpo)
        ld a,131                ;idle plus data received
        ret
lowusti ld bc,0
        ld ix,0
        ld iy,0
        ld de,0
        ld a,3                  ;idle
        ret

;### LOWURX -> hand the waiting datagram over to the caller
;### Input      A=socket, BC=maximum length, E=destination bank, HL=destination
;### Destroyed  AF,BC,DE,HL
lowurx  ld a,e
        ld (lowurxb),a
        ld (lowurxa),hl
        ld hl,(esp_urxn)
        or a
        sbc hl,bc
        jr nc,lowurx1           ;the datagram is not shorter than the buffer, use BC
        ld bc,(esp_urxn)
lowurx1 ld a,b
        or c
        jr z,lowurx2
        ld a,(lowurxb)          ;A=(dest*16)+src
        add a:add a:add a:add a
        ld hl,App_BnkNum
        add (hl)
        ld hl,esp_urxb
        ld de,(lowurxa)
        rst #20:dw jmp_bnkcop
lowurx2 ld a,255
        ld (esp_uown),a         ;the buffer is free again
        ld a,esp_sta_delay
        ld (esp_sta_rx),a       ;RX light
        or a
        ret

;### LOWUSK -> throw the waiting datagram away
;### Input      A=socket
lowusk  ld hl,esp_uown
        cp (hl)
        ret nz
        ld (hl),255
        ret


;==============================================================================
;### DNS ######################################################################
;==============================================================================

;### ESPDNS -> start DNS request
;### Input      HL=domain string (0 terminated, in own bank)
;### Output     CF=1 on error
espdns  ld a,(onx_dnsst)
        cp 1
        scf
        ret z                   ;one request at a time
        ld b,0                  ;at most 255 characters
espdns1 ld a,(hl)
        out (onx_dat),a
        or a
        jr z,espdns2
        inc hl
        djnz espdns1
        xor a                   ;too long, terminate it
        out (onx_dat),a
espdns2 ld a,onx_c_dnsq
        call onxcmd
        scf
        ret nz                  ;refused (empty name or bridge busy)
        in a,(onx_dat)          ;0 = running, 1 = was an IP literal, IP follows
        cp 1
        jr z,onxdnip
        ld a,1
        ld (onx_dnsst),a
        or a
        ret

;### ONXDNP -> poll the outstanding DNS request
onxdnp  ld a,onx_c_dnss
        call onxcmd
        jr nz,onxdnp8
        in a,(onx_dat)          ;1 running, 2 done + IP, FFh failed
        cp 2
        jr z,onxdnip
        cp 1
        ret z
onxdnp8 ld a,3
        ld (onx_dnsst),a
        ret
onxdnip ld hl,esp_dnsres
        ld bc,4*256+onx_dat
        inir
        ld a,2
        ld (onx_dnsst),a
        or a
        ret

;### ESPDNR -> DNSRQR equivalent
;### Output     CF=0 -> IP in IX,IY ; CF=1 -> A=0 still in progress, >0 error
espdnr  ld a,(onx_dnsst)
        cp 1
        call z,onxdnp
        ld a,(onx_dnsst)
        cp 2
        jr z,espdnr1
        cp 3
        jr z,espdnr2
        xor a                   ;still in progress
        scf
        ret
espdnr1 xor a
        ld (onx_dnsst),a
        ld ix,(esp_dnsres+0)
        ld iy,(esp_dnsres+2)
        or a
        ret
espdnr2 xor a
        ld (onx_dnsst),a
        ld a,neterrdto
        scf
        ret
