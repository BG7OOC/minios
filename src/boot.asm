;========================================================
;  MiniOS - 引导扇区 (Bootloader)
;  16位实模式 -> 32位保护模式 -> 跳转到 C 内核
;
;  功能:
;   - BIOS 读取软盘/磁盘上的 kernel.bin 到 0x10000 (64KB)
;   - 设置 A20 地址线
;   - 建立 GDT (Global Descriptor Table)
;   - 切换到 32 位保护模式
;   - 跳到 0x10000 处的内核入口
;
;  编译: nasm -f bin boot.asm -o boot.bin
;========================================================

        BITS 16
        ORG 0x7c00

        jmp short start
        nop

start:
        ; ---- 初始化段寄存器与栈 ----
        cli
        mov ax, 0x0000
        mov ds, ax
        mov ss, ax
        mov sp, 0x7c00          ; 栈放在引导扇区之上
        sti

        ; ---- 保存引导盘号 (DL = BIOS 传入) ----
        mov [BOOT_DRIVE], dl

        ; ---- 打印开机信息 (BIOS 中断) ----
        mov si, MSG_BOOT
        call print_string

        ; ---- 加载内核到 0x10000 ----
        ; ES:BX = 目标地址, 使用 BIOS int 0x13 AH=02 读扇区
        mov ax, 0x1000
        mov es, ax
        xor bx, bx              ; ES:BX = 0x10000
        mov ah, 0x02            ; 读扇区功能
        mov al, KERNEL_SECTORS  ; 读取的扇区数
        mov ch, 0x00            ; 柱面 0
        mov cl, 0x02            ; 扇区 2 (引导扇区是扇区1)
        mov dh, 0x00            ; 磁头 0
        mov dl, [BOOT_DRIVE]    ; 磁盘号
        int 0x13
        jc disk_error           ; 出错则跳转

        ; ---- 加载完成 ----
        mov si, MSG_LOADED
        call print_string

        ; ---- 切换到 32 位模式 ----
        cli
        call enable_a20          ; 打开 A20
        lgdt [gdt_descriptor]   ; 加载 GDT
        mov eax, cr0
        or al, 1                ; 设置保护模式标志
        mov cr0, eax
        jmp CODE_SEG:init32     ; 跳转到 32 位代码

;----------------------------------------
; 错误处理
;----------------------------------------
disk_error:
        mov si, MSG_DISK_ERR
        call print_string
        jmp $                   ; 死循环

enable_a20:
        ; BIOS 方式
        mov ax, 0x2401
        int 0x15
        ret

;----------------------------------------
; 打印字符串 (0x0E TTY 模式)
;   SI = 字符串地址, 以 0 结尾
;----------------------------------------
print_string:
        pusha
.loop:
        lodsb
        or al, al
        jz .done
        mov ah, 0x0e
        mov bh, 0x00
        int 0x10
        jmp .loop
.done:
        popa
        ret

;----------------------------------------
; 32 位保护模式
;----------------------------------------
        BITS 32
init32:
        mov ax, DATA_SEG       ; 数据段选择子
        mov ds, ax
        mov es, ax
        mov fs, ax
        mov gs, ax
        mov ss, ax
        mov esp, 0x90000       ; 栈顶 (内核下方)

        ; 跳转到 C 内核 (位于 0x10000)
        mov eax, KERNEL_OFFSET
        call eax
        hlt                    ; 若内核返回则停机

        jmp $

;----------------------------------------
; 数据区
;----------------------------------------
KERNEL_OFFSET   equ 0x10000
KERNEL_SECTORS  equ 64         ; 64 个扇区 (32KB), 足够放精简内核
BOOT_DRIVE      db 0

MSG_BOOT        db "MiniOS booting...", 0x0D, 0x0A, 0
MSG_LOADED      db "Kernel loaded to 0x10000, entering protected mode...", 0x0D, 0x0A, 0
MSG_DISK_ERR    db "DISK ERROR! Could not load kernel.", 0

;----------------------------------------
; GDT (Global Descriptor Table)
;----------------------------------------
CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

gdt_start:
        dq 0x0                 ; 空描述符

gdt_code:
        dw 0xffff              ; 段限长 low
        dw 0x0000              ; 基址 low
        db 0x00                ; 基址 mid
        db 0x9a                ; 访问字节: Present, DPL0, 代码段, 可读可执行
        db 0xcf                ; 标志: 4K粒度, 32位
        db 0x00                ; 基址 high

gdt_data:
        dw 0xffff
        dw 0x0000
        db 0x00
        db 0x92                ; 访问字节: 数据段, 可读写
        db 0xcf
        db 0x00

gdt_end:

gdt_descriptor:
        dw gdt_end - gdt_start - 1   ; GDT 长度-1
        dd gdt_start                 ; GDT 基址

;----------------------------------------
; 填充 MBR 签名
;----------------------------------------
        TIMES 510-($-$$) db 0
        dw 0xAA55             ; 引导签名