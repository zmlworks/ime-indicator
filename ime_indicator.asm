; =============================================================================
;  ImeIndicator v1.1  -  テキストカーソル（キャレット）の横に IME の入力モードを表示する常駐アプリ
;  ImeIndicator v1.1  -  shows the IME (Japanese input) mode next to the text caret
;
;  Target   : Windows 10/11 x64 (any x64 CPU; nothing AMD/Intel specific)
;  Language : x64 assembly, NASM syntax, pure Win32 API, no C runtime
;  Build    : see build.sh  (nasm -f win64 + x86_64-w64-mingw32-ld)
;
;  ---------------------------------------------------------------------------
;  Overview
;  ---------------------------------------------------------------------------
;  * One small top-most, layered, click-through popup window ("indicator")
;    is placed just below-right of the TEXT CARET of the focused app
;    (caret.left+2, caret.bottom+4 px @96 DPI, DPI-scaled; flipped above the
;    caret near the bottom of the monitor work area).  When no caret can be
;    found the indicator is hidden (it never falls back to the mouse cursor).
;  * A second, never-shown window ("tray window") owns the notification-area
;    icon and its right-click menu (「終了」).  It is a normal (activatable)
;    top-level window, which TrackPopupMenu needs to dismiss correctly; the
;    indicator itself is WS_EX_NOACTIVATE and must never take focus.
;  * Timer 1 (CARET_INTERVAL ms): locate the caret of the foreground thread:
;        a) GetGUIThreadInfo.hwndCaret/rcCaret + ClientToScreen (Win32 caret)
;        b) else MSAA: AccessibleObjectFromWindow(focus, OBJID_CARET,
;           IID_IAccessible) -> IAccessible::accLocation(CHILDID_SELF)
;        a) runs with the thread DPI context temporarily switched to the
;        target window's context, and the result is converted to physical
;        pixels with LogicalToPhysicalPointForPerMonitorDPI, so DPI-unaware /
;        system-aware apps on scaled monitors are handled correctly.
;        b) runs in our own per-monitor-v2 context (screen coordinates).
;        (UI Automation TextPattern is deliberately NOT used: large COM
;        surface, slow cross-process calls, more risk than benefit here.)
;  * Timer 2 (IME_INTERVAL ms)  : query IME state of the foreground app:
;        GetForegroundWindow -> GetGUIThreadInfo (focus window, fallback to
;        active / foreground) -> ImmGetDefaultIMEWnd ->
;        SendMessageTimeoutW(WM_IME_CONTROL, IMC_GETOPENSTATUS / 
;        IMC_GETCONVERSIONMODE, SMTO_ABORTIFHUNG, short timeout)
;    The window is only repainted when the state changes and only moved when
;    the position changes, so idle CPU usage is negligible.
;  * No hooks of any kind, no keyboard access, no network, no admin rights.
;  * COM (for MSAA) runs in an STA with a tiny message filter that cancels any
;    outgoing cross-process call taking longer than COM_CALL_TIMEOUT ms, and
;    MSAA is skipped for hung windows, so a busy target app cannot freeze us.
;
;  ---------------------------------------------------------------------------
;  Win64 calling convention notes (applies to every function below)
;  ---------------------------------------------------------------------------
;  * Args: RCX, RDX, R8, R9, then stack at [RSP+20h], [RSP+28h], ... at the
;    moment of the CALL; callee may use 32 bytes of "shadow space" at
;    [RSP+0..1Fh].  RSP must be 16-byte aligned at the CALL instruction.
;  * Volatile  : RAX RCX RDX R8 R9 R10 R11 (and XMM0-5)
;    Nonvolatile: RBX RBP RDI RSI R12 R13 R14 R15 (and XMM6-15)
;  * Every non-leaf function uses the FUNC_BEGIN / FUNC_RET / FUNC_END macros:
;        push rbx,rsi,rdi,rbp,r12,r13,r14,r15   (8 pushes = 64 bytes)
;        sub  rsp, FRAME                         (FRAME == 8 mod 16)
;    On entry RSP == 8 (mod 16) (return address), after 8 pushes still
;    8 (mod 16), after "sub rsp, FRAME" it is 0 (mod 16) -> aligned for calls.
;    Layout inside the frame:
;        [rsp+00h..1Fh]  shadow space for callees
;        [rsp+20h..   ]  outgoing stack arguments (5th, 6th, ...)
;        [rsp+LOCALS..]  this function's locals (offsets documented per func)
;  * The macros also emit proper .pdata/.xdata (x64 unwind info) for every
;    framed function, so the OS can unwind through our frames (crash dumps,
;    debuggers, stack walks).  Leaf functions that touch neither RSP nor
;    nonvolatile registers need no unwind info.
; =============================================================================

bits 64
default rel

; -----------------------------------------------------------------------------
;  Tunables
; -----------------------------------------------------------------------------
BASE_SIZE       equ 26          ; indicator box size (px @ 96 DPI)
FONT_PX         equ 18          ; character height  (px @ 96 DPI)
CARET_DX        equ 2           ; box x = caret.left   + CARET_DX (px @ 96 DPI)
CARET_DY        equ 4           ; box y = caret.bottom + CARET_DY (or above caret)
RADIUS          equ 8           ; rounded-corner ellipse size (px @ 96 DPI)
ALPHA           equ 230         ; window opacity 0..255
CARET_INTERVAL  equ 50          ; ms, caret polling timer
COM_CALL_TIMEOUT equ 300        ; ms, cancel slow cross-process MSAA calls
IME_INTERVAL    equ 100         ; ms, IME polling timer
IME_TIMEOUT     equ 50          ; ms, SendMessageTimeout timeout per query
HOUSEKEEP_TICKS equ 10          ; every N IME ticks: re-assert topmost, retry tray

; -----------------------------------------------------------------------------
;  Win32 constants
; -----------------------------------------------------------------------------
WM_NULL             equ 0000h
WM_CLOSE            equ 0010h
WM_PAINT            equ 000Fh
WM_ERASEBKGND       equ 0014h
WM_ENDSESSION       equ 0016h
WM_MOUSEACTIVATE    equ 0021h
WM_CONTEXTMENU      equ 007Bh
WM_DISPLAYCHANGE    equ 007Eh
WM_NCHITTEST        equ 0084h
WM_COMMAND          equ 0111h
WM_TIMER            equ 0113h
WM_RBUTTONUP        equ 0205h
WM_IME_CONTROL      equ 0283h
WM_DPICHANGED       equ 02E0h
WM_APP              equ 8000h
WM_TRAY             equ WM_APP + 1

IMC_GETCONVERSIONMODE equ 1
IMC_GETOPENSTATUS     equ 5
IME_CMODE_NATIVE      equ 1     ; (= IME_CMODE_JAPANESE)
IME_CMODE_KATAKANA    equ 2
IME_CMODE_FULLSHAPE   equ 8

SMTO_ABORTIFHUNG    equ 2
HTTRANSPARENT       equ -1
MA_NOACTIVATE       equ 3

WS_POPUP            equ 80000000h
WS_CAPTION          equ 00C00000h
WS_EX_TOPMOST       equ 00000008h
WS_EX_TRANSPARENT   equ 00000020h
WS_EX_TOOLWINDOW    equ 00000080h
WS_EX_LAYERED       equ 00080000h
WS_EX_NOACTIVATE    equ 08000000h
GWL_STYLE           equ -16
LWA_ALPHA           equ 2

SWP_NOSIZE          equ 0001h
SWP_NOMOVE          equ 0002h
SWP_NOZORDER        equ 0004h
SWP_NOACTIVATE      equ 0010h
SWP_SHOWWINDOW      equ 0040h
SWP_NOOWNERZORDER   equ 0200h
HWND_TOPMOST        equ -1
SW_HIDE             equ 0

OBJID_CARET         equ 0FFFFFFF8h
VT_I4               equ 3
CHILDID_SELF        equ 0
IUNK_Release        equ 2 * 8       ; vtable offsets (IUnknown: 0..2,
IACC_accLocation    equ 22 * 8      ;  IDispatch: 3..6, IAccessible: 7..)
COINIT_APARTMENTTHREADED equ 2
COINIT_DISABLE_OLE1DDE   equ 4
E_NOINTERFACE       equ 80004002h
PENDINGMSG_CANCELCALL     equ 0
PENDINGMSG_WAITDEFPROCESS equ 2
MONITOR_DEFAULTTONULL    equ 0
MONITOR_DEFAULTTONEAREST equ 2
MDT_EFFECTIVE_DPI   equ 0

NIM_ADD             equ 0
NIM_MODIFY          equ 1
NIM_DELETE          equ 2
NIF_MESSAGE         equ 1
NIF_ICON            equ 2
NIF_TIP             equ 4

MF_STRING           equ 0000h
MF_GRAYED           equ 0001h
MF_SEPARATOR        equ 0800h
TPM_RIGHTBUTTON     equ 0002h
TPM_RIGHTALIGN      equ 0008h
TPM_BOTTOMALIGN     equ 0020h
TPM_NONOTIFY        equ 0080h
TPM_RETURNCMD       equ 0100h

DT_CENTER           equ 0001h
DT_VCENTER          equ 0004h
DT_SINGLELINE       equ 0020h
DT_NOPREFIX         equ 0800h
TRANSPARENT_BK      equ 1       ; SetBkMode(TRANSPARENT)
PS_SOLID            equ 0
LOGPIXELSX          equ 88
DEFAULT_CHARSET     equ 1
SHIFTJIS_CHARSET    equ 128
ANTIALIASED_QUALITY equ 4
VARIABLE_PITCH_SWISS equ 22h    ; VARIABLE_PITCH | FF_SWISS
FW_BOLD             equ 700

