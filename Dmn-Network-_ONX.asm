nolist

DRIVER      equ 6    ;the openMSXnet layer uses the DRIVER=6 frame of the daemon unchanged
M4BOARD     equ 0
low_buflen  equ 0
ESPDEBUG    equ 0    ;must stay 0 for openMSXnet
LNGSKIP     equ 2    ;2 = direct texts, no language pack at all (use with Dmn-Network-i18n-direct.asm)
low_sockmax equ 4    ;the bridge has 4 TCP and 4 UDP handles, must be defined BEFORE Dmn-Network.asm
low_vermaj  equ 0    ;driver version shown in the daemon info box and the driver tab
low_vermin  equ 1

org #1000

;--- output file, folder must exist
WRITE "\symnet\netd-onx.exe"
print "STEP 1 WRITE accepted"

READ "\symnet\SRC-Main\SymbOS-Constants.asm"
print "STEP 2 constants read"
READ "Dmn-Network-head.asm"
print "STEP 3 head read"

READ "Dmn-Network-libs.asm"
print "STEP 4 libs read"

READ "Dmn-Network.asm"
print "STEP 5 daemon read"
READ "Dmn-Network-ONX.asm"
print "STEP 6 openMSXnet driver read"

App_EndTrns

relocate_table
relocate_end
