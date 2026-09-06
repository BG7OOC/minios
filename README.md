# MiniOS

一个用纯 NASM 汇编编写的 32 位精简操作系统（约 32KB 内核），可在 QEMU 中真实启动、运行、交互。

**作者：BG7OOC**

> 仅用于教育与授权的安全/系统研究。请勿用于未经授权的系统或设备。

## 功能

- **实模式引导**：`boot.bin` 通过 BIOS int 0x13 读取 64 个扇区（32KB）内核到 `0x10000`
- **保护模式**：A20 使能 + GDT + 跳转 0x10000 进入 32 位内核
- **VGA 文本显示**：1067 直写 `0xB8000` 文本缓冲区（80x25）
- **PIT 定时器**：100Hz 时钟，驱动 `uptime`
- **PS/2 键盘**：IRQ1，扫描码翻译，命令行 shell
- **Shell 命令**：`help` `about` `info` `clear` `uptime` `hello` `reboot`

## 目录结构

```
MINIOS/
├── src/
│   ├── boot.asm       # 16 位引导扇区（512B, 0xAA55）
│   └── kernel.asm     # 32 位内核（ORG 0x10000）
├── build/
│   ├── boot.bin       # 512 字节
│   ├── kernel.bin     # 32768 字节
│   └── minios.img     # 512 + 32768 = 33280 字节，可引导镜像
└── build.bat          # 一键构建并运行
```

## 构建与运行

需要 `nasm` 与 `qemu-system-i386`。路径可参照脚本内配置修改。

```bat
build.bat          :: 一条命令：编译 + 打包 + 启动 QEMU
```

或在命令行手动执行：

```bat
nasm -f bin src\boot.asm   -o build\boot.bin
nasm -f bin src\kernel.asm -o build\kernel.bin
copy /b build\boot.bin + build\kernel.bin build\minios.img
qemu-system-i386 -drive format=raw,file=build\minios.img
```

## 中断模型（调试中的关键结论）

- **不重映射 PIC**，沿用 BIOS 默认向量：IRQ0→int 0x08（定时器）、IRQ1→int 0x09（键盘）。对应向量 0x08 的 #DF 与定时器冲突，调试期可接受。
- **QEMU 兼容性**：QEMU 11.1.0 的 `do_interrupt_protected` 以门描述符 **byte5** 的低 5 位为类型、bit15 为 P。若 `set_idt_entry` 未写 byte5（保持 0x00），会判为 type=0 → 触发 `#GP(intno*8+2)` → #DF → triple fault。因此在 `set_idt_entry` 中把 `[edi+5]` 置为 `0x8E` 以兼容真实 x86（忽略 byte5）与 QEMU 双方。
- 软件 `int 0x20` 亦产生同样 `e=0x102` 的 `#GP`，证实故障根因在 IDT 门派发路径本身，而非硬件/PIC 投递。

## 验证手段

- 串口：`-serial file:serial.txt`（SeaBIOS 初始化 COM1 115200 8N1）
- QEMU monitor：`-monitor tcp:127.0.0.1:PORT,server,nowait`
  - `pmemsave` 导出 `0xB8000` 文本区网格核对
  - `sendkey` 注入键盘输入
- 已通过回归：boot banner、`help`、`uptime`（定时器计数）、`hello`、未知命令提示符，显示无偏移、串口干净。

## 命令

```
MiniOS> help
    Commands:
      help    show commands
      about   about MiniOS
      info    system info
      clear   clear screen
      uptime  show uptime
      hello   greeting
      reboot  restart machine
```