IMAGE_ICON          equ 1
SM_CXSMICON         equ 49
SM_CYSMICON         equ 50
IDI_APPLICATION     equ 32512
IDC_ARROW           equ 32512
MB_ICONINFORMATION  equ 40h
ERROR_ACCESS_DENIED   equ 5
ERROR_ALREADY_EXISTS  equ 183
LOAD_LIBRARY_SEARCH_SYSTEM32 equ 800h
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE    equ -3
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 equ -4

TIMER_CARET         equ 1
TIMER_IME           equ 2
ID_EXIT             equ 1001
TRAY_UID            equ 1

; indicator states (index into state_table)
ST_OFF      equ 0       ; 「A」  IME off / half-width alphanumeric
ST_HIRA     equ 1       ; 「あ」 hiragana
ST_KATA     equ 2       ; 「カ」 full-width katakana
ST_HKATA    equ 3       ; 「ｱ」  half-width katakana
ST_FALNUM   equ 4       ; 「Ａ」 full-width alphanumeric (IME on)
ST_UNKNOWN  equ 5       ; 「?」  could not query (e.g. elevated app)
ST_COUNT    equ 6
STATE_ENTRY equ 12      ; dw char, dw 0, dd bg COLORREF, dd border COLORREF

; -----------------------------------------------------------------------------
;  Structure sizes / offsets (x64)
; -----------------------------------------------------------------------------
; VARIANT        (24): vt 0 (WORD), wReserved1..3 2..7, lVal / union 8
; MONITORINFO    (40): cbSize 0, rcMonitor 4 (L4 T8 R12 B16), rcWork 20, dwFlags 36
; GUITHREADINFO  (72): cbSize 0, flags 4, hwndActive 8, hwndFocus 16,
;                      hwndCapture 24, hwndMenuOwner 32, hwndMoveSize 40,
;                      hwndCaret 48, rcCaret 56
; NOTIFYICONDATAW(976): cbSize 0, hWnd 8, uID 16, uFlags 20,
;                      uCallbackMessage 24, hIcon 32, szTip[128] 40,
;                      dwState 296, dwStateMask 300, szInfo[256] 304,
;                      uTimeout 816, szInfoTitle[64] 820, dwInfoFlags 948,
;                      guidItem 952, hBalloonIcon 968
; WNDCLASSEXW    (80): cbSize 0, style 4, lpfnWndProc 8, cbClsExtra 16,
;                      cbWndExtra 20, hInstance 24, hIcon 32, hCursor 40,
;                      hbrBackground 48, lpszMenuName 56, lpszClassName 64,
;                      hIconSm 72
; MSG            (48): hwnd 0, message 8, wParam 16, lParam 24, time 32, pt 36
; PAINTSTRUCT    (72): hdc 0, fErase 8, rcPaint 12, ... (72 bytes total)
; LOGFONTW       (92): lfHeight 0, lfWidth 4, lfEscapement 8, lfOrientation 12,
;                      lfWeight 16, lfItalic 20, lfUnderline 21, lfStrikeOut 22,
;                      lfCharSet 23, lfOutPrecision 24, lfClipPrecision 25,
;                      lfQuality 26, lfPitchAndFamily 27, lfFaceName[32] 28
; RECT           (16): left 0, top 4, right 8, bottom 12
NID_SIZE        equ 976
GTI_SIZE        equ 72
LOGFONT_SIZE    equ 92
LF_FACE         equ 28

; -----------------------------------------------------------------------------
;  Imports.  "call Foo" becomes "call [rel __imp_Foo]" (IAT slot from the
;  mingw-w64 import libraries).
; -----------------------------------------------------------------------------
%macro IMPORT 1-*
  %rep %0
    extern __imp_%1
    %define %1 [rel __imp_%1]
    %rotate 1
  %endrep
%endmacro

; kernel32
IMPORT GetModuleHandleW, GetProcAddress, LoadLibraryExW, CreateMutexW, \
       GetLastError, CloseHandle, ExitProcess, MulDiv, lstrcmpiW
; user32
IMPORT MessageBoxW, SetProcessDPIAware, GetDC, ReleaseDC, LoadIconW, \
       LoadImageW, LoadCursorW, GetSystemMetrics, RegisterClassExW, \
       CreateWindowExW, DestroyWindow, SetLayeredWindowAttributes, \
       RegisterWindowMessageW, SetTimer, KillTimer, GetMessageW, \
       DispatchMessageW, DefWindowProcW, PostQuitMessage, PostMessageW, \
       GetCursorPos, MonitorFromPoint, MonitorFromWindow, \
       ClientToScreen, IsHungAppWindow, \
       GetMonitorInfoW, SetWindowPos, ShowWindow, SetWindowRgn, \
       InvalidateRect, GetForegroundWindow, GetWindowThreadProcessId, \
       GetGUIThreadInfo, SendMessageTimeoutW, GetShellWindow, \
       GetDesktopWindow, GetClassNameW, GetWindowRect, GetWindowLongPtrW, \
       CreatePopupMenu, AppendMenuW, TrackPopupMenu, DestroyMenu, \
       SetForegroundWindow, BeginPaint, EndPaint, GetClientRect, DrawTextW
; gdi32
IMPORT GetDeviceCaps, CreateFontIndirectW, EnumFontFamiliesExW, DeleteObject, \
       CreateRoundRectRgn, CreateSolidBrush, CreatePen, SelectObject, \
       RoundRect, SetBkMode, SetTextColor
; imm32
IMPORT ImmGetDefaultIMEWnd
; shell32
IMPORT Shell_NotifyIconW
; ole32 / oleacc (MSAA caret)
IMPORT CoInitializeEx, CoUninitialize, CoRegisterMessageFilter
IMPORT AccessibleObjectFromWindow

; -----------------------------------------------------------------------------
;  Function frame macros (see header comment).  They also generate the x64
;  unwind data:
;    UNWIND_INFO: Version=1, Flags=0, SizeOfProlog=19, CountOfCodes=10,
;                 FrameRegister=0
;    codes (reverse prologue order, "offset" = end of the instruction):
;      19: UWOP_ALLOC_LARGE(info 0), next slot = FRAME/8
;      12: PUSH r15   10: PUSH r14   8: PUSH r13   6: PUSH r12
;       4: PUSH rbp    3: PUSH rdi   2: PUSH rsi   1: PUSH rbx
;  The prologue byte layout is fixed: 4 one-byte pushes, 4 two-byte (REX)
;  pushes, and a 7-byte "sub rsp, imm32" (48 81 EC imm32, emitted as raw
;  bytes so NASM cannot pick the shorter imm8 form).
; -----------------------------------------------------------------------------
%macro FUNC_BEGIN 2             ; name, frame size (must be 8 mod 16, >= 40)
  %if ((%2) % 16) != 8
    %error "FUNC_BEGIN: frame size must be 8 mod 16"
  %endif
  %push funcctx
  %define %$frame %2
  %define %$name  %1
%1:
    push    rbx
    push    rsi
    push    rdi
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    db      48h, 81h, 0ECh          ; sub rsp, imm32  (always the 7-byte
    dd      %2                      ;  form so SizeOfProlog is constant)
  [section .xdata]
  align 4
%$xdata:
    db  1, 19, 10, 0            ; ver/flags, prolog size, code count, frame reg
    db  19, 01h                 ; UWOP_ALLOC_LARGE, OpInfo 0
    dw  (%2) / 8
    db  12, 0F0h, 10, 0E0h, 8, 0D0h, 6, 0C0h
    db  4, 050h, 3, 070h, 2, 060h, 1, 030h
  __SECT__
%endmacro

%macro FUNC_RET 0               ; canonical epilogue (RAX preserved)
    db      48h, 81h, 0C4h          ; add rsp, imm32
    dd      %$frame
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rdi
    pop     rsi
    pop     rbx
    ret
%endmacro

%macro FUNC_END 0               ; closes the function, emits RUNTIME_FUNCTION
%$end:
  [section .pdata]
    dd  %$name wrt ..imagebase
    dd  %$end  wrt ..imagebase
    dd  %$xdata wrt ..imagebase
  __SECT__
  %pop
%endmacro

; =============================================================================
section .pdata  rdata align=4
section .xdata  rdata align=8

; =============================================================================
section .rdata  rdata align=8
; -----------------------------------------------------------------------------
szClass         dw __utf16__("ImeIndicatorWnd"), 0
szIndTitle      dw __utf16__("ImeIndicator"), 0
szTrayTitle     dw __utf16__("ImeIndicatorTray"), 0
szAppTitle      dw __utf16__("IME インジケーター"), 0
szMutex         dw __utf16__("Local\ImeIndicator-5C1E7A3B-SingleInstance"), 0
szAlready       dw __utf16__("IME インジケーターは既に起動しています。"), 0
szTaskbarCreated dw __utf16__("TaskbarCreated"), 0
szMenuTitle     dw __utf16__("IME インジケーター v1.1"), 0
szExit          dw __utf16__("終了"), 0
szTip           dw __utf16__("IME インジケーター（右クリックで終了）"), 0
szTip_chars     equ ($ - szTip) / 2         ; incl. terminating NUL (< 128)
szUser32        dw __utf16__("user32.dll"), 0
szShcore        dw __utf16__("shcore.dll"), 0
szSetProcessDpiAwarenessContext db "SetProcessDpiAwarenessContext", 0
szGetDpiForMonitor              db "GetDpiForMonitor", 0
szSetThreadDpiAwarenessContext  db "SetThreadDpiAwarenessContext", 0
szGetWindowDpiAwarenessContext  db "GetWindowDpiAwarenessContext", 0
szLogicalToPhysicalPointForPerMonitorDPI db "LogicalToPhysicalPointForPerMonitorDPI", 0

