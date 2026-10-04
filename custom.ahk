/*
XButton1 --> mouse back
XButton2 --> mouse forward

x --> shift
^ --> ctrl
*/


; map CAPS button to ESC
CapsLock::Escape
SetCapsLockState "AlwaysOff"

; mouse forward --> ctrl-i (import 3md/stl/etc)
#HotIf WinActive("ahk_exe bambu-studio.exe")
XButton2::^i
#HotIf

#HotIf WinActive("ahk_exe orca-slicer.exe")
XButton2::^i
#HotIf

#HotIf WinActive("ahk_exe freecad.exe")
XButton2::^o
XButton1::^e
#HotIf

#HotIf WinActive("ahk_exe inkscape.exe")
XButton2::^i
XButton1::+^e
#HotIf
