;============================================================
;  MiniOS - 精简内核 (纯 NASM 汇编, 32位保护模式)
;
;  编译: nasm -f bin kernel.asm -o kernel.bin
;  加载: 由 boot.bin 从磁盘读到 0x10000 (最多32KB)
;
;  功能: VGA文本模式 + PIT定时器 + 键盘IRQ + 简单shell
;  中断: 不重映射PIC, 沿用BIOS默认向量 IRQ0->0x08, IRQ1->0x09
;============================================================

        BITS 32
        ORG 0x10000

;------------------------------------------------------------
; 内核入口
;------------------------------------------------------------
start:
        ; 建立自己的实地址寻址指针 (保护模式下 base=0)
        mov byte [current_color], 0x1F    ; 白字蓝底

        ; ---- 中断模型: 不重映射 PIC, 沿用 BIOS 默认向量 ----
        ;   IRQ0(定时器) -> 0x08, IRQ1(键盘) -> 0x09
        ;   注: 0x08 亦为 #DF 硬件向量, 调试期由定时器处理顶替

        ; ---- 初始化 PIT 定时器 100Hz ----
        call init_timer

        ; ---- 初始化键盘 ----
        call clear_kb_buf

        ; ---- 设置 IDT ----
        call setup_idt
        lidt [idt_descriptor]

        ; ---- 初始化内存文件系统 ----
        call fs_init

        ; ---- 启动画面 ----
        call clear_screen
        mov esi, MSG_LOGO
        mov byte [current_color], 0x0E    ; 黄字
        call print_string
        mov esi, MSG_BANNER
        mov byte [current_color], 0x0B    ; 青字
        call print_string
        mov esi, MSG_HINT
        mov byte [current_color], 0x07    ; 灰字
        call print_string

        ; ---- 打开中断 ----
        sti

        ; ---- 提示符 ----
        call print_prompt

;------------------------------------------------------------
; 主循环: 等待键盘中断处理
;------------------------------------------------------------
main_loop:
        hlt
        jmp main_loop

;------------------------------------------------------------
; clear_screen: 填充 80x25 VGA 文本区
;------------------------------------------------------------
clear_screen:
        pusha
        mov edi, VIDEO_MEM
        mov ecx, 1000
        mov eax, 0x07200720
        rep stosd
        mov dword [cursor_pos], 0
        popa
        ret

;------------------------------------------------------------
; print_string: 输出以0结尾字符串
;   ESI = 地址, [current_color] = 颜色
;------------------------------------------------------------
print_string:
        pusha
.loop:
        lodsb
        or al, al
        jz .done
        cmp al, 0x0A
        je .nl
        call print_char
        jmp .loop
.nl:
        call print_newline
        jmp .loop
.done:
        popa
        ret

;------------------------------------------------------------
; print_char: AL = 字符, [current_color] = 颜色
;------------------------------------------------------------
print_char:
        pusha
        movzx ebx, byte [current_color]
        mov edi, VIDEO_MEM
        add edi, [cursor_pos]
        mov ah, bl
        mov [edi], ax
        mov eax, [cursor_pos]
        add eax, 2
        mov [cursor_pos], eax
        popa
        ret

print_newline:
        pusha
        mov eax, [cursor_pos]
        mov ecx, 160
        xor edx, edx
        div ecx
        inc eax
        imul eax, ecx
        mov [cursor_pos], eax
        popa
        ret

;------------------------------------------------------------
; 串口调试输出 (COM1, 8N1, 仅TX)
;------------------------------------------------------------
serial_putc:
        push ax
        push bx
        push dx
        mov bh, al            ; 保存要发送的字符
.s1:
        mov dx, 0x3F8 + 5     ; LSR
        in al, dx
        test al, 0x20         ; THR 空?
        jz .s1
        mov dx, 0x3F8
        mov al, bh
        out dx, al            ; 发送字符
        pop dx
        pop bx
        pop ax
        ret

serial_puts:                  ; ESI -> 串口零结尾字符串
        push ax
        push esi
.l:
        lodsb
        or al, al
        jz .d
        call serial_putc
        jmp .l
.d:
        pop esi
        pop ax
        ret

serial_hex8:                  ; EAX -> 8个十六进制字符
        push eax
        push ecx
        push edx
        mov ecx, 8
.m:
        mov edx, eax
        shr edx, 28
        rol eax, 4
        mov al, dl
        and al, 0x0F
        cmp al, 9
        jbe .n
        add al, 7
.n:
        add al, '0'
        call serial_putc
        dec ecx
        jnz .m
        pop edx
        pop ecx
        pop eax
        ret

serial_raw8:                  ; ESI -> 最多8个原始字节
        push eax
        push ecx
        push esi
        mov ecx, 8
.l:
        mov al, [esi]
        test al, al
        jz .d
        cmp al, ' '
        je .d
        call serial_putc
        inc esi
        loop .l
.d:
        pop esi
        pop ecx
        pop eax
        ret

serial_dump_bytes:            ; ESI=addr, ECX=count: 每字节"XX "
        push eax
        push ebx
        push ecx
        push edx
        xor edx, edx
.l:
        cmp edx, ecx
        jge .done
        mov al, [esi]
        mov bh, al
        shr al, 4
        call serial_hex1
        mov al, bh
        and al, 0x0F
        call serial_hex1
        mov al, ' '
        call serial_putc
        inc esi
        inc edx
        jmp .l
.done:
        mov al, 0x0D
        call serial_putc
        mov al, 0x0A
        call serial_putc
        pop edx
        pop ecx
        pop ebx
        pop eax
        ret

serial_hex1:
        cmp al, 9
        jbe .n
        add al, 7
.n:
        add al, '0'
        call serial_putc
        ret

;------------------------------------------------------------
; PIT 定时器: 100Hz (divisor = 1193180/100 = 11932)
;------------------------------------------------------------
init_timer:
        pusha
        mov al, 0x36
        out 0x43, al
        mov ax, 11932
        out 0x40, al
        mov al, ah
        out 0x40, al
        popa
        ret

;------------------------------------------------------------
; 清空键盘缓冲
;------------------------------------------------------------
clear_kb_buf:
        pusha
.check:
        in al, 0x64
        test al, 1
        jz .done
        in al, 0x60
        jmp .check