; GUIDs (Data1 dd, Data2 dw, Data3 dw, Data4 8 bytes)
align 8
IID_IAccessible:        ; {618736E0-3C3D-11CF-810C-00AA00389B71}
    dd 618736E0h
    dw 3C3Dh, 11CFh
    db 81h, 0Ch, 00h, 0AAh, 00h, 38h, 9Bh, 71h
IID_IUnknown:           ; {00000000-0000-0000-C000-000000000046}
    dd 0
    dw 0, 0
    db 0C0h, 0, 0, 0, 0, 0, 0, 46h
IID_IMessageFilter:     ; {00000016-0000-0000-C000-000000000046}
    dd 16h
    dw 0, 0
    db 0C0h, 0, 0, 0, 0, 0, 0, 46h

; IMessageFilter vtable (static COM object, see msgfilter_* below).  These
; absolute pointers are fixed up through .reloc when the image is rebased.
msgfilter_vtbl:
    dq msgfilter_QueryInterface
    dq msgfilter_AddRef
    dq msgfilter_Release
    dq msgfilter_HandleInComingCall
    dq msgfilter_RetryRejectedCall
    dq msgfilter_MessagePending

%if szTip_chars > 128
  %error "tooltip too long"
%endif

; Font candidates, 32 WCHARs each (= LOGFONTW.lfFaceName).  The first one
; that exists is used; the last (empty) entry lets the font mapper pick any
; Japanese (SHIFTJIS_CHARSET) font.
%macro WSTR32 1                 ; WCHAR[32], zero padded
  %%s: dw __utf16__(%1)
  times 32 - ($ - %%s) / 2 dw 0
%endmacro
%define FACE WSTR32
align 2
face_table:
    FACE "Yu Gothic UI"
    FACE "Meiryo UI"
    FACE "Meiryo"
    FACE "MS UI Gothic"
    times 32 dw 0
FACE_COUNT equ ($ - face_table) / 64

; Window classes of the shell (desktop / taskbar): the indicator is hidden
; while one of these is the foreground window.  Empty entry terminates.
shell_class_table:
    WSTR32 "Progman"
    WSTR32 "WorkerW"
    WSTR32 "Shell_TrayWnd"
    WSTR32 "Shell_SecondaryTrayWnd"
    times 32 dw 0

; State table: character, background colour, border colour (COLORREF 0x00BBGGRR)
align 4
state_table:
    dw 0041h, 0             ; ST_OFF    「A」 slate blue-gray  #5A6B7D
    dd 007D6B5Ah, 0052463Ah
    dw 3042h, 0             ; ST_HIRA   「あ」 orange-red      #E2461F
    dd 001F46E2h, 00102EA0h
    dw 30ABh, 0             ; ST_KATA   「カ」 magenta         #B0308A
    dd 008A30B0h, 005E1A78h
    dw 0FF71h, 0            ; ST_HKATA  「ｱ」  violet          #7A3DC8
    dd 00C83D7Ah, 0086234Eh
    dw 0FF21h, 0            ; ST_FALNUM 「Ａ」 teal            #12857A
    dd 007A8512h, 00525A0Bh
    dw 003Fh, 0             ; ST_UNKNOWN「?」  dark gray       #444444
    dd 00444444h, 00222222h
%if ($ - state_table) != ST_COUNT * STATE_ENTRY
  %error "state_table size mismatch"
%endif

; =============================================================================
section .data   data align=8
; -----------------------------------------------------------------------------
g_state         dd -1               ; current ST_* (-1 = not yet known)
g_lastx         dd 80000000h
g_lasty         dd 80000000h
; The static IMessageFilter object: just a pointer to its vtable.
; (Together with msgfilter_vtbl these are the image's only absolute
; addresses; they give the image a real .reloc section, which GNU ld would
; otherwise omit -> RELOCS_STRIPPED -> no ASLR.  verify_pe.py checks this.)
align 8
g_msgfilter     dq msgfilter_vtbl

; =============================================================================
section .bss    bss align=16
; -----------------------------------------------------------------------------
g_hInst         resq 1
g_hMutex        resq 1
g_hwndInd       resq 1              ; indicator window
g_hwndTray      resq 1              ; hidden tray-owner window
g_hFont         resq 1
g_hIcon         resq 1
g_hIconSm       resq 1
g_pGetDpiForMonitor resq 1          ; shcore!GetDpiForMonitor or 0
g_fs_monitor    resq 1              ; monitor covered by a fullscreen fg app, or 0
g_pSetThreadDpiAwarenessContext resq 1   ; user32 (Win10 1607+) or 0
g_pGetWindowDpiAwarenessContext resq 1
g_pLogicalToPhysicalPointForPerMonitorDPI resq 1
g_msgTaskbarCreated resd 1
g_sysdpi        resd 1
g_dpi           resd 1              ; DPI the current size/font were built for
g_w             resd 1              ; scaled metrics
g_h             resd 1
g_offx          resd 1              ; scaled CARET_DX
g_offy          resd 1              ; scaled CARET_DY
g_radius        resd 1
g_visible       resd 1
g_force         resd 1              ; force a SetWindowPos on the next caret tick
g_tray_ok       resd 1
g_tick          resd 1
g_com_ok        resd 1              ; CoInitializeEx succeeded
g_in_timer      resd 1              ; re-entrancy guard (COM modal loops)
g_exiting       resd 1
alignb 16
g_nid           resb NID_SIZE       ; NOTIFYICONDATAW

; =============================================================================
section .text   code align=16
; =============================================================================

; -----------------------------------------------------------------------------
;  start  -  process entry point (no CRT).  Never returns (ExitProcess).
;  Locals: [rsp+60h] WNDCLASSEXW (80)  [rsp+0B0h] MSG (48)
;  Outgoing args up to 12 (CreateWindowExW): [rsp+20h..5Fh]
; -----------------------------------------------------------------------------
global start
FUNC_BEGIN start, 0E8h
    ; DPI awareness must be set before any window (incl. MessageBox) exists
    call    init_dpi

    xor     ecx, ecx
    call    GetModuleHandleW
    mov     [g_hInst], rax

    ; ---- single instance: named mutex in the session namespace ------------
    xor     ecx, ecx                    ; lpMutexAttributes
    xor     edx, edx                    ; bInitialOwner = FALSE
    lea     r8, [szMutex]
    call    CreateMutexW
    mov     [g_hMutex], rax
    call    GetLastError                ; valid also when the handle is returned
    cmp     eax, ERROR_ALREADY_EXISTS
    jne     .first_instance
    xor     ecx, ecx
    lea     rdx, [szAlready]
    lea     r8, [szAppTitle]
    mov     r9d, MB_ICONINFORMATION
    call    MessageBoxW
    xor     ecx, ecx
    call    ExitProcess
.first_instance:

    ; ---- COM (STA) for MSAA + message filter for call timeouts -------------
    xor     ecx, ecx
    mov     edx, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE
    call    CoInitializeEx
    test    eax, eax                    ; S_OK / S_FALSE -> must uninitialize
    js      .no_com
    mov     dword [g_com_ok], 1
    lea     rcx, [g_msgfilter]
    xor     edx, edx                    ; previous filter not needed
    call    CoRegisterMessageFilter
.no_com:

    ; ---- icons -------------------------------------------------------------
    mov     rcx, [g_hInst]
    mov     edx, 1                      ; MAKEINTRESOURCE(1)
    call    LoadIconW
    test    rax, rax
    jnz     .have_icon
    xor     ecx, ecx
    mov     edx, IDI_APPLICATION
    call    LoadIconW
.have_icon:
    mov     [g_hIcon], rax
    mov     [g_hIconSm], rax
    mov     ecx, SM_CXSMICON
    call    GetSystemMetrics
    mov     r12d, eax
    mov     ecx, SM_CYSMICON
    call    GetSystemMetrics
    mov     r13d, eax
    mov     rcx, [g_hInst]
    mov     edx, 1                      ; resource id 1
    mov     r8d, IMAGE_ICON
    mov     r9d, r12d                   ; cx
    mov     [rsp+20h], r13              ; cy
    mov     qword [rsp+28h], 0          ; LR_DEFAULTCOLOR
    call    LoadImageW
    test    rax, rax
    jz      .icons_done
    mov     [g_hIconSm], rax
