USB/IP  PC 端日志采集器
========================

用途
----
手机（HarmonyOS USB/IP 服务端）断开的时候，只看手机一侧的日志没法判断
到底是哪一边先断的。这个工具在电脑上持续记录下面这些变化，每条都带毫秒
时间戳，可以和手机 App 导出的日志拼成一条时间轴。

  tcp   本机到手机 3240 端口的 TCP 连接：建立、状态变化、消失
  port  虚拟端口状态（usbip port），只在变化时记
  proc  usbip.exe / wusbip.exe 进程出现与命令行（能看出是谁发起的 attach）
  net   网卡链路状态与速率
  wlan  WiFi 连接状态与信号强度（每变化 15 个百分点记一条）
  ping  到手机的 ICMP 可达性（对端 IP 从 TCP 连接自动学习）
  etw   驱动 WPP 跟踪（仅管理员模式）
  beat  每 10 秒一行心跳

不需要管理员权限。不修改任何设置，不碰设备，只做只读观测。


快速开始
--------
1) 双击 start-log.bat，窗口里开始滚动时间戳。

2) 照平常那样用：手机上打开设备开关，电脑上 usbip attach。
   然后复现问题（等它断、拔插、重连，随便折腾）。

3) 复现完之后：
   - 按 Ctrl+C，或者双击 stop-log.bat
   - 程序会自动调用 merge-logs.ps1 生成 merged.log

输出位置：
   C:\Users\<你>\usbip-log\logs\<日期-时间>\pc.log        原始记录
   C:\Users\<你>\usbip-log\logs\<日期-时间>\merged.log    合并后的时间轴 + 结论

把 merged.log 发出来就行。


把手机日志也合并进来
--------------------
merged.log 里只有电脑侧时，"app.log : (not provided)" 会写在那里。
三种方式把手机日志放进来：

  A. 手机点"复制日志"后，如果电脑剪贴板能收到（华为多屏协同 / 跨设备剪贴板），
     采集器每 10 秒检查一次剪贴板，发现内容像 App 日志就自动存成
     C:\Users\<你>\usbip-log\app.log，日志里会出现：
         [sys] app log picked up from clipboard -> ...\app.log

  B. 手动保存为 C:\Users\<你>\usbip-log\app.log
     （微信/QQ 传文件到电脑，或用手机助手导出，全选复制粘贴进记事本另存）

  C. 什么都不做，把 pc.log 和手机日志一起发出来，人工对齐也可以。

已经有 app.log 时，也可以在事后补跑合并，不用重新采集：

     powershell -NoProfile -ExecutionPolicy Bypass ^
       -File C:\Users\<你>\usbip-log\merge-logs.ps1 ^
       -PcLog "C:\Users\<你>\usbip-log\logs\20261122-201106\pc.log" ^
       -AppLog C:\Users\<你>\usbip-log\app.log


怎么看断开的结论
----------------
merged.log 末尾有一节 "what the timeline says"，里面每次断开都有一行：

    20:11:21.911  down  127.0.0.1:44310 last=FinWait2 => LOCAL-FIN  lived 2.7s

判定依据是断开瞬间本机 socket 停在哪个状态：

  LOCAL-FIN  停在 FinWait1 / FinWait2 / TimeWait
             => 是**电脑这边先关的**。客户端放弃了连接
                （驱动报错、进程被杀、或它认为链路不通）

  PEER-FIN   停在 CloseWait / LastAck
             => 是**手机那边先关的**。服务端主动断开了会话
                （保活超时、会话被接管、设备被移除）

  RST        没有 FIN 握手，socket 直接从 Established 消失
             => 异常终止。网络断了、或某一端被强制杀掉

后面还会跟一句 "lived Ns"，是这次连接存活了多久——用来判断问题是不是
集中在"连上十几分钟后才出"。

如果断开前后 8 秒内有 WiFi 掉线或 ping 失败，会追加提示：

    ... => PEER-FIN  lived 842.3s  + network event within 8s

有这一句，就要先怀疑 WiFi，而不是 USB/IP 本身。

其它小节：
  -- connect / disconnect sequence --   每次连接的建立与断开，带存活时长
  -- gap between a drop and the next connect --  断开后多久重连
  -- virtual port changes --            驱动侧端口状态变化
  -- wifi link / signal --              WiFi 状态与信号台阶
  -- clock skew candidates --           两侧时钟偏差参考


时钟偏差
--------
两份日志都用本机本地时间。如果两边都开了 NTP，误差通常在 1 秒以内。
merged.log 里的 "clock skew candidates" 会把电脑侧建连时刻和手机侧
[导入] 时刻配对，delta 如果几条都一致，那个数就是两边时钟的固定偏差，
读时间轴时按它校正即可。


管理员模式（可选）
------------------
用管理员身份运行 start-log.bat（右键 -> 以管理员身份运行）会多抓一份
驱动内部的 WPP 跟踪，存成 driver.etl / driver.xml。

说明：这份 trace 包含驱动内部的 URB 收发细节，但发布版驱动没有带 TMF
符号文件，所以 tracerpt 只能解出事件和时间戳，解不出可读文字。它对
"精确到微秒的事件密度分析"有用，日常判读靠 tcp/port/wlan 三路就够。


常见问题
--------
Q: 采集会不会干扰正在用的连接？
A: 不会。只做只读查询（Get-NetTCPConnection、usbip port、netsh、WMI），
   不打开设备、不发控制传输、不改注册表。ping 只打手机，不碰 3240 端口。

Q: 笔记本/台式机都行吗？
A: 都行。有线连接时 wlan 那一路不会有内容，其余照常。

Q: 能一直开着吗？
A: 可以。20 分钟大约产生 200 行左右。日志按天分目录，不会覆盖。

Q: 采集器忘了停就关机了怎么办？
A: 文件是逐行落盘的，随时可以拿出来用。只是不会自动合并，手动跑一次
   merge-logs.ps1 即可。


reset-usbip.bat（连接坏了先跑这个）
----------------------------------
用途：把 PC 侧所有已 import 的虚拟端口全部 detach 掉，等 3 秒，再按手机端
实际导出的 busid 重新 attach 一次。

为什么需要它：usbip-win2 的 UDE 驱动给每次 attach 分配一个虚拟 Port。如果
上一次会话是被"掐断"的（不是设备自己拔掉），旧 Port 会留在系统里，下一次
attach 就又多出一个 Port —— 于是两个 Port 指向同一个 busid，互相抢同一条
TCP 连接，表现为"第一次连很久都没事，断一次以后再连就时好时坏"。

用法：双击 reset-usbip.bat，会先打印当前端口，再问手机 IP（直接回车用上次那个）。

只看不改：reset-usbip.ps1 -DryRun

判断标准：跑完应该正好剩 1 个 Port。多于 1 个说明驱动还在后台重试，再跑一次；
仍然多，就重启手机上的服务端再连。