.done:
        popa
        ret

;------------------------------------------------------------
; IDT 设置
;------------------------------------------------------------
setup_idt:
        pusha
        ; 零填充 IDT
        mov edi, idt_entries
        mov ecx, 256
        xor eax, eax
        mov ebx, 8
.zero:
        mov [edi], eax
        add edi, ebx
        loop .zero

        ; 装 3 个中断向量
        mov eax, isr_default
        mov ebx, 0x00
        call set_idt_entry

        ; 定时器 IRQ0 -> 0x08 (BIOS/PIC 默认向量)
        mov eax, irq0_handler
        mov ebx, 0x08
        call set_idt_entry

        ; 键盘 IRQ1 -> 0x09 (BIOS/PIC 默认向量)
        mov eax, irq1_handler
        mov ebx, 0x09
        call set_idt_entry

        ; 故障向量: #GP(13) -> 串口打印后停机 (调试用)
        mov eax, gp_handler
        mov ebx, 0x0D
        call set_idt_entry

        popa
        ret

; 设置 IDT 条目
;   eax = 处理函数地址, ebx = 向量号
set_idt_entry:
        push eax
        push ebx
        ; idt_entries + 向量号*8
        mov edi, idt_entries
        mov ecx, ebx
        shl ecx, 3
        add edi, ecx

        ; offset 低16位
        mov ecx, eax
        and ecx, 0xFFFF
        mov word [edi], cx
        ; 段选择子 0x08
        mov word [edi+2], 0x08
        ; 标志: 中断门 DPL0
        mov byte [edi+4], 0x8E
        ; 保留/QEMU 兼容: QEMU 11.1 从 byte5 取 gate 的 type/P 位,
        ; 而真实 x86 忽略 byte5 -> 同时写入令两边都有效
        mov byte [edi+5], 0x8E
        ; offset 高16位
        shr eax, 16
        mov word [edi+6], ax
        pop ebx
        pop eax
        ret

;------------------------------------------------------------
; 中断处理函数
;------------------------------------------------------------
isr_default:
        pusha
        ; 忽略
        popa
        iret

irq0_handler:
        pusha
        inc dword [timer_ticks]
        mov al, 0x20
        out 0x20, al            ; EOI
        popa
        iret

irq1_handler:
        pusha
        in al, 0x60             ; 扫描码
        test al, 0x80
        jnz .eoi
        mov [last_scan], al
        call handle_key
.eoi:
        mov al, 0x20
        out 0x20, al
        popa
        iret

;------------------------------------------------------------
; #DF / #GP 故障处理器: 串口打印后停机 (调试用)
;------------------------------------------------------------
gp_handler:
        push dword 0x0D
        jmp fault_common