.icons_done:

    lea     rcx, [szTaskbarCreated]
    call    RegisterWindowMessageW
    mov     [g_msgTaskbarCreated], eax

    ; ---- window class ------------------------------------------------------
    lea     rdi, [rsp+60h]
    xor     eax, eax
    mov     ecx, 80 / 8
    rep     stosq
    mov     dword [rsp+60h], 80         ; cbSize
    lea     rax, [wnd_proc]
    mov     [rsp+60h+8], rax            ; lpfnWndProc
    mov     rax, [g_hInst]
    mov     [rsp+60h+24], rax           ; hInstance
    mov     rax, [g_hIcon]
    mov     [rsp+60h+32], rax           ; hIcon
    xor     ecx, ecx
    mov     edx, IDC_ARROW
    call    LoadCursorW
    mov     [rsp+60h+40], rax           ; hCursor
    lea     rax, [szClass]
    mov     [rsp+60h+64], rax           ; lpszClassName
    mov     rax, [g_hIconSm]
    mov     [rsp+60h+72], rax           ; hIconSm
    lea     rcx, [rsp+60h]
    call    RegisterClassExW
    test    eax, eax
    jz      .fail

    ; ---- hidden tray-owner window (never shown) ----------------------------
    mov     ecx, WS_EX_TOOLWINDOW
    lea     rdx, [szClass]
    lea     r8, [szTrayTitle]
    mov     r9d, WS_POPUP
    xor     eax, eax
    mov     [rsp+20h], rax              ; x
    mov     [rsp+28h], rax              ; y
    mov     [rsp+30h], rax              ; w
    mov     [rsp+38h], rax              ; h
    mov     [rsp+40h], rax              ; hWndParent
    mov     [rsp+48h], rax              ; hMenu
    mov     rax, [g_hInst]
    mov     [rsp+50h], rax              ; hInstance
    mov     qword [rsp+58h], 0          ; lpParam
    call    CreateWindowExW
    test    rax, rax
    jz      .fail
    mov     [g_hwndTray], rax

    ; ---- indicator window --------------------------------------------------
    mov     ecx, WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE
    lea     rdx, [szClass]
    lea     r8, [szIndTitle]
    mov     r9d, WS_POPUP
    xor     eax, eax
    mov     [rsp+20h], rax
    mov     [rsp+28h], rax
    mov     qword [rsp+30h], BASE_SIZE
    mov     qword [rsp+38h], BASE_SIZE
    mov     [rsp+40h], rax
    mov     [rsp+48h], rax
    mov     rax, [g_hInst]
    mov     [rsp+50h], rax
    mov     qword [rsp+58h], 0
    call    CreateWindowExW
    test    rax, rax
    jz      .fail
    mov     [g_hwndInd], rax

    ; layered attributes must be set before the window is first shown
    mov     rcx, rax
    xor     edx, edx                    ; crKey (unused)
    mov     r8d, ALPHA
    mov     r9d, LWA_ALPHA
    call    SetLayeredWindowAttributes

    mov     ecx, [g_sysdpi]             ; first guess; caret tick corrects it
    call    apply_dpi
    call    tray_add

    mov     rcx, [g_hwndInd]
    mov     edx, TIMER_CARET
    mov     r8d, CARET_INTERVAL
    xor     r9d, r9d
    call    SetTimer
    mov     rcx, [g_hwndInd]
    mov     edx, TIMER_IME
    mov     r8d, IME_INTERVAL
    xor     r9d, r9d
    call    SetTimer

    call    update_ime                  ; show immediately, don't wait a tick
    call    update_caret

    ; ---- message loop ------------------------------------------------------
.msg_loop:
    lea     rcx, [rsp+0B0h]
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    call    GetMessageW
    test    eax, eax                    ; 0 = WM_QUIT, -1 = error
    jle     .loop_end
    lea     rcx, [rsp+0B0h]             ; (no TranslateMessage: no keyboard input)
    call    DispatchMessageW
    jmp     .msg_loop
.loop_end:
    mov     ebx, [rsp+0B0h+16]          ; exit code = WM_QUIT wParam
    jmp     .cleanup

.fail:
    mov     ebx, 1
.cleanup:
    call    tray_delete                 ; no-op if already removed
    mov     rcx, [g_hFont]
    test    rcx, rcx
    jz      .no_font
    call    DeleteObject
.no_font:
    mov     rcx, [g_hMutex]
    test    rcx, rcx
    jz      .no_mutex
    call    CloseHandle
.no_mutex:
    cmp     dword [g_com_ok], 0
    je      .no_uninit
    xor     ecx, ecx
    xor     edx, edx
    call    CoRegisterMessageFilter     ; revoke our filter
    call    CoUninitialize
.no_uninit:
    mov     ecx, ebx
    call    ExitProcess
    int3                                ; not reached
FUNC_END

; -----------------------------------------------------------------------------
;  init_dpi  -  per-monitor DPI awareness (V2 if available) and
;               shcore!GetDpiForMonitor lookup; stores system DPI.
;  The manifest already requests PerMonitorV2; the API call is the fallback
;  for when the manifest is ignored.  If the awareness is already set the
;  call fails with ERROR_ACCESS_DENIED, which we treat as success.
; -----------------------------------------------------------------------------
FUNC_BEGIN init_dpi, 28h
    lea     rcx, [szUser32]
    call    GetModuleHandleW            ; user32 is a static import -> loaded
    test    rax, rax
    jz      .legacy
    mov     r12, rax
    ; optional per-thread DPI helpers used by the caret code (0 if missing)
    mov     rcx, r12
    lea     rdx, [szSetThreadDpiAwarenessContext]
    call    GetProcAddress
    mov     [g_pSetThreadDpiAwarenessContext], rax
    mov     rcx, r12
    lea     rdx, [szGetWindowDpiAwarenessContext]
    call    GetProcAddress
    mov     [g_pGetWindowDpiAwarenessContext], rax
    mov     rcx, r12
    lea     rdx, [szLogicalToPhysicalPointForPerMonitorDPI]
    call    GetProcAddress
    mov     [g_pLogicalToPhysicalPointForPerMonitorDPI], rax

    mov     rcx, r12
    lea     rdx, [szSetProcessDpiAwarenessContext]
    call    GetProcAddress
    test    rax, rax
    jz      .legacy
    mov     rbx, rax
    mov     rcx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    call    rbx
    test    eax, eax
    jnz     .aware_done
    call    GetLastError
    cmp     eax, ERROR_ACCESS_DENIED    ; already set (e.g. by the manifest)
    je      .aware_done
    mov     rcx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE
    call    rbx
    test    eax, eax
    jnz     .aware_done
.legacy:
    call    SetProcessDPIAware          ; system-aware as a last resort
.aware_done:

    ; shcore.dll from System32 only (no DLL search-order hijacking)
    lea     rcx, [szShcore]
    xor     edx, edx
    mov     r8d, LOAD_LIBRARY_SEARCH_SYSTEM32
    call    LoadLibraryExW
    test    rax, rax
    jz      .no_shcore
    mov     rcx, rax
    lea     rdx, [szGetDpiForMonitor]
    call    GetProcAddress
    mov     [g_pGetDpiForMonitor], rax
.no_shcore:

    xor     ecx, ecx
    call    GetDC
    mov     rbx, rax
    mov     rcx, rax
    mov     edx, LOGPIXELSX
    call    GetDeviceCaps
    cmp     eax, 48
    jae     .dpi_ok
    mov     eax, 96
.dpi_ok:
    mov     [g_sysdpi], eax
    test    rbx, rbx
    jz      .out
    xor     ecx, ecx
    mov     rdx, rbx
    call    ReleaseDC
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  get_monitor_dpi(RCX = HMONITOR) -> EAX = effective DPI of that monitor
;  Locals: [rsp+20h] dpiX, [rsp+24h] dpiY
; -----------------------------------------------------------------------------
FUNC_BEGIN get_monitor_dpi, 38h
    mov     rax, [g_pGetDpiForMonitor]
    test    rax, rax
    jz      .fallback
    test    rcx, rcx
    jz      .fallback
    mov     dword [rsp+20h], 0
    mov     dword [rsp+24h], 0
    mov     edx, MDT_EFFECTIVE_DPI
    lea     r8, [rsp+20h]
    lea     r9, [rsp+24h]
    call    rax
    test    eax, eax                    ; HRESULT: S_OK == 0
    jnz     .fallback
    mov     eax, [rsp+20h]
    cmp     eax, 48                     ; sanity range 48..1536
    jb      .fallback
    cmp     eax, 1536
    ja      .fallback
    jmp     .out
.fallback:
    mov     eax, [g_sysdpi]
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  font_enum_proc  -  EnumFontFamiliesExW callback (leaf, no frame needed)
;  (lpelfe, lpntme, FontType, lParam=R9 -> int* found)
; -----------------------------------------------------------------------------
font_enum_proc:
    mov     dword [r9], 1
    xor     eax, eax                    ; stop enumerating
    ret

; -----------------------------------------------------------------------------
;  scale(ECX = value @96 DPI) -> EAX = value scaled to g_dpi (MulDiv rounding)
; -----------------------------------------------------------------------------
FUNC_BEGIN scale, 28h
    mov     edx, [g_dpi]
    mov     r8d, 96
    call    MulDiv
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  apply_dpi(ECX = dpi)  -  rebuild metrics, font, window size and region.
;  Locals: [rsp+40h] LOGFONTW (92 bytes, to 9Ch), [rsp+0A0h] int found
;  Outgoing args up to 7 (SetWindowPos): [rsp+20h..37h]
; -----------------------------------------------------------------------------
FUNC_BEGIN apply_dpi, 0A8h
    mov     [g_dpi], ecx

    mov     ecx, BASE_SIZE
    call    scale
    mov     [g_w], eax
    mov     [g_h], eax
    mov     ecx, CARET_DX
    call    scale
    mov     [g_offx], eax
    mov     ecx, CARET_DY
    call    scale
    mov     [g_offy], eax
    mov     ecx, RADIUS
    call    scale
    mov     [g_radius], eax

    ; ---- pick the first installed face from face_table ---------------------
    xor     ecx, ecx
    call    GetDC                       ; screen DC for EnumFontFamiliesExW
    mov     rbx, rax
    lea     r13, [face_table]
    xor     r14d, r14d                  ; candidate index
.face_loop:
    lea     rdi, [rsp+40h]              ; zero LOGFONTW
    xor     eax, eax
    mov     ecx, LOGFONT_SIZE / 4
    rep     stosd
    lea     rdi, [rsp+40h+LF_FACE]      ; copy 32 WCHARs of face name
    mov     rsi, r14
    shl     rsi, 6
    add     rsi, r13
    mov     ecx, 32
    rep     movsw
    cmp     r14d, FACE_COUNT - 1        ; last entry (empty name): always use
    jae     .create
    test    rbx, rbx
    jz      .next_face
    mov     byte [rsp+40h+23], DEFAULT_CHARSET
    mov     dword [rsp+0A0h], 0
    mov     rcx, rbx
    lea     rdx, [rsp+40h]
    lea     r8, [font_enum_proc]
    lea     r9, [rsp+0A0h]
    mov     qword [rsp+20h], 0          ; dwFlags
    call    EnumFontFamiliesExW
    cmp     dword [rsp+0A0h], 0
    jne     .create
.next_face:
    inc     r14d
    jmp     .face_loop

.create:
    mov     ecx, FONT_PX
    call    scale
    neg     eax                         ; negative = character height in px
    mov     [rsp+40h], eax              ; lfHeight
    mov     dword [rsp+40h+16], FW_BOLD ; lfWeight
    mov     byte [rsp+40h+23], SHIFTJIS_CHARSET
    mov     byte [rsp+40h+26], ANTIALIASED_QUALITY
    mov     byte [rsp+40h+27], VARIABLE_PITCH_SWISS
    lea     rcx, [rsp+40h]
    call    CreateFontIndirectW
    test    rax, rax
    jz      .font_done
    mov     rcx, [g_hFont]
    mov     [g_hFont], rax
    test    rcx, rcx
    jz      .font_done
    call    DeleteObject                ; old font (not selected anywhere)
.font_done:
    test    rbx, rbx
    jz      .no_dc
    xor     ecx, ecx
    mov     rdx, rbx
    call    ReleaseDC
.no_dc:

    ; ---- resize window and set rounded region -----------------------------
    mov     rcx, [g_hwndInd]
    test    rcx, rcx
    jz      .out
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, [g_w]
    mov     [rsp+20h], rax
    mov     eax, [g_h]
    mov     [rsp+28h], rax
    mov     qword [rsp+30h], SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
    call    SetWindowPos

    xor     ecx, ecx
    xor     edx, edx
    mov     r8d, [g_w]
    inc     r8d                         ; region right/bottom are exclusive+1
    mov     r9d, [g_h]
    inc     r9d
    mov     eax, [g_radius]
    mov     [rsp+20h], rax
    mov     [rsp+28h], rax
    call    CreateRoundRectRgn
    test    rax, rax
    jz      .no_rgn
    mov     r15, rax
    mov     rcx, [g_hwndInd]
    mov     rdx, r15
    mov     r8d, 1                      ; bRedraw
    call    SetWindowRgn                ; on success the system owns the region
    test    eax, eax
    jnz     .no_rgn
    mov     rcx, r15
    call    DeleteObject
.no_rgn:
    mov     dword [g_force], 1
    mov     rcx, [g_hwndInd]
    xor     edx, edx
    xor     r8d, r8d
    call    InvalidateRect
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  update_caret  -  timer 1: find the text caret of the foreground thread and
;  place the indicator below-right of it; hide when there is no caret.
;
;  Locals:
;    [rsp+40h]  GUITHREADINFO (72, to 88h): hwndActive 48h, hwndFocus 50h,
;               hwndCaret 70h, rcCaret 78h (L 78h T 7Ch R 80h B 84h)
;    [rsp+88h]  RECT caret in screen coords (L 88h T 8Ch R 90h B 94h)
;    [rsp+98h]  MONITORINFO (40, to 0C0h): rcWork L 0ACh T 0B0h R 0B4h B 0B8h
;    [rsp+0C0h] RECT foreground window (L C0h T C4h R C8h B CCh)
;    [rsp+0D0h] VARIANT (24, to 0E8h) = { vt=VT_I4, lVal=CHILDID_SELF }
;    [rsp+0E8h] IAccessible*
;    [rsp+0F0h] long left, [0F4h] top, [0F8h] width, [0FCh] height
;  Outgoing args: up to 7 (SetWindowPos) -> [rsp+20h..37h]
;  Registers: RBX=foreground, R12=focus/target window, R13=window the caret
;    coordinates belong to, R14=result (0 none, 1 found, 2 target hung),
;    R15=previous thread DPI context (0 = not switched), ESI/EDI scratch.
;  Only the Win32-caret query (GetGUIThreadInfo + ClientToScreen, which never
;  pump messages) runs in the switched DPI context; MSAA/COM runs in ours.
; -----------------------------------------------------------------------------
FUNC_BEGIN update_caret, 108h
    call    GetForegroundWindow
    test    rax, rax
    jz      .hide
    mov     rbx, rax
    cmp     rax, [g_hwndInd]            ; our own windows (e.g. tray menu)
    je      .hide
    cmp     rax, [g_hwndTray]
    je      .hide
    mov     rcx, rbx
    call    is_shell_window             ; desktop / taskbar
    test    eax, eax
    jnz     .hide

    ; ---- Win32 caret query in the foreground window's DPI context ---------
    xor     r15d, r15d
    mov     rax, [g_pGetWindowDpiAwarenessContext]
    test    rax, rax
    jz      .ctx_done
    cmp     qword [g_pSetThreadDpiAwarenessContext], 0
    je      .ctx_done
    mov     rcx, rbx
    call    rax
    test    rax, rax
    jz      .ctx_done
    mov     rcx, rax
    call    [g_pSetThreadDpiAwarenessContext]
    mov     r15, rax                    ; previous context, 0 on failure
.ctx_done:

    xor     r14d, r14d
    mov     r12, rbx
    mov     r13, rbx
    mov     rcx, rbx
    xor     edx, edx
    call    GetWindowThreadProcessId
    test    eax, eax
    jz      .win32_done
    mov     esi, eax                    ; thread id
    lea     rdi, [rsp+40h]
    xor     eax, eax
    mov     ecx, GTI_SIZE / 8
    rep     stosq
    mov     dword [rsp+40h], GTI_SIZE
    mov     ecx, esi
    lea     rdx, [rsp+40h]
    call    GetGUIThreadInfo
    test    eax, eax
    jz      .win32_done
    mov     rax, [rsp+50h]              ; hwndFocus
    test    rax, rax
    jnz     .set_target
    mov     rax, [rsp+48h]              ; hwndActive
    test    rax, rax
    jz      .target_done
.set_target:
    mov     r12, rax
.target_done:

    ; ---- (a) classic Win32 caret ------------------------------------------
%ifdef DEBUG_FORCE_MSAA                 ; test builds only: skip (a)
    jmp     .win32_done
%endif
    mov     rax, [rsp+70h]              ; hwndCaret
    test    rax, rax
    jz      .win32_done
    mov     ecx, [rsp+84h]              ; rcCaret.bottom > rcCaret.top ?
    cmp     ecx, [rsp+7Ch]
    jle     .win32_done
    mov     r13, rax
    mov     rcx, r13
    lea     rdx, [rsp+78h]              ; (left, top)  client -> screen
    call    ClientToScreen
    test    eax, eax
    jz      .win32_done
    mov     rcx, r13
    lea     rdx, [rsp+80h]              ; (right, bottom)
    call    ClientToScreen
    test    eax, eax
    jz      .win32_done
    mov     rax, [rsp+78h]
    mov     [rsp+88h], rax
    mov     rax, [rsp+80h]
    mov     [rsp+90h], rax
    mov     r14d, 1
.win32_done:
    ; back to our own (per-monitor v2) context BEFORE any COM call: a COM
    ; modal loop may dispatch WM_PAINT to us, which must run in our context
    test    r15, r15
    jz      .ctx_restored
    mov     rcx, r15
    call    [g_pSetThreadDpiAwarenessContext]