fault_common:
        pusha
        ; [esp+32]=向量号, [esp+36]=错误码(#GP)或EIP(#DF), [esp+40]=EIP(#GP)
        mov esi, SDBG_FAULT
        call serial_puts
        mov eax, [esp+32]
        call serial_hex8
        mov esi, SDBG_E
        call serial_puts
        mov eax, [esp+36]
        call serial_hex8
        mov esi, SDBG_S
        call serial_puts
        mov eax, [esp+40]
        call serial_hex8
        mov si, SDBG_NL
        call serial_puts
        jmp $

;------------------------------------------------------------
; handle_key: 扫描码 -> 输入处理
;------------------------------------------------------------
handle_key:
        pusha

        movzx eax, byte [last_scan]

        ; 回车 (0x1C)
        cmp al, 0x1C
        je .enter

        ; 退格 (0x0E) - 简化处理, 清命令
        cmp al, 0x0E
        je .enter

        ; 只接受字母数字区 + 空格 (0x02-0x39), 用表转换
        cmp al, 0x39
        ja .done
        movzx eax, al
        mov bl, [scan_table + eax]
        cmp bl, 0
        je .done

        ; 加入到命令缓冲
        mov ecx, [cmd_len]
        cmp ecx, 63
        jae .done
        mov edi, cmd_buffer
        add edi, ecx
        mov [edi], bl
        inc dword [cmd_len]

        ; 打印字符
        mov al, bl
        call print_char

        jmp .done

.enter:
        call print_newline
        call execute_command
        call print_prompt

.done:
        popa
        ret

;------------------------------------------------------------
; print_prompt
;------------------------------------------------------------
print_prompt:
        pusha
        mov esi, MSG_PROMPT
        mov byte [current_color], 0x0B
        call print_string
        ; 清命令缓冲
        mov dword [cmd_len], 0
        mov edi, cmd_buffer
        mov ecx, 64
        xor eax, eax
        rep stosb
        popa
        ret

;------------------------------------------------------------
; execute_command
;------------------------------------------------------------
execute_command:
        pusha

        mov eax, [cmd_len]
        cmp eax, 0
        je .done

        ; help
        lea esi, [cmd_buffer]
        lea edi, [CMD_HELP]
        call str_cmp
        je .cmd_help

        lea esi, [cmd_buffer]
        lea edi, [CMD_ABOUT]
        call str_cmp
        je .cmd_about

        lea esi, [cmd_buffer]
        lea edi, [CMD_INFO]
        call str_cmp
        je .cmd_info

        lea esi, [cmd_buffer]
        lea edi, [CMD_CLEAR]
        call str_cmp
        je .cmd_clear

        lea esi, [cmd_buffer]
        lea edi, [CMD_UPTIME]
        call str_cmp
        je .cmd_uptime

        lea esi, [cmd_buffer]
        lea edi, [CMD_HELLO]
        call str_cmp
        je .cmd_hello

        lea esi, [cmd_buffer]
        lea edi, [CMD_REBOOT]
        call str_cmp
        je .cmd_reboot

        lea esi, [cmd_buffer]
        lea edi, [CMD_VER]
        call str_cmp
        je .cmd_ver

        lea esi, [cmd_buffer]
        lea edi, [CMD_DATE]
        call str_cmp
        je .cmd_date

        lea esi, [cmd_buffer]
        lea edi, [CMD_TICKS]
        call str_cmp
        je .cmd_ticks

        lea esi, [cmd_buffer]
        lea edi, [CMD_CLS]
        call str_cmp
        je .cmd_cls

        lea esi, [cmd_buffer]
        lea edi, [CMD_LOGO]
        call str_cmp
        je .cmd_logo

        lea esi, [cmd_buffer]
        lea edi, [CMD_WHOAMI]
        call str_cmp
        je .cmd_whoami

        lea esi, [cmd_buffer]
        lea edi, [CMD_SHUTDOWN]
        call str_cmp
        je .cmd_shutdown

        ; echo 需要前缀匹配 ("echo <text>")
        lea esi, [cmd_buffer]
        lea edi, [CMD_ECHO]
        call str_cmp_pref
        je .cmd_echo

        ; ---- 文件系统命令 ----
        lea esi, [cmd_buffer]
        lea edi, [CMD_PWD]
        call str_cmp
        je .cmd_pwd

        lea esi, [cmd_buffer]
        lea edi, [CMD_LS]
        call str_cmp
        je .cmd_ls

        lea esi, [cmd_buffer]
        lea edi, [CMD_CD]
        call str_cmp_pref
        je .cmd_cd

        lea esi, [cmd_buffer]
        lea edi, [CMD_MKDIR]
        call str_cmp_pref
        je .cmd_mkdir

        lea esi, [cmd_buffer]
        lea edi, [CMD_TOUCH]
        call str_cmp_pref
        je .cmd_touch

        lea esi, [cmd_buffer]
        lea edi, [CMD_RM]
        call str_cmp_pref
        je .cmd_rm

        lea esi, [cmd_buffer]
        lea edi, [CMD_WRITE]
        call str_cmp_pref
        je .cmd_write

        lea esi, [cmd_buffer]
        lea edi, [CMD_CAT]
        call str_cmp_pref
        je .cmd_cat

        ; 未知
        mov esi, MSG_UNKNOWN
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

.cmd_help:
        mov esi, MSG_HELP_FULL
        mov byte [current_color], 0x0B
        call print_string
        jmp .done

.cmd_about:
        mov esi, MSG_ABOUT
        mov byte [current_color], 0x0A
        call print_string
        jmp .done

.cmd_info:
        mov esi, MSG_INFO
        mov byte [current_color], 0x0A
        call print_string
        jmp .done

.cmd_clear:
        call clear_screen
        jmp .done

.cmd_uptime:
        call print_uptime
        jmp .done

.cmd_hello:
        mov esi, MSG_HELLO
        mov byte [current_color], 0x0E
        call print_string
        jmp .done

.cmd_reboot:
        mov al, 0xFE
        out 0x64, al
        jmp $
        jmp .done

.cmd_ver:
        mov esi, MSG_VER
        mov byte [current_color], 0x0E
        call print_string
        jmp .done

.cmd_date:
        call print_date
        jmp .done

.cmd_ticks:
        mov byte [current_color], 0x0A
        mov esi, MSG_TICKS_PREFIX
        call print_string
        mov eax, [timer_ticks]
        call print_udec_eax
        mov esi, MSG_TICKS_SUFFIX
        call print_string
        jmp .done

.cmd_cls:
        call clear_screen
        jmp .done

.cmd_logo:
        mov esi, MSG_LOGO
        mov byte [current_color], 0x0E
        call print_string
        jmp .done

.cmd_whoami:
        mov esi, MSG_WHOAMI
        mov byte [current_color], 0x0A
        call print_string
        jmp .done

.cmd_shutdown:
        mov dx, 0x604           ; QEMU i440fx: PIIX3 PM 控制端口
        mov ax, 0x2000          ; SLP_EN (soft off)
        out dx, ax
        jmp .done

.cmd_echo:
        lea esi, [cmd_buffer]
        add esi, 5              ; "echo" + 空格
        mov al, [esi]
        test al, al
        jz .echo_usage
        mov byte [current_color], 0x0A
        call print_string
        jmp .done
.echo_usage:
        mov esi, MSG_ECHO_USAGE
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

; ---- 文件系统命令处理 ----
.cmd_pwd:
        mov byte [current_color], 0x0A
        mov esi, MSG_PWD_PREFIX
        call print_string
        call pwd_dump
        mov esi, MSG_NL2
        call print_string
        jmp .done

.cmd_ls:
        call list_dir
        jmp .done

.cmd_cd:
        call cmd_arg
        mov al, [esi]
        test al, al
        jz .cd_root
        call fs_resolve
        cmp eax, -1
        je .cd_nf
        imul ebx, eax, FS_ENT_SZ
        cmp byte [fs_ents+ebx+FS_E_TYPE], FS_DIR
        jne .cd_nd
        mov [fs_cwd], eax
        jmp .done
.cd_root:
        mov dword [fs_cwd], 0
        jmp .done
.cd_nf:
        mov esi, MSG_ERR_NF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.cd_nd:
        mov esi, MSG_ERR_ND
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

.cmd_mkdir:
        call cmd_arg
        mov al, [esi]
        test al, al
        jz .mk_arg
        mov ebx, FS_DIR
        call create_entry
        jmp .done
.mk_arg:
        mov esi, MSG_ERR_ARG
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

.cmd_touch:
        call cmd_arg
        mov al, [esi]
        test al, al
        jz .mk_arg
        mov ebx, FS_FILE
        call create_entry
        jmp .done

.cmd_rm:
        call cmd_arg
        mov al, [esi]
        test al, al
        jz .rm_arg
        call fs_resolve
        cmp eax, -1
        je .rm_nf
        cmp eax, 0
        je .rm_root
        ; 目录非空检查
        imul ebx, eax, FS_ENT_SZ
        cmp byte [fs_ents+ebx+FS_E_TYPE], FS_DIR
        jne .rm_free
        push eax
        mov esi, eax
        mov ecx, FS_MAX_ENT
        mov edx, 1
.rm_scan:
        cmp edx, ecx
        jge .rm_empty
        imul ebx, edx, FS_ENT_SZ
        cmp dword [fs_ents+ebx+FS_E_PARENT], esi
        jne .rm_next
        cmp byte [fs_ents+ebx+FS_E_NAME], 0
        jne .rm_notempty
.rm_next:
        inc edx
        jmp .rm_scan
.rm_empty:
        pop eax
.rm_free:
        imul ebx, eax, FS_ENT_SZ
        mov byte [fs_ents+ebx+FS_E_NAME], 0
        mov dword [fs_ents+ebx+FS_E_PARENT], -1
        jmp .done
.rm_notempty:
        pop eax
        mov esi, MSG_ERR_NEMPTY
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.rm_nf:
        mov esi, MSG_ERR_NF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.rm_root:
        mov esi, MSG_ERR_ROOT
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.rm_arg:
        mov esi, MSG_ERR_ARG
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

.cmd_cat:
        call cmd_arg
        mov al, [esi]
        test al, al
        jz .ct_arg
        call fs_resolve
        cmp eax, -1
        je .ct_nf
        imul ebx, eax, FS_ENT_SZ
        cmp byte [fs_ents+ebx+FS_E_TYPE], FS_FILE
        jne .ct_isf
        mov byte [current_color], 0x0A
        call fs_cat
        mov esi, MSG_NL2
        call print_string
        jmp .done
.ct_arg:
        mov esi, MSG_ERR_ARG
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.ct_nf:
        mov esi, MSG_ERR_NF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.ct_isf:
        mov esi, MSG_ERR_ISF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

.cmd_write:
        call cmd_arg
        mov al, [esi]
        test al, al
        jz .wr_arg
        ; 分解 "文件 内容"
        mov edi, esi
.wr_find:
        cmp byte [edi], ' '
        je .wr_b
        cmp byte [edi], 0
        je .wr_b
        inc edi
        jmp .wr_find
.wr_b:
        cmp edi, esi
        je .wr_arg
        mov byte [edi], 0        ; 名字截止
        inc edi
.wr_s:
        cmp byte [edi], ' '
        jne .wr_done
        inc edi
        jmp .wr_s
.wr_done:
        cmp byte [edi], 0
        je .wr_arg
        mov [fs_tmp_content], edi
        mov ecx, 0
        mov edx, edi
.wr_len:
        cmp byte [edx], 0
        je .wr_len_done
        inc edx
        inc ecx
        jmp .wr_len
.wr_len_done:
        mov [fs_tmp_len], ecx
        ; 解析父目录 + 名字 (esi = 名路径)
        call split_last_comp
        cmp eax, -1
        je .wr_nf
        cmp eax, -2
        je .wr_nd
        mov [fs_tmp_parent], eax
        mov esi, edi
        cmp byte [esi], 0
        je .wr_arg
        ; 已存在?
        mov eax, [fs_tmp_parent]
        call fs_find_child
        cmp eax, -1
        je .wr_mk
        imul ebx, eax, FS_ENT_SZ
        cmp byte [fs_ents+ebx+FS_E_TYPE], FS_FILE
        jne .wr_isf
        jmp .wr_got
.wr_mk:
        mov eax, [fs_tmp_parent]
        mov ebx, FS_FILE
        call fs_mkentry
        cmp eax, -2
        je .wr_ex
        cmp eax, -1
        je .wr_full
.wr_got:
        mov esi, [fs_tmp_content]
        mov ecx, [fs_tmp_len]
        call fs_write_data
        cmp eax, -1
        je .wr_df
        jmp .done
.wr_arg:
        mov esi, MSG_ERR_WARG
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.wr_nf:
        mov esi, MSG_ERR_NF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.wr_nd:
        mov esi, MSG_ERR_ND
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.wr_isf:
        mov esi, MSG_ERR_ISF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.wr_ex:
        mov esi, MSG_ERR_EX
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.wr_full:
        mov esi, MSG_ERR_FULL
        mov byte [current_color], 0x0C
        call print_string
        jmp .done
.wr_df:
        mov esi, MSG_ERR_DF
        mov byte [current_color], 0x0C
        call print_string
        jmp .done

.done:
        popa
        ret

;------------------------------------------------------------
; print_uptime: 显示运行秒数
;------------------------------------------------------------
print_uptime:
        pusha
        mov esi, MSG_UPTIME_PREFIX
        mov byte [current_color], 0x0A
        call print_string

        ; ticks -> 秒 (100Hz)
        mov eax, [timer_ticks]
        mov ebx, 100
        xor edx, edx
        div ebx
        ; 现在 eax = 秒
        call print_udec_eax

        mov esi, MSG_UPTIME_SUFFIX
        mov byte [current_color], 0x0A
        call print_string
        popa
        ret

;------------------------------------------------------------
; print_udec_eax: 打印 EAX 的无符号十进制数
;------------------------------------------------------------
print_udec_eax:
        pusha
        xor ecx, ecx
        mov ebx, 10
.div:
        xor edx, edx
        div ebx
        push edx
        inc ecx
        test eax, eax
        jnz .div
.disp:
        pop edx
        add dl, '0'
        mov al, dl
        call print_char
        loop .disp
        popa
        ret

;------------------------------------------------------------
; print_dec2: 打印 AL (0-99) 的两位零填充十进制
;------------------------------------------------------------
print_dec2:
        pushad
        movzx eax, al
        xor edx, edx
        mov ebx, 10
        div ebx            ; EAX=十位, EDX=个位
        add eax, '0'
        add edx, '0'
        mov ecx, edx
        call print_char
        mov al, cl
        call print_char
        popad
        ret

;------------------------------------------------------------
; cmos_read: 读取一个 CMOS 寄存器, AL=寄存器号, 返回 AL=二进制值
;   (禁用 NMI; BCD 根据 [cmos_bin] 自动转换; cmos_bin 非0=二进制)
;------------------------------------------------------------
cmos_read:
        push ebx
        push edx
        or al, 0x80
        out 0x70, al
        in al, 0x71
        cmp byte [cmos_bin], 0
        jne .done
        ; BCD -> 二进制
        movzx ebx, al
        mov edx, ebx
        shr ebx, 4
        imul ebx, ebx, 10
        and edx, 0x0F
        add ebx, edx
        mov al, bl
.done:
        pop edx
        pop ebx
        ret

;------------------------------------------------------------
; print_date: 读取 CMOS RTC 并打印 YYYY-MM-DD HH:MM:SS
;------------------------------------------------------------
print_date:
        pusha
        ; 检测 RTC 模式: 寄存器 B 的 bit2 (0=BCD, 1=二进制)
        mov al, 0x0B
        or al, 0x80
        out 0x70, al
        in al, 0x71
        and al, 0x04
        mov [cmos_bin], al

        mov esi, MSG_DATE_PREFIX
        mov byte [current_color], 0x0A
        call print_string

        mov al, 0x32    ; century
        call cmos_read
        call print_dec2
        mov al, 0x09    ; year
        call cmos_read
        call print_dec2
        mov al, '-'
        call print_char
        mov al, 0x08    ; month
        call cmos_read
        call print_dec2
        mov al, '-'
        call print_char
        mov al, 0x07    ; day
        call cmos_read
        call print_dec2
        mov al, ' '
        call print_char
        mov al, 0x04    ; hour
        call cmos_read
        call print_dec2
        mov al, ':'
        call print_char
        mov al, 0x02    ; minute
        call cmos_read
        call print_dec2
        mov al, ':'
        call print_char
        mov al, 0x00    ; second
        call cmos_read
        call print_dec2

        mov esi, MSG_NEWLINE
        mov byte [current_color], 0x0A
        call print_string
        popa
        ret

;------------------------------------------------------------
; str_cmp: ESI/EDI 指向字符串, 相等则 ZF=1
;------------------------------------------------------------
str_cmp:
        push esi
        push edi
.loop:
        mov al, [esi]
        mov bl, [edi]
        cmp al, bl
        jne .ne
        cmp al, 0
        je .eq
        inc esi
        inc edi
        jmp .loop
.ne:
        pop edi
        pop esi
        or eax, 0x01
        ret
.eq:
        pop edi
        pop esi
        xor eax, eax
        ret

;------------------------------------------------------------
; str_cmp_pref: ESI 以 EDI 为前缀则相等(ZF=1)。
;   EDI 耗尽时, ESI 处必须是 ' ' 或 0 才算匹配。
;------------------------------------------------------------
str_cmp_pref:
        push esi
        push edi
.loop:
        mov al, [esi]
        mov bl, [edi]
        cmp bl, 0
        je .checksep
        cmp al, bl
        jne .ne
        inc esi
        inc edi
        jmp .loop
.checksep:
        cmp al, ' '
        je .eq
        cmp al, 0
        je .eq
.ne:
        pop edi
        pop esi
        or eax, 0x01
        ret
.eq:
        pop edi
        pop esi
        xor eax, eax
        ret

;============================================================
; 内存文件系统 (ramfs)
;============================================================
FS_MAX_ENT    equ 128
FS_DATA_SIZE  equ 8192
FS_E_NAME     equ 0
FS_E_TYPE     equ 11
FS_E_SIZE     equ 12
FS_E_PARENT   equ 16
FS_E_DATA     equ 20
FS_ENT_SZ     equ 32
FS_DIR        equ 1
FS_FILE       equ 2

; 初始化: 建立根目录
fs_init:
        pusha
        mov byte [fs_ents+FS_E_NAME], '/'
        mov byte [fs_ents+FS_E_TYPE], FS_DIR
        mov dword [fs_ents+FS_E_PARENT], -1
        mov dword [fs_ents+FS_E_SIZE], 0
        mov dword [fs_ents+FS_E_DATA], 0
        mov dword [fs_cwd], 0
        mov dword [fs_data_free], 0
        mov ebx, [fs_cwd]
        mov esi, DBG_CWD
        call serial_puts
        mov eax, ebx
        call serial_hex8
        mov esi, DBG_NL
        call serial_puts
        mov eax, 0x12345678
        mov esi, DBG_LIT
        call serial_puts
        call serial_hex8
        mov esi, DBG_NL
        call serial_puts
        mov esi, DBG_CHR
        call serial_puts
        mov edi, DBG_CHRS
.cc:
        mov al, [edi]
        test al, al
        jz .ccd
        call serial_putc
        inc edi
        jmp .cc
.ccd:
        mov esi, DBG_NL
        call serial_puts
        popa
        ret

; ESI-> 空字符串则返回当前目录, 否则解析路径
; 返回 EAX = 条目idx 或 -1
fs_resolve:
        push ebx
        push ecx
        push edx
        push esi
        mov al, [esi]
        cmp al, '/'
        jne .rel
        mov eax, 0
        jmp .skip_slashes
.rel:
        mov eax, [fs_cwd]
.skip_slashes:
        mov al, [esi]
        cmp al, '/'
        jne .main
        inc esi
        jmp .skip_slashes
.main:
        mov al, [esi]
        test al, al
        jz .retok
        cmp al, ' '
        je .retok
        call fs_read_component
        mov edx, esi            ; 保存路径指针 (str_cmp 会破坏 ebx 低字节, 不用 ebx)
        mov ecx, eax            ; 保存当前目录 (str_cmp 会破坏 eax)
        ; 特殊组件
        lea esi, [name_buf]
        lea edi, [FSN_DOTDOT]
        call str_cmp
        je .dotdot
        lea esi, [name_buf]
        lea edi, [FSN_DOT]
        call str_cmp
        je .dot
        cmp byte [name_buf], 0
        je .dot
        ; 普通组件: 查找子项
        lea esi, [name_buf]
        mov eax, ecx
        call fs_find_child
        cmp eax, -1
        je .nf
        jmp .adv
.dotdot:
        mov eax, ecx            ; 当前目录
        imul ebx, eax, FS_ENT_SZ
        cmp dword [fs_ents+ebx+FS_E_PARENT], -1
        je .adv                  ; 根目录的 '..' 不动
        mov eax, [fs_ents+ebx+FS_E_PARENT]
        jmp .adv
.dot:
        mov eax, ecx            ; '.' 或空组件: 保持当前目录
.adv:
        mov esi, edx
        jmp .skip_slashes
.retok:
        jmp .ret
.nf:
        mov eax, -1
.ret:
        pop esi
        pop edx
        pop ecx
        pop ebx
        ret

; 读取路径组件到 name_buf (<=11字符, 0结尾), ESI 停在分隔符
fs_read_component:
        push eax
        push ecx
        push edi
        lea edi, [name_buf]
        xor ecx, ecx
.loop:
        mov al, [esi]
        cmp al, '/'
        je .done
        cmp al, 0
        je .done
        cmp al, ' '
        je .done
        cmp ecx, 11
        jae .done
        mov [edi], al
        inc esi
        inc edi
        inc ecx
        jmp .loop
.done:
        mov byte [edi], 0
        pop edi
        pop ecx
        pop eax
        ret

DBG_FIND db "[F] parent=", 0
DBG_NM   db " name=", 0
DBG_HIT  db " hit=", 0
DBG_CWD  db "[C] fs_cwd=", 0
DBG_LIT  db "[L] lit=", 0
DBG_CHR  db "[C] chars=", 0
DBG_CHRS db "ABC0DEF89", 0
DBG_NL   db 0x0A, 0
; EAX=父目录, ESI=名字 -> EAX=子项idx 或 -1
fs_find_child:
        pusha
        mov esi, DBG_FIND
        call serial_puts
        mov eax, [esp+28]
        call serial_hex8
        mov esi, DBG_NM
        call serial_puts
        mov esi, [esp+4]
        call serial_raw8
        mov esi, DBG_NL
        call serial_puts
        popa
        push ebx
        push ecx
        push edx
        push esi            ; 名字
        push edi
        mov ecx, FS_MAX_ENT
        mov edx, 1
.loop:
        cmp edx, ecx
        jge .nf
        imul ebx, edx, FS_ENT_SZ
        add ebx, fs_ents
        cmp dword [ebx+FS_E_PARENT], eax
        jne .next
        cmp byte [ebx+FS_E_NAME], 0
        je .next
        push esi
        push edi
        push eax            ; 保护父目录 (str_cmp 的 .ne 会破坏 eax)
        mov esi, [esp+16]
        lea edi, [ebx+FS_E_NAME]
        call str_cmp
        pop eax
        pop edi
        pop esi
        jne .next
        mov eax, edx
        jmp .ret2
.next:
        inc edx
        jmp .loop
.nf:
        mov eax, -1
.ret2:
        push eax
        mov esi, DBG_HIT
        call serial_puts
        mov eax, [esp]
        call serial_hex8
        mov esi, DBG_NL
        call serial_puts
        pop eax
        pop edi
        pop esi
        pop edx
        pop ecx
        pop ebx
        ret

; -> EAX = 空闲条目idx 或 -1
fs_find_free:
        push ebx
        push ecx
        mov ecx, FS_MAX_ENT
        mov eax, 1
.loop:
        cmp eax, ecx
        jge .full
        imul ebx, eax, FS_ENT_SZ
        cmp byte [fs_ents+ebx+FS_E_NAME], 0
        je .ret
        inc eax
        jmp .loop
.full:
        mov eax, -1
.ret:
        pop ecx
        pop ebx
        ret

; EAX=父目录, EBX=类型, ESI=名字 -> EAX=new / -1满 / -2已存在
fs_mkentry:
        push ecx
        push edx
        push esi
        push edi
        mov ecx, eax            ; 父
        ; 同名检查
        call fs_find_child
        cmp eax, -1
        jne .exists
        call fs_find_free
        cmp eax, -1
        je .full
        imul edx, eax, FS_ENT_SZ
        lea edi, [fs_ents+edx+FS_E_NAME]
        push eax                ; 新idx
        xor edx, edx            ; 计数
.copy:
        cmp edx, 11
        jae .copied
        mov al, [esi]
        mov [edi], al
        test al, al
        jz .copied
        inc esi
        inc edi
        inc edx
        jmp .copy
.copied:
        pop eax
        imul edx, eax, FS_ENT_SZ
        mov [fs_ents+edx+FS_E_TYPE], bl
        mov dword [fs_ents+edx+FS_E_SIZE], 0
        mov [fs_ents+edx+FS_E_PARENT], ecx
        mov dword [fs_ents+edx+FS_E_DATA], 0
        jmp .ret
.exists:
        mov eax, -2
        jmp .ret
.full:
        mov eax, -1
.ret:
        pop edi
        pop esi
        pop edx
        pop ecx
        ret

; EAX=文件idx, ESI=数据, ECX=长度 -> EAX=0 或 -1(池满)
fs_write_data:
        push eax            ; idx @[esp+20]
        push ecx            ; len @[esp+16]
        push edx
        push ebx
        push esi
        push edi
        mov eax, [fs_data_free]
        mov edx, [esp+16]
        lea ebx, [eax+edx]
        cmp ebx, FS_DATA_SIZE
        ja .full
        mov ecx, [esp+20]
        imul ecx, ecx, FS_ENT_SZ
        add ecx, fs_ents
        mov [ecx+FS_E_DATA], eax
        mov [ecx+FS_E_SIZE], edx
        mov edi, fs_data
        add edi, eax
        mov esi, [esp+4]
        mov ecx, [esp+16]
.copy:
        test ecx, ecx
        jz .copied
        mov al, [esi]
        mov [edi], al
        inc esi
        inc edi
        dec ecx
        jmp .copy
.copied:
        mov eax, [esp+16]
        add [fs_data_free], eax
        xor eax, eax
        jmp .ret
.full:
        mov eax, -1
.ret:
        pop edi
        pop esi
        pop ebx
        pop edx
        pop ecx
        pop eax
        ret

; EAX=文件idx -> 打印内容
fs_cat:
        pusha
        imul ebx, eax, FS_ENT_SZ
        add ebx, fs_ents
        mov ecx, [ebx+FS_E_SIZE]
        mov esi, [ebx+FS_E_DATA]
        add esi, fs_data
        test ecx, ecx
        jz .done
.loop:
        mov al, [esi]
        call print_char
        inc esi
        dec ecx
        jnz .loop
.done:
        popa
        ret

; cmd_arg: ESI 指向 cmd_buffer 参数起点
cmd_arg:
        push ecx
        lea esi, [cmd_buffer]
.loop:
        mov al, [esi]
        test al, al
        jz .done
        cmp al, ' '
        je .found
        inc esi
        jmp .loop
.found:
        inc esi
        mov al, [esi]
        cmp al, ' '
        je .found
.done:
        pop ecx
        ret

; 分解 "父目录路径/名字": ESI=路径 -> EAX=父目录idx(是目录)或-1/-2, EDI=名字
;   -1 = 父路径不存在, -2 = 父不是目录
split_last_comp:
        push esi
        push ebx
        push ecx
        mov ecx, 0
        mov ebx, esi
.scan:
        cmp byte [ebx], 0
        je .scan_end
        cmp byte [ebx], '/'
        jne .skip
        mov ecx, ebx
.skip:
        inc ebx
        jmp .scan
.scan_end:
        mov esi, [esp+8]        ; 恢复路径起点
        test ecx, ecx
        jz .noslash
        mov byte [ecx], 0        ; 截断父路径
        call fs_resolve
        cmp eax, -1
        je .nf
        push eax
        imul ebx, eax, FS_ENT_SZ
        cmp byte [fs_ents+ebx+FS_E_TYPE], FS_DIR
        pop eax
        jne .ndret
        lea edi, [ecx+1]
        jmp .ret
.noslash:
        mov eax, [fs_cwd]
        push eax
        mov esi, DBG_CWD
        call serial_puts
        call serial_hex8
        mov esi, DBG_NL
        call serial_puts
        pop eax
        lea edi, [esi]
        jmp .ret
.nf:
        mov eax, -1
        jmp .ret
.ndret:
        mov eax, -2
.ret:
        pop ecx
        pop ebx
        pop esi
        ret

; 创建文件/目录: ESI=路径(名字为最后组件), EBX=类型
create_entry:
        push ebx           ; 类型 @[esp+...]
        push edi
        push esi
        call split_last_comp
        cmp eax, -1
        je .nf
        cmp eax, -2
        je .nd
        cmp byte [edi], 0
        je .arg
        mov ebx, [esp+8]    ; 类型 (push 顺序: esi,edi,ebx -> [esp+8])
        mov esi, edi        ; 名字
        call fs_mkentry
        cmp eax, -2
        je .ex
        cmp eax, -1
        je .full
        jmp .ret
.nf:
        mov esi, MSG_ERR_NF
        mov byte [current_color], 0x0C
        call print_string
        jmp .ret
.nd:
        mov esi, MSG_ERR_ND
        mov byte [current_color], 0x0C
        call print_string
        jmp .ret
.arg:
        mov esi, MSG_ERR_ARG
        mov byte [current_color], 0x0C
        call print_string
        jmp .ret
.ex:
        mov esi, MSG_ERR_EX
        mov byte [current_color], 0x0C
        call print_string
        jmp .ret
.full:
        mov esi, MSG_ERR_FULL
        mov byte [current_color], 0x0C
        call print_string
.ret:
        pop esi
        pop edi
        pop ebx
        ret

; pwd 输出路径 (自fs_cwd回溯到根)
pwd_dump:
        pusha
        mov eax, [fs_cwd]
        cmp eax, 0
        je .root
        mov ecx, 0
.collect:
        mov [pwd_idx + ecx*4], eax
        inc ecx
        imul ebx, eax, FS_ENT_SZ
        mov eax, [fs_ents+ebx+FS_E_PARENT]
        cmp eax, 0
        jne .collect
.print:
        dec ecx
        jl .done
        mov eax, [pwd_idx + ecx*4]
        imul ebx, eax, FS_ENT_SZ
        lea esi, [fs_ents+ebx+FS_E_NAME]
        call print_string
        mov al, '/'
        call print_char
        jmp .print
.root:
        mov al, '/'
        call print_char
.done:
        popa
        ret

; ls 输出当前目录
list_dir:
        pusha
        mov byte [current_color], 0x0A
        mov eax, [fs_cwd]
        mov edx, 1
.loop:
        cmp edx, FS_MAX_ENT
        jge .eol
        imul ebx, edx, FS_ENT_SZ
        add ebx, fs_ents
        cmp dword [ebx+FS_E_PARENT], eax
        jne .next
        cmp byte [ebx+FS_E_NAME], 0
        je .next
        mov esi, MSG_LS_PRE
        call print_string
        lea esi, [ebx+FS_E_NAME]
        call print_string
        ; 补齐到12列
        mov ecx, 0
        lea edi, [ebx+FS_E_NAME]
.lenl:
        cmp byte [edi], 0
        je .padl
        inc edi
        inc ecx
        jmp .lenl
.padl:
        cmp ecx, 12
        jge .pad_done
        mov al, ' '
        call print_char
        inc ecx
        jmp .padl
.pad_done:
        cmp byte [ebx+FS_E_TYPE], FS_DIR
        je .isdir
        mov esi, MSG_LS_FILE
        call print_string
        mov eax, [ebx+FS_E_SIZE]
        call print_udec_eax
        jmp .next
.isdir:
        mov esi, MSG_LS_DIR
        call print_string
.next:
        inc edx
        jmp .loop
.eol:
        mov esi, MSG_NL2
        call print_string
        popa
        ret

;------------------------------------------------------------
; 数据区
;------------------------------------------------------------
VIDEO_MEM      equ 0x000B8000

MSG_LOGO   db 0x0A, "  MiniOS v1.0 - tiny 32-bit OS", 0x0D, 0x0A
           db  "  by BG7OOC", 0x0D, 0x0A, 0

MSG_BANNER db 0x0A, "  Booting complete.", 0x0D, 0x0A
           db  "  Timer: 100Hz  all systems nominal", 0x0D, 0x0A, 0

MSG_HINT   db 0x0A, "  Type 'help' to see commands.", 0x0D, 0x0A, 0

MSG_HELP_FULL db 0x0A, "  Commands:", 0x0D, 0x0A
           db "    help     show commands", 0x0D, 0x0A
           db "    about    about MiniOS", 0x0D, 0x0A
           db "    ver      version info", 0x0D, 0x0A
           db "    info     system info", 0x0D, 0x0A
           db "    logo     print logo", 0x0D, 0x0A
           db "    whoami   who are you", 0x0D, 0x0A
           db "    date     current date/time", 0x0D, 0x0A
           db "    uptime   show uptime", 0x0D, 0x0A
           db "    ticks    raw timer ticks", 0x0D, 0x0A
           db "    echo     echo text", 0x0D, 0x0A
           db "    clear    clear screen", 0x0D, 0x0A
           db "    cls      alias of clear", 0x0D, 0x0A
           db "    hello    greeting", 0x0D, 0x0A
           db "    pwd      print working dir", 0x0D, 0x0A
           db "    ls       list directory", 0x0D, 0x0A
           db "    cd       change directory", 0x0D, 0x0A
           db "    mkdir    create directory", 0x0D, 0x0A
           db "    touch    create empty file", 0x0D, 0x0A
           db "    write    write file", 0x0D, 0x0A
           db "    cat      print file", 0x0D, 0x0A
           db "    rm       remove file/dir", 0x0D, 0x0A
           db "    shutdown power off", 0x0D, 0x0A
           db "    reboot   restart machine", 0x0D, 0x0A, 0

MSG_ABOUT db 0x0A, "  MiniOS is a tiny OS written in x86 assembly.", 0x0D, 0x0A
          db "  Runs in 32-bit protected mode.", 0x0D, 0x0A
          db "  Features: VGA, PIC, PIT, keyboard, shell.", 0x0D, 0x0A, 0

MSG_INFO db 0x0A, "  CPU      :  32-bit Protected Mode", 0x0D, 0x0A
         db "  Display  :  VGA Txt 80x25", 0x0D, 0x0A
         db "  Timer    :  PIT @100Hz", 0x0D, 0x0A
         db "  Keyboard :  IRQ1 PS/2", 0x0D, 0x0A
         db "  Kernel   :  0x10000", 0x0D, 0x0A, 0

MSG_HELLO  db 0x0A, "  Hello there! Have a nice day. =)", 0x0D, 0x0A, 0
MSG_VER    db 0x0A, "  MiniOS v1.0 - by BG7OOC (Sep 2026)", 0x0D, 0x0A, 0
MSG_WHOAMI db 0x0A, "  You are bg7ooc, owner of this tiny machine.", 0x0D, 0x0A, 0
MSG_ECHO_USAGE db 0x0A, "  Usage: echo <text>", 0x0D, 0x0A, 0
MSG_UNKNOWN db 0x0A, "  Unknown command. Type 'help'.", 0x0D, 0x0A, 0
MSG_PROMPT db "MiniOS> ", 0
MSG_NEWLINE db 0x0D, 0x0A, 0
SDBG_NL db 0
SDBG_FAULT db "[FAULT] vec=", 0
SDBG_E db " err=", 0
SDBG_S db " eip=", 0
MSG_UPTIME_PREFIX db 0x0A, "  Uptime: ", 0
MSG_UPTIME_SUFFIX db " seconds", 0x0D, 0x0A, 0
MSG_TICKS_PREFIX db 0x0A, "  Ticks: ", 0
MSG_TICKS_SUFFIX db " (100Hz)", 0x0D, 0x0A, 0
MSG_DATE_PREFIX db 0x0A, "  Date: ", 0

; 文件系统相关字符串 (只用 0x0A 换行, print_string 不处理 0x0D)
MSG_NL2       db 0x0A, 0
MSG_PWD_PREFIX db 0x0A, "  ", 0
MSG_LS_PRE    db 0x0A, "    ", 0
MSG_LS_FILE   db "  <file>  ", 0
MSG_LS_DIR    db "  <dir>", 0
FSN_DOTDOT    db "..", 0
FSN_DOT       db ".", 0
MSG_ERR_NF    db 0x0A, "  error: path not found", 0x0A, 0
MSG_ERR_ND    db 0x0A, "  error: not a directory", 0x0A, 0
MSG_ERR_ISF   db 0x0A, "  error: not a file", 0x0A, 0
MSG_ERR_EX    db 0x0A, "  error: name already exists", 0x0A, 0
MSG_ERR_FULL  db 0x0A, "  error: table is full", 0x0A, 0
MSG_ERR_NEMPTY db 0x0A, "  error: directory not empty", 0x0A, 0
MSG_ERR_ROOT  db 0x0A, "  error: cannot remove root", 0x0A, 0
MSG_ERR_DF    db 0x0A, "  error: data pool full", 0x0A, 0
MSG_ERR_ARG   db 0x0A, "  error: missing argument", 0x0A, 0
MSG_ERR_WARG  db 0x0A, "  Usage: write <file> <text>", 0x0A, 0

CMD_HELP   db "help", 0
CMD_ABOUT  db "about", 0
CMD_INFO   db "info", 0
CMD_CLEAR  db "clear", 0
CMD_UPTIME db "uptime", 0
CMD_HELLO  db "hello", 0
CMD_REBOOT db "reboot", 0
CMD_VER    db "ver", 0
CMD_DATE   db "date", 0
CMD_TICKS  db "ticks", 0
CMD_CLS    db "cls", 0
CMD_LOGO   db "logo", 0
CMD_WHOAMI db "whoami", 0
CMD_SHUTDOWN db "shutdown", 0
CMD_ECHO   db "echo", 0
CMD_PWD    db "pwd", 0
CMD_LS     db "ls", 0
CMD_CD     db "cd", 0
CMD_MKDIR  db "mkdir", 0
CMD_TOUCH  db "touch", 0
CMD_RM     db "rm", 0
CMD_WRITE  db "write", 0
CMD_CAT    db "cat", 0

; 扫描码 -> ASCII (US QWERTY, 前0x3A)
scan_table:
        db 0, 27, '1','2','3','4','5','6','7','8','9','0','-','='
        db 8, 9, 'q','w','e','r','t','y','u','i','o','p','[',']'
        db 13, 0, 'a','s','d','f','g','h','j','k','l',';',''''
        db '`', 0, '\','z','x','c','v','b','n','m',',','.','/'
        db 0, '*', 0, ' '

; 变量
current_color db 0x1F
cursor_pos    dd 0
cmd_len       dd 0
cmos_bin      db 0
timer_ticks   dd 0
last_scan     db 0
cmd_buffer    times 64 db 0

; 文件系统运行态
fs_cwd        dd 0
fs_data_free  dd 0
fs_tmp_parent dd 0
fs_tmp_content dd 0
fs_tmp_len    dd 0
name_buf      times 12 db 0
pwd_idx       times 32 dd 0
fs_ents       times FS_MAX_ENT*FS_ENT_SZ db 0
fs_data       times FS_DATA_SIZE db 0

;------------------------------------------------------------
; IDT: 放最后 (相对地址直接寻址, 位置固定)
;------------------------------------------------------------
align 8
idt_entries  times 256*8 db 0

idt_descriptor:
        dw 256*8 - 1
        dd idt_entries

; 填充到 32KB 边界 (boot 加载 64 扇区)
times (64*512 - ($-$$)) db 0