.ctx_restored:
    test    r14d, r14d
    jz      .msaa
    ; logical (target's DPI view) -> physical screen pixels.  No-op for
    ; per-monitor aware targets; only meaningful if we switched context.
    test    r15, r15
    jz      .have_caret
    mov     rax, [g_pLogicalToPhysicalPointForPerMonitorDPI]
    test    rax, rax
    jz      .have_caret
    mov     rcx, r13
    lea     rdx, [rsp+88h]
    call    rax
    mov     rcx, r13
    lea     rdx, [rsp+90h]
    call    [g_pLogicalToPhysicalPointForPerMonitorDPI]
    jmp     .have_caret


    ; ---- (b) MSAA caret object ---------------------------------------------
    ; Runs in our own per-monitor-v2 context; accLocation returns screen
    ; coordinates which are used as they are.
.msaa:
    mov     r13, r12
    cmp     dword [g_com_ok], 0
    je      .query_done
    mov     rcx, rbx
    call    IsHungAppWindow             ; never talk COM to a hung app
    test    eax, eax
    jz      .not_hung
    mov     r14d, 2
    jmp     .query_done
.not_hung:
    mov     qword [rsp+0E8h], 0
    mov     rcx, r12                    ; focus window (or foreground)
    mov     edx, OBJID_CARET
    lea     r8, [IID_IAccessible]
    lea     r9, [rsp+0E8h]
    call    AccessibleObjectFromWindow
    test    eax, eax                    ; HRESULT
    jnz     .query_done
    mov     rcx, [rsp+0E8h]
    test    rcx, rcx
    jz      .query_done
    xor     eax, eax
    mov     [rsp+0D0h], rax             ; VARIANT: vt = VT_I4, lVal = 0
    mov     [rsp+0D8h], rax
    mov     [rsp+0E0h], rax
    mov     word [rsp+0D0h], VT_I4
    mov     dword [rsp+0D8h], CHILDID_SELF
    mov     [rsp+0F0h], rax             ; left = top = 0
    mov     [rsp+0F8h], rax             ; width = height = 0
    ; accLocation(this, &l, &t, &w, &h, VARIANT varChild).  A 24-byte
    ; VARIANT "by value" is passed by reference to a caller-owned copy on x64.
    mov     rax, [rcx]                  ; vtable
    lea     rdx, [rsp+0F0h]
    lea     r8, [rsp+0F4h]
    lea     r9, [rsp+0F8h]
    lea     r10, [rsp+0FCh]
    mov     [rsp+20h], r10
    lea     r10, [rsp+0D0h]
    mov     [rsp+28h], r10
    call    [rax+IACC_accLocation]
    mov     esi, eax                    ; HRESULT
    mov     rcx, [rsp+0E8h]
    mov     rax, [rcx]
    call    [rax+IUNK_Release]          ; release every poll
    test    esi, esi                    ; only S_OK counts
    jnz     .query_done
    mov     eax, [rsp+0FCh]
    test    eax, eax
    jle     .query_done                 ; zero height -> no caret
    mov     eax, [rsp+0F0h]
    or      eax, [rsp+0F4h]
    jz      .query_done                 ; (0,0) -> no caret
    mov     eax, [rsp+0F0h]
    mov     [rsp+88h], eax
    add     eax, [rsp+0F8h]
    mov     [rsp+90h], eax
    mov     eax, [rsp+0F4h]
    mov     [rsp+8Ch], eax
    add     eax, [rsp+0FCh]
    mov     [rsp+94h], eax
    mov     r14d, 1

.query_done:
    cmp     r14d, 2
    je      .out                        ; target hung: leave things as they are
    test    r14d, r14d
    jz      .hide
.have_caret:
    ; ---- sanity: caret must lie inside the foreground window ---------------
    mov     rcx, rbx
    lea     rdx, [rsp+0C0h]
    call    GetWindowRect
    test    eax, eax
    jz      .hide
    mov     eax, [rsp+88h]              ; caret.left in [fg.left, fg.right]
    cmp     eax, [rsp+0C0h]
    jl      .hide
    cmp     eax, [rsp+0C8h]
    jg      .hide
    mov     eax, [rsp+8Ch]              ; caret.top in [fg.top, fg.bottom]
    cmp     eax, [rsp+0C4h]
    jl      .hide
    cmp     eax, [rsp+0CCh]
    jg      .hide

    ; ---- monitor of the caret ------------------------------------------------
    mov     rcx, [rsp+88h]              ; POINT (left, top) by value
    mov     edx, MONITOR_DEFAULTTONULL
    call    MonitorFromPoint
    test    rax, rax
    jz      .hide                       ; off-screen caret
    mov     r12, rax
    cmp     rax, [g_fs_monitor]         ; fullscreen app on that monitor
    je      .hide
    mov     rcx, r12
    call    get_monitor_dpi
    cmp     eax, [g_dpi]
    je      .dpi_ok
    mov     ecx, eax
    call    apply_dpi                   ; sets g_force
.dpi_ok:
    mov     dword [rsp+98h], 40         ; MONITORINFO.cbSize
    mov     rcx, r12
    lea     rdx, [rsp+98h]
    call    GetMonitorInfoW
    test    eax, eax
    jz      .hide

    ; ---- position: below-right of the caret, or above it -------------------
    mov     esi, [rsp+88h]
    add     esi, [g_offx]               ; x = caret.left + dx
    mov     edi, [rsp+94h]
    add     edi, [g_offy]               ; y = caret.bottom + dy
    mov     eax, edi
    add     eax, [g_h]
    cmp     eax, [rsp+0B8h]             ; rcWork.bottom
    jle     .y_ok
    mov     edi, [rsp+8Ch]              ; flip: y = caret.top - h - dy
    sub     edi, [g_h]
    sub     edi, [g_offy]
.y_ok:
    ; clamp into rcWork
    mov     eax, [rsp+0B4h]
    sub     eax, [g_w]
    cmp     esi, eax
    jle     .cx1
    mov     esi, eax
.cx1:
    cmp     esi, [rsp+0ACh]
    jge     .cx2
    mov     esi, [rsp+0ACh]
.cx2:
    mov     eax, [rsp+0B8h]
    sub     eax, [g_h]
    cmp     edi, eax
    jle     .cy1
    mov     edi, eax
.cy1:
    cmp     edi, [rsp+0B0h]
    jge     .cy2
    mov     edi, [rsp+0B0h]
.cy2:

    ; ---- move only if something changed ---------------------------------------
    cmp     dword [g_force], 0
    jne     .move
    cmp     dword [g_visible], 0
    je      .move
    cmp     esi, [g_lastx]
    jne     .move
    cmp     edi, [g_lasty]
    jne     .move
    jmp     .out

.move:
    mov     [g_lastx], esi
    mov     [g_lasty], edi
    mov     dword [g_force], 0
    mov     dword [g_visible], 1
    mov     rcx, [g_hwndInd]
    mov     rdx, HWND_TOPMOST
    movsxd  r8, esi                     ; coordinates may be negative
    movsxd  r9, edi
    mov     eax, [g_w]
    mov     [rsp+20h], rax
    mov     eax, [g_h]
    mov     [rsp+28h], rax
    mov     qword [rsp+30h], SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER
    call    SetWindowPos
    jmp     .out

.hide:
    cmp     dword [g_visible], 0
    je      .out
    mov     dword [g_visible], 0
    mov     rcx, [g_hwndInd]
    mov     edx, SW_HIDE
    call    ShowWindow
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  is_shell_window(RCX = hwnd) -> EAX = 1 if desktop / taskbar / shell window
;  Locals: [rsp+30h] WCHAR class[64] (128 bytes, to 0B0h)
; -----------------------------------------------------------------------------
FUNC_BEGIN is_shell_window, 0B8h
    mov     rbx, rcx
    call    GetShellWindow
    cmp     rax, rbx
    je      .yes
    call    GetDesktopWindow
    cmp     rax, rbx
    je      .yes
    mov     rcx, rbx
    lea     rdx, [rsp+30h]
    mov     r8d, 64
    call    GetClassNameW
    test    eax, eax
    jz      .no
    lea     r12, [shell_class_table]
.cls_loop:
    lea     rcx, [rsp+30h]
    mov     rdx, r12
    call    lstrcmpiW
    test    eax, eax
    jz      .yes
    add     r12, 64
    cmp     word [r12], 0               ; empty entry terminates the table
    jne     .cls_loop
.no:
    xor     eax, eax
    jmp     .out
.yes:
    mov     eax, 1
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  Static COM IMessageFilter object (g_msgfilter -> msgfilter_vtbl).
;  All methods are leaf functions (no stack use, no nonvolatile registers),
;  so they need no unwind data.  The object is never freed (AddRef/Release
;  return a constant).
;  MessagePending is called while an outgoing cross-process call (MSAA
;  accLocation etc.) is waiting and a message arrives (our 50 ms timer makes
;  sure one does): after COM_CALL_TIMEOUT ms the call is cancelled
;  (RPC_E_CALL_CANCELED), so a busy target app cannot freeze the indicator.
; -----------------------------------------------------------------------------
msgfilter_QueryInterface:               ; (this, riid, ppv)
    mov     rax, [rdx+8]                ; IUnknown and IMessageFilter share
    cmp     rax, [IID_IUnknown+8]       ; their last 8 bytes
    jne     .no
    mov     rax, [rdx]
    test    rax, rax                    ; {00000000-0000-0000-...}
    jz      .yes
    cmp     rax, [IID_IMessageFilter]   ; {00000016-0000-0000-...}
    jne     .no
.yes:
    mov     [r8], rcx
    xor     eax, eax                    ; S_OK
    ret
.no:
    mov     qword [r8], 0
    mov     eax, E_NOINTERFACE
    ret

msgfilter_AddRef:
msgfilter_Release:
    mov     eax, 1
    ret

msgfilter_HandleInComingCall:           ; we serve no COM objects to others
    xor     eax, eax                    ; SERVERCALL_ISHANDLED
    ret

msgfilter_RetryRejectedCall:            ; callee busy/rejected: give up
    mov     eax, -1
    ret

msgfilter_MessagePending:               ; (this, htask, dwTickCount, type)
    cmp     r8d, COM_CALL_TIMEOUT
    jb      .wait
    mov     eax, PENDINGMSG_CANCELCALL
    ret
.wait:
    mov     eax, PENDINGMSG_WAITDEFPROCESS
    ret

; -----------------------------------------------------------------------------
;  detect_fullscreen(RCX = foreground HWND)  -  sets g_fs_monitor to the
;  monitor covered by a fullscreen foreground window, or 0.
;  "Fullscreen" = window rect covers the whole monitor AND the window has no
;  standard caption (games, F11 browsers, video players).  Maximized normal
;  windows keep WS_CAPTION and are therefore not treated as fullscreen.
;  The desktop / taskbar (is_shell_window) is never fullscreen.
;  Locals: [rsp+0B0h] RECT window (L B0 T B4 R B8 B BC)
;          [rsp+0C0h] MONITORINFO (40, to 0E8h): rcMonitor L C4 T C8 R CC B D0
; -----------------------------------------------------------------------------
FUNC_BEGIN detect_fullscreen, 0E8h
    mov     rbx, rcx
    xor     r14d, r14d                  ; result
    test    rbx, rbx
    jz      .out
    mov     rcx, rbx
    call    is_shell_window             ; desktop / taskbar never fullscreen
    test    eax, eax
    jnz     .out

    mov     rcx, rbx
    mov     edx, GWL_STYLE
    call    GetWindowLongPtrW
    and     eax, WS_CAPTION
    cmp     eax, WS_CAPTION
    je      .out                        ; has a title bar -> normal window

    mov     rcx, rbx
    mov     edx, MONITOR_DEFAULTTONULL
    call    MonitorFromWindow
    test    rax, rax
    jz      .out
    mov     r12, rax
    mov     dword [rsp+0C0h], 40
    mov     rcx, r12
    lea     rdx, [rsp+0C0h]
    call    GetMonitorInfoW
    test    eax, eax
    jz      .out
    mov     rcx, rbx
    lea     rdx, [rsp+0B0h]
    call    GetWindowRect
    test    eax, eax
    jz      .out

    mov     eax, [rsp+0B0h]             ; left   <= mon.left
    cmp     eax, [rsp+0C4h]
    jg      .out
    mov     eax, [rsp+0B4h]             ; top    <= mon.top
    cmp     eax, [rsp+0C8h]
    jg      .out
    mov     eax, [rsp+0B8h]             ; right  >= mon.right
    cmp     eax, [rsp+0CCh]
    jl      .out
    mov     eax, [rsp+0BCh]             ; bottom >= mon.bottom
    cmp     eax, [rsp+0D0h]
    jl      .out
    mov     r14, r12                    ; fullscreen on monitor r12
.out:
    mov     [g_fs_monitor], r14
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  query_ime(RCX = IME window, EDX = IMC_xxx, R8 = DWORD_PTR* result)
;    -> EAX != 0 on success.  Wraps SendMessageTimeoutW(WM_IME_CONTROL).
;  Outgoing args: 7 (to [rsp+30h])
; -----------------------------------------------------------------------------
FUNC_BEGIN query_ime, 38h
    mov     qword [r8], 0
    mov     [rsp+30h], r8               ; lpdwResult
    mov     r8d, edx                    ; wParam = IMC_xxx
    mov     edx, WM_IME_CONTROL
    xor     r9d, r9d                    ; lParam = 0
    mov     qword [rsp+20h], SMTO_ABORTIFHUNG
    mov     qword [rsp+28h], IME_TIMEOUT
    call    SendMessageTimeoutW
    ; RAX = 0 on failure / timeout (also when blocked by UIPI)
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  update_ime  -  timer 2: determine the IME mode of the foreground app.
;  Locals: [rsp+40h] GUITHREADINFO (72, to 88h), [rsp+88h] DWORD_PTR result
;  Registers: RBX=foreground HWND, R12=target HWND, R13=IME window, ESI=state
; -----------------------------------------------------------------------------
FUNC_BEGIN update_ime, 98h
    inc     dword [g_tick]

    call    GetForegroundWindow
    test    rax, rax
    jz      .housekeep                  ; transient (switching) -> keep state
    mov     rbx, rax

    mov     rcx, rbx
    call    detect_fullscreen

    ; ---- focus window of the foreground thread -----------------------------
    mov     r12, rbx                    ; default target: foreground window
    mov     rcx, rbx
    xor     edx, edx
    call    GetWindowThreadProcessId
    test    eax, eax
    jz      .have_target
    mov     r13d, eax                   ; thread id
    lea     rdi, [rsp+40h]
    xor     eax, eax
    mov     ecx, GTI_SIZE / 8
    rep     stosq
    mov     dword [rsp+40h], GTI_SIZE   ; cbSize
    mov     ecx, r13d
    lea     rdx, [rsp+40h]
    call    GetGUIThreadInfo
    test    eax, eax
    jz      .have_target
    mov     rax, [rsp+40h+16]           ; hwndFocus
    test    rax, rax
    jnz     .set_target
    mov     rax, [rsp+40h+8]            ; hwndActive
    test    rax, rax
    jz      .have_target
.set_target:
    mov     r12, rax
.have_target:

    ; ---- default IME window of that window's thread ------------------------
    mov     rcx, r12
    call    ImmGetDefaultIMEWnd
    test    rax, rax
    jnz     .have_ime
    cmp     r12, rbx
    je      .unknown
    mov     rcx, rbx
    call    ImmGetDefaultIMEWnd
    test    rax, rax
    jz      .unknown
.have_ime:
    mov     r13, rax

    mov     rcx, r13
    mov     edx, IMC_GETOPENSTATUS
    lea     r8, [rsp+88h]
    call    query_ime
    test    eax, eax
    jz      .unknown
    cmp     qword [rsp+88h], 0
    je      .off

    mov     rcx, r13
    mov     edx, IMC_GETCONVERSIONMODE
    lea     r8, [rsp+88h]
    call    query_ime
    test    eax, eax
    jz      .hira                       ; open but mode unknown: assume あ
    mov     eax, [rsp+88h]
    test    eax, IME_CMODE_NATIVE
    jz      .alnum
    test    eax, IME_CMODE_KATAKANA
    jz      .hira
    test    eax, IME_CMODE_FULLSHAPE
    jz      .hkata
    mov     esi, ST_KATA
    jmp     .set
.hkata:
    mov     esi, ST_HKATA
    jmp     .set
.hira:
    mov     esi, ST_HIRA
    jmp     .set
.alnum:
    test    eax, IME_CMODE_FULLSHAPE
    jz      .off
    mov     esi, ST_FALNUM
    jmp     .set
.off:
    mov     esi, ST_OFF
    jmp     .set
.unknown:
    mov     esi, ST_UNKNOWN
.set:
%ifdef DEBUG_FORCE_STATE                ; test builds only: nasm -DDEBUG_FORCE_STATE=n
    mov     esi, DEBUG_FORCE_STATE
%endif
    cmp     esi, [g_state]
    je      .housekeep
    mov     [g_state], esi
    mov     rcx, [g_hwndInd]            ; repaint only on change
    xor     edx, edx
    xor     r8d, r8d
    call    InvalidateRect

    ; ---- every HOUSEKEEP_TICKS: tray retry + re-assert topmost -------------
.housekeep:
    mov     eax, [g_tick]
    xor     edx, edx
    mov     ecx, HOUSEKEEP_TICKS
    div     ecx
    test    edx, edx
    jnz     .out
    cmp     dword [g_tray_ok], 0
    jne     .tray_fine
    call    tray_add                    ; Explorer was not ready at startup
.tray_fine:
    cmp     dword [g_visible], 0
    je      .out
    mov     rcx, [g_hwndInd]
    mov     rdx, HWND_TOPMOST
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword [rsp+20h], 0
    mov     qword [rsp+28h], 0
    mov     qword [rsp+30h], SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER
    call    SetWindowPos
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  paint(RCX = hwnd) -> EAX = 0   (WM_PAINT handler)
;  Locals: [rsp+40h] PAINTSTRUCT (72, to 88h), [rsp+88h] RECT client,
;          [rsp+98h] WCHAR text[2]
;  Outgoing args: 7 (RoundRect) to [rsp+30h]
;  Registers: RBX=hwnd R12=hdc R13=state entry R14=brush R15=pen RSI/RDI=old
; -----------------------------------------------------------------------------
FUNC_BEGIN paint, 0A8h
    mov     rbx, rcx
    mov     rcx, rbx
    lea     rdx, [rsp+40h]
    call    BeginPaint
    test    rax, rax
    jz      .out
    mov     r12, rax
    mov     rcx, rbx
    lea     rdx, [rsp+88h]
    call    GetClientRect

    mov     eax, [g_state]
    cmp     eax, ST_COUNT               ; unsigned: -1 also -> unknown
    jb      .st_ok
    mov     eax, ST_UNKNOWN
.st_ok:
    imul    eax, eax, STATE_ENTRY
    lea     r13, [state_table]
    add     r13, rax

    mov     ecx, [r13+4]
    call    CreateSolidBrush
    mov     r14, rax
    mov     eax, [g_dpi]                ; border width = max(1, dpi/96)
    xor     edx, edx
    mov     ecx, 96
    div     ecx
    test    eax, eax
    jnz     .pw_ok
    mov     eax, 1
.pw_ok:
    mov     ecx, PS_SOLID
    mov     edx, eax
    mov     r8d, [r13+8]
    call    CreatePen
    mov     r15, rax

    mov     rcx, r12
    mov     rdx, r14
    call    SelectObject
    mov     rsi, rax                    ; old brush
    mov     rcx, r12
    mov     rdx, r15
    call    SelectObject
    mov     rdi, rax                    ; old pen

    mov     rcx, r12                    ; RoundRect(hdc,0,0,right,bottom,r,r)
    xor     edx, edx
    xor     r8d, r8d
    mov     r9d, [rsp+88h+8]
    mov     eax, [rsp+88h+12]
    mov     [rsp+20h], rax
    mov     eax, [g_radius]
    mov     [rsp+28h], rax
    mov     [rsp+30h], rax
    call    RoundRect

    mov     rcx, r12
    mov     rdx, rdi
    call    SelectObject
    mov     rcx, r12
    mov     rdx, rsi
    call    SelectObject
    test    r15, r15
    jz      .no_pen
    mov     rcx, r15
    call    DeleteObject
.no_pen:
    test    r14, r14
    jz      .no_brush
    mov     rcx, r14
    call    DeleteObject
.no_brush:

    mov     rcx, r12
    mov     edx, TRANSPARENT_BK
    call    SetBkMode
    mov     rcx, r12
    mov     edx, 00FFFFFFh              ; white text
    call    SetTextColor
    mov     rcx, r12
    mov     rdx, [g_hFont]
    call    SelectObject
    mov     rsi, rax                    ; old font

    movzx   eax, word [r13]
    mov     [rsp+98h], ax
    mov     word [rsp+9Ah], 0
    mov     rcx, r12
    lea     rdx, [rsp+98h]
    mov     r8d, 1                      ; one character
    lea     r9, [rsp+88h]
    mov     qword [rsp+20h], DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX
    call    DrawTextW

    test    rsi, rsi
    jz      .no_oldfont
    mov     rcx, r12
    mov     rdx, rsi
    call    SelectObject
.no_oldfont:
    mov     rcx, rbx
    lea     rdx, [rsp+40h]
    call    EndPaint
.out:
    xor     eax, eax
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  tray_add  -  add (or re-add) the notification-area icon.
; -----------------------------------------------------------------------------
FUNC_BEGIN tray_add, 28h
    lea     rbx, [g_nid]
    mov     rdi, rbx
    xor     eax, eax
    mov     ecx, NID_SIZE / 8
    rep     stosq
    mov     dword [rbx], NID_SIZE       ; cbSize
    mov     rax, [g_hwndTray]
    mov     [rbx+8], rax                ; hWnd
    mov     dword [rbx+16], TRAY_UID    ; uID
    mov     dword [rbx+20], NIF_MESSAGE | NIF_ICON | NIF_TIP
    mov     dword [rbx+24], WM_TRAY     ; uCallbackMessage
    mov     rax, [g_hIconSm]
    mov     [rbx+32], rax               ; hIcon
    lea     rdi, [rbx+40]               ; szTip
    lea     rsi, [szTip]
    mov     ecx, szTip_chars
    rep     movsw

    mov     ecx, NIM_ADD
    mov     rdx, rbx
    call    Shell_NotifyIconW
    test    eax, eax
    jnz     .ok
    mov     ecx, NIM_MODIFY             ; maybe it already exists
    mov     rdx, rbx
    call    Shell_NotifyIconW
    test    eax, eax
    jnz     .ok
    mov     dword [g_tray_ok], 0
    jmp     .out
.ok:
    mov     dword [g_tray_ok], 1
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  tray_delete  -  remove the notification-area icon (idempotent).
; -----------------------------------------------------------------------------
FUNC_BEGIN tray_delete, 28h
    cmp     dword [g_nid], 0            ; never added
    je      .out
    mov     ecx, NIM_DELETE
    lea     rdx, [g_nid]
    call    Shell_NotifyIconW
    mov     dword [g_nid], 0
    mov     dword [g_tray_ok], 0
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  show_menu  -  tray right-click menu:  [IME インジケーター v1.1] / --- / 終了
;  Locals: [rsp+40h] POINT
;  Outgoing args: 7 (TrackPopupMenu) to [rsp+30h]
; -----------------------------------------------------------------------------
FUNC_BEGIN show_menu, 58h
    lea     rcx, [rsp+40h]
    call    GetCursorPos
    call    CreatePopupMenu
    test    rax, rax
    jz      .out
    mov     rbx, rax

    mov     rcx, rbx
    mov     edx, MF_STRING | MF_GRAYED
    xor     r8d, r8d
    lea     r9, [szMenuTitle]
    call    AppendMenuW
    mov     rcx, rbx
    mov     edx, MF_SEPARATOR
    xor     r8d, r8d
    xor     r9d, r9d
    call    AppendMenuW
    mov     rcx, rbx
    mov     edx, MF_STRING
    mov     r8d, ID_EXIT
    lea     r9, [szExit]
    call    AppendMenuW

    ; required so the menu closes when the user clicks elsewhere (KB135788)
    mov     rcx, [g_hwndTray]
    call    SetForegroundWindow

    mov     rcx, rbx
    mov     edx, TPM_RIGHTBUTTON | TPM_RIGHTALIGN | TPM_BOTTOMALIGN | TPM_NONOTIFY | TPM_RETURNCMD
    movsxd  r8, dword [rsp+40h]
    movsxd  r9, dword [rsp+44h]
    mov     qword [rsp+20h], 0          ; nReserved
    mov     rax, [g_hwndTray]
    mov     [rsp+28h], rax              ; hWnd
    mov     qword [rsp+30h], 0          ; prcRect
    call    TrackPopupMenu
    mov     esi, eax                    ; selected command id or 0

    mov     rcx, [g_hwndTray]
    mov     edx, WM_NULL
    xor     r8d, r8d
    xor     r9d, r9d
    call    PostMessageW
    mov     rcx, rbx
    call    DestroyMenu

    cmp     esi, ID_EXIT
    jne     .out
    call    do_exit
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  do_exit  -  stop timers, remove tray icon, destroy windows, quit loop.
; -----------------------------------------------------------------------------
FUNC_BEGIN do_exit, 28h
    cmp     dword [g_exiting], 0
    jne     .out
    mov     dword [g_exiting], 1
    mov     rcx, [g_hwndInd]
    mov     edx, TIMER_CARET
    call    KillTimer
    mov     rcx, [g_hwndInd]
    mov     edx, TIMER_IME
    call    KillTimer
    call    tray_delete
    mov     rcx, [g_hwndInd]
    call    DestroyWindow
    mov     rcx, [g_hwndTray]
    call    DestroyWindow
    xor     ecx, ecx
    call    PostQuitMessage
.out:
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  Message handlers.  Called by wnd_proc via tail-jump with the original
;  (hwnd=RCX, msg=EDX, wParam=R8, lParam=R9); return LRESULT in RAX.
; -----------------------------------------------------------------------------
FUNC_BEGIN on_timer, 28h
    ; A cross-process COM call (MSAA) runs a modal message loop that may
    ; dispatch our own WM_TIMER again: never nest the timer work.
    cmp     dword [g_in_timer], 0
    jne     .out
    cmp     dword [g_exiting], 0
    jne     .out
    mov     dword [g_in_timer], 1
    cmp     r8, TIMER_CARET
    jne     .not_caret
    call    update_caret
    jmp     .done
.not_caret:
    cmp     r8, TIMER_IME
    jne     .done
    call    update_ime
.done:
    mov     dword [g_in_timer], 0
.out:
    xor     eax, eax
FUNC_RET
FUNC_END

FUNC_BEGIN on_tray, 28h
    movzx   eax, r9w                    ; LOWORD(lParam) = mouse message
    cmp     eax, WM_RBUTTONUP
    je      .menu
    cmp     eax, WM_CONTEXTMENU
    jne     .out
.menu:
    call    show_menu
.out:
    xor     eax, eax
FUNC_RET
FUNC_END

FUNC_BEGIN on_command, 28h
    movzx   eax, r8w                    ; LOWORD(wParam) = command id
    cmp     eax, ID_EXIT
    jne     .out
    call    do_exit
.out:
    xor     eax, eax
FUNC_RET
FUNC_END

FUNC_BEGIN on_close, 28h               ; WM_CLOSE (e.g. "taskkill" w/o /F)
    call    do_exit
    xor     eax, eax
FUNC_RET
FUNC_END

FUNC_BEGIN on_endsession, 28h          ; logoff/shutdown: remove tray icon
    test    r8, r8
    jz      .out
    call    tray_delete
.out:
    xor     eax, eax
FUNC_RET
FUNC_END

FUNC_BEGIN on_taskbar_created, 28h     ; Explorer (re)started
    mov     dword [g_tray_ok], 0
    call    tray_add
    xor     eax, eax
FUNC_RET
FUNC_END

; -----------------------------------------------------------------------------
;  wnd_proc  -  shared by both windows.  Pure dispatcher: it never touches
;  RSP or nonvolatile registers (leaf, no unwind data needed) and tail-jumps
;  to a handler (which builds its own frame) or to DefWindowProcW, so the
;  caller's stack/shadow space is passed through unchanged.
; -----------------------------------------------------------------------------
wnd_proc:
    cmp     edx, WM_TIMER
    je      on_timer
    cmp     edx, WM_PAINT
    je      paint
    cmp     edx, WM_ERASEBKGND
    je      .ret1                       ; everything is drawn in WM_PAINT
    cmp     edx, WM_NCHITTEST
    je      .ret_transparent            ; extra click-through safety
    cmp     edx, WM_MOUSEACTIVATE
    je      .ret_noactivate
    cmp     edx, WM_TRAY
    je      on_tray
    cmp     edx, WM_COMMAND
    je      on_command
    cmp     edx, WM_CLOSE
    je      on_close
    cmp     edx, WM_ENDSESSION
    je      on_endsession
    cmp     edx, WM_DPICHANGED
    jne     .not_dpi
    mov     dword [g_force], 1          ; we size/position ourselves on the
    xor     eax, eax                    ; next caret tick (monitor DPI is re-read)
    ret
.not_dpi:
    cmp     edx, WM_DISPLAYCHANGE
    jne     .not_display
    mov     dword [g_force], 1          ; resolution changed: re-place
    jmp     DefWindowProcW
.not_display:
    mov     eax, [g_msgTaskbarCreated]
    test    eax, eax
    jz      .default
    cmp     edx, eax
    je      on_taskbar_created
.default:
    jmp     DefWindowProcW
.ret1:
    mov     eax, 1
    ret
.ret_transparent:
    mov     rax, HTTRANSPARENT
    ret
.ret_noactivate:
    mov     eax, MA_NOACTIVATE
    ret
