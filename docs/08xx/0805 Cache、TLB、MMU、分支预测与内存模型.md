# 0805 Cache(缓存)、TLB(地址转换后备缓冲)、MMU(内存管理单元)、分支预测与内存模型

> 文档编号：0805  
> 所属部分：08 处理器架构、RISC-V(第五代精简指令集架构) 与 CPU(中央处理器) 微架构  
> 对应总纲小节：8.4 分支预测、8.5 存储层次、8.6 一致性与内存模型、8.9 高级微架构基础  
> 主题定位：系统讲清 CPU 中 cache、TLB、MMU、branch prediction(分支预测) 和 memory model(内存模型) 的基本结构、RTL(寄存器传输级) 落地方式、验证方法、时序/PPA(性能、功耗、面积) 影响，以及面试中如何从“概念名词”讲到“工程实现”。  
> 目标岗位：数字 IC(集成电路) 设计、数字 IC 验证、CPU 前端设计、SoC(片上系统) 前端、处理器验证、嵌入式 CPU/应用处理器相关岗位。  
> 前置知识：建议先阅读 `0801 RISC-V ISA基础.md`、`0802 RISC-V五级流水线与Hazard.md`、`0803 CSR、异常中断与特权级.md`、`0804 RISC-V SoC、MMIO与外设互联.md`；需要理解 pipeline(流水线)、load/store(加载/存储)、MMIO(内存映射输入输出)、exception(异常)、interrupt(中断)、SystemVerilog(系统 Verilog) 和基础 SRAM(静态随机存取存储器)。

---

## 术语首次出现说明

本文档遵循“英文名词或缩写首次出现时给出中文名称”的规则。以下术语在后文会高频出现，后续再次出现时可直接使用英文或缩写。

| 英文术语 | 中文名称 | 英文术语 | 中文名称 | 英文术语 | 中文名称 |
|---|---|---|---|---|---|
| cache | 缓存 | TLB | 地址转换后备缓冲 | MMU | 内存管理单元 |
| branch prediction | 分支预测 | memory model | 内存模型 | CPU | 中央处理器 |
| RISC-V | 第五代精简指令集架构 | RTL | 寄存器传输级 | SoC | 片上系统 |
| IC | 集成电路 | PPA | 性能、功耗、面积 | SystemVerilog | 系统 Verilog |
| SRAM | 静态随机存取存储器 | DRAM | 动态随机存取存储器 | MMIO | 内存映射输入输出 |
| pipeline | 流水线 | load/store | 加载/存储 | exception | 异常 |
| interrupt | 中断 | I-cache | 指令缓存 | D-cache | 数据缓存 |
| L1/L2/L3 | 一级/二级/三级缓存 | cache line | 缓存行 | block | 缓存块 |
| tag | 标签 | index | 索引 | offset | 偏移 |
| valid bit | 有效位 | dirty bit | 脏位 | replacement | 替换 |
| direct-mapped | 直接映射 | set-associative | 组相联 | fully-associative | 全相联 |
| way | 路 | set | 组 | hit/miss | 命中/未命中 |
| compulsory miss | 强制未命中 | capacity miss | 容量未命中 | conflict miss | 冲突未命中 |
| write-through | 写直达 | write-back | 写回 | write-allocate | 写分配 |
| no-write-allocate | 不写分配 | write buffer | 写缓冲 | victim cache | 牺牲缓存 |
| prefetch | 预取 | stride | 步长 | locality | 局部性 |
| FENCE.I | 指令缓存同步屏障指令 | LSU | 加载存储单元 | CAM | 内容寻址存储器 |
| miss penalty | 未命中惩罚 | hit time | 命中时间 | miss rate | 未命中率 |
| AMAT | 平均访存时间 | refill | 回填 | eviction | 驱逐 |
| victim | 被替换项 | replay | 重放 | MSHR | 未命中状态保持寄存器 |
| outstanding miss | 未完成未命中 | hit-under-miss | 未命中期间命中继续 | miss-under-miss | 多未命中并发 |
| temporal locality | 时间局部性 | spatial locality | 空间局部性 | cacheable | 可缓存 |
| device memory | 设备内存 | uncached | 不缓存 | memory attribute | 内存属性 |
| virtual address | 虚拟地址 | physical address | 物理地址 | page | 页 |
| page table | 页表 | page table walk | 页表遍历 | PTW | 页表遍历器 |
| PTE | 页表项 | VPN | 虚拟页号 | PPN | 物理页号 |
| ASID | 地址空间标识 | satp | 监管地址转换与保护寄存器 | SFENCE.VMA | 虚拟内存栅栏指令 |
| A/D bit | 访问/脏位 | R/W/X | 读/写/执行权限位 | U/S | 用户/监管权限位 |
| page fault | 页故障 | access fault | 访问错误 | permission check | 权限检查 |
| PMP | 物理内存保护 | PMA | 物理内存属性 | Sv32/Sv39/Sv48 | 32/39/48 位监管虚拟内存方案 |
| VIPT | 虚拟索引物理标签 | PIPT | 物理索引物理标签 | VIVT | 虚拟索引虚拟标签 |
| alias | 别名 | synonym | 同义别名 | homonym | 同名异义 |
| branch target | 分支目标 | BTB | 分支目标缓冲器 | BHT | 分支历史表 |
| PHT | 模式历史表 | RAS | 返回地址栈 | GHR | 全局历史寄存器 |
| 1-bit predictor | 1 位预测器 | 2-bit predictor | 2 位饱和计数器预测器 | saturating counter | 饱和计数器 |
| taken/not taken | 跳转/不跳转 | mispredict | 预测错误 | redirect | 重定向 |
| speculation | 推测执行 | wrong-path | 错误路径 | squash/kill | 压掉/杀除 |
| predictor update | 预测器更新 | checkpoint | 检查点 | branch PC | 分支程序计数器 |
| commit/retire | 提交/退休 | store buffer | 存储缓冲 | load queue | 加载队列 |
| store queue | 存储队列 | memory ordering | 内存顺序 | coherence | 一致性 |
| consistency | 一致性模型 | RVWMO | RISC-V 弱内存顺序模型 | FENCE | 存储屏障指令 |
| acquire/release | 获取/释放语义 | AMO | 原子内存操作 | LR/SC | 保留加载/条件存储 |
| invalidate | 无效化 | snoop | 监听 | directory | 目录 |
| MESI | 修改/独占/共享/无效协议 | MSI | 修改/共享/无效协议 | MOESI | 修改/拥有/独占/共享/无效协议 |
| scoreboard | 记分板 | SVA | SystemVerilog 断言 | coverage | 覆盖率 |
| directed test | 定向测试 | random test | 随机测试 | reference model | 参考模型 |
| ISS | 指令集模拟器 | debug | 调试 | critical path | 关键路径 |
| OS | 操作系统 | kernel | 内核 | driver | 驱动程序 |
| bare-metal | 裸机软件 | runtime | 运行时 | virtual memory | 虚拟内存 |
| doorbell | 门铃寄存器 | descriptor | 描述符 | write-back cache | 写回缓存 |
| flash | 闪存 | eMMC | 嵌入式多媒体卡 | UFS | 通用闪存存储 |
| SSD | 固态硬盘 | storage controller | 存储控制器 | DMA | 直接存储器访问 |
| persistent storage | 持久化存储 | file system | 文件系统 | executable image | 可执行镜像 |
| block/page | 块/页 | firmware | 固件 | bootloader | 启动加载程序 |
| structural hazard | 结构冒险 | cache controller | 缓存控制器 | bus response | 总线响应 |
| backpressure | 反压 | store buffer entry | 存储缓冲项 | bus transaction | 总线事务 |

---

## 第0章 本专题学习地图

### 0.0 为什么把这五个主题放在一篇

cache、TLB、MMU、分支预测和内存模型看起来是五类问题，但它们都服务于同一件事：

```text
让 CPU 更快地取指、访存、跳转，并且仍然保持软件可见行为正确。
```

`0801` 第7章已经把程序、用户数据、ROM/RAM/flash 和 storage controller 的直觉关系先铺开了。本篇继续讨论的是运行时这一侧：当 firmware、kernel、app 或用户数据被 bootloader/OS/driver 从 flash/eMMC/UFS/SSD 搬到 SRAM/DRAM 后，CPU 如何用 cache 降低访问延迟，用 TLB/MMU 管理虚拟地址和权限，用 FENCE/内存模型保证 DMA、MMIO 和多核场景下的可见顺序。

它们之间的关系非常紧：

- I-cache 提高取指带宽，但分支预测决定下一拍取哪里。
- D-cache 降低 load/store 延迟，但 MMIO/device memory 通常不能被缓存。
- TLB 把虚拟地址快速转成物理地址，MMU 负责页表遍历和权限检查。
- 分支预测引入 wrong-path 指令，cache/TLB 访问可能发生在推测路径上。
- memory model 决定 load/store、FENCE、AMO、LR/SC 在多核和外设下的可见顺序。

### 0.1 小节关系

本篇按下面顺序展开：

1. 第1章讲存储层次和 cache 解决的问题。
2. 第2章讲 cache 的结构：tag/index/offset、映射方式、替换、写策略。
3. 第3章讲 I-cache、D-cache、MMIO 和 cacheable/device memory。
4. 第4章讲 TLB/MMU、页表、权限检查、page fault 和 SFENCE.VMA。
5. 第5章讲分支预测：BTB/BHT/PHT/RAS、更新和恢复。
6. 第6章讲内存模型、store buffer、FENCE、AMO、LR/SC 和一致性。
7. 第7章给 RTL 结构骨架。
8. 第8章讲验证方法。
9. 第9章讲时序、综合、后端和 PPA 影响。
10. 第10章讲常见 bug、边界条件和 debug 方法。
11. 第11章讲面试问法。
12. 第12章讲练习题与答案要点。
13. 第13章讲和其他章节的关联。

### 0.2 这篇的学习边界

本篇不追求把乱序核、完整 Linux MMU 或多核一致性协议全部实现出来，而是面向数字 IC 面试和工程基础，建立下面这套能力：

- 能画出 cache/TLB/branch predictor 的基本结构。
- 能解释为什么 MMIO 不能随便 cache。
- 能说明 page fault 和 access fault 的区别。
- 能讲清分支预测错误后怎么恢复。
- 能解释弱内存模型下为什么需要 FENCE。
- 能说出 RTL 和验证里最容易出错的地方。

---

## 第1章 存储层次和 Cache 的问题背景

当前阶段建议：简单了解本章，重点知道 cache/DRAM/storage 的层次关系；最小 RV32I 教学核可以先无 cache。

### 1.0 CPU 为什么需要 cache

CPU 核心频率远高于外部 DRAM 访问速度。如果每条指令和每次数据访问都直接去 DRAM，流水线大部分时间都在等内存。

这里讨论的 DRAM/SRAM/cache 属于“运行时访问路径”。用户看到的 app、照片或 OTA 包可能长期放在 flash/eMMC/UFS/SSD 这类 persistent storage 中，但 CPU 执行和频繁访问时，通常先由 OS/driver 通过 storage controller 把相关 block/page 读入 DRAM 或 SRAM；之后 CPU 再通过 I-cache/D-cache 取指和访问数据。因此，persistent storage 解决“掉电不丢和容量”的问题，cache/DRAM 解决“运行时速度和随机访问”的问题。

可以先用三层速度差建立直觉：

| 层次 | 典型位置 | 容量直觉 | 速度直觉 | 主要解决什么 |
|---|---|---|---|---|
| cache | CPU core 附近或内部 | 小 | 很快 | 给热点指令/数据加速 |
| SRAM/DRAM | 片上 SRAM 或片外/片上 DRAM | 中到大 | 中等 | 存放运行时代码、栈、堆、页表 |
| flash/eMMC/UFS/SSD | 持久化存储 | 大 | 慢，且访问粒度粗 | 掉电保存 firmware、app、文件和用户数据 |

cache 不是新的软件地址空间，也不是程序员手动分配的一块普通 RAM。它更像 CPU 和下级 memory 之间的透明加速层：软件仍然访问同一个地址，硬件自动判断这次访问能否在 cache 里命中。

cache 利用局部性减少平均访问延迟：

- 时间局部性：刚访问过的数据，近期可能再次访问。
- 空间局部性：访问某个地址后，附近地址也可能很快被访问。

平均访存时间可以粗略表示为：

$$
AMAT = HitTime + MissRate \times MissPenalty
$$

其中：

- `HitTime`：命中时延迟。
- `MissRate`：未命中率。
- `MissPenalty`：未命中后从下一级取回的代价。

这个公式也解释了为什么 cache 设计不只是“越大越好”。更大的 cache 可能降低 `MissRate`，但也可能增加 `HitTime`；更大的 line 可能降低空间局部性好的程序的 miss，但会增加 `MissPenalty` 和污染风险。面试里要能把这三个量一起讲，而不是只说“cache 提高性能”。

### 1.1 cache 解决的问题和引入的问题

cache 解决的是性能问题，但引入了工程复杂度：

| 带来的好处 | 带来的复杂度 |
|---|---|
| 降低平均访存延迟 | tag 比较和替换 |
| 提高取指/访存吞吐 | miss refill 状态机 |
| 减少总线流量 | write-back dirty 管理 |
| 隐藏 DRAM 延迟 | 一致性和内存顺序 |
| 提升热点数据访问 | MMIO/cacheable 属性区分 |

把 cache 放进 CPU 后，load/store 不再是“地址发出去、数据立刻回来”的简单动作，而是变成一条带属性和状态机的数据路径：

```text
virtual/physical address
  -> attribute check: cacheable / uncached / device
  -> tag/index/offset lookup
  -> hit: return data or merge store
  -> miss: choose victim, writeback if dirty, refill
  -> replay original request
```

这条路径必须和 `0802` 的 pipeline stall/flush、`0803` 的 exception/trap、`0804` 的 MMIO/device memory 对齐。比如一条 load 发生 D-cache miss 后，流水线可能 stall 多拍；如果 miss refill 最后返回 bus error，就要产生 access fault；如果地址属于 MMIO，则不应进入 cache，也不能被 write-back 或合并。

所以 cache controller 同时站在三条边界上：

| 边界 | cache 必须回答的问题 |
|---|---|
| 和流水线 | hit 能否本拍返回，miss 是否 stall/replay，flush 后请求是否还能产生副作用 |
| 和总线/内存 | miss 如何 refill，dirty victim 如何 writeback，错误响应如何上报 |
| 和系统属性 | 这个地址是否 cacheable，是否 device memory，是否允许 speculative access |

初学时最容易漏掉第三条。普通 DRAM 可以 cache，UART/PLIC/CLINT 这类 MMIO 通常不能 cache；否则 cache 会把“读状态”“写触发”错误地当成普通数据保存起来。

### 1.2 cache line

cache 不是按单字节独立缓存，而是按 cache line 搬运。假设 line size 为 $B$ 字节，则地址低位 offset 位数为：

$$
offset\_bits = \log_2(B)
$$

line 越大：

- 空间局部性利用更好。
- tag 开销更低。
- miss refill 带宽需求更高。
- 污染风险更大。

line size 还会影响异常和总线行为。一次 `LW` 只需要 4 byte，但 refill 可能拉回 64 byte；如果这 64 byte 跨越了不可访问区域或设备区域，设计必须明确是否允许这种访问。通常 cacheable normal memory 才允许按 line refill，device/uncached 访问按实际访问宽度发出，避免读取额外地址造成外设副作用。

例如 line size 是 64 byte，CPU 读地址 `0x8000_0014`。cache 并不是只缓存这 4 byte，而是把 `0x8000_0000` 到 `0x8000_003f` 这一整条 line 作为一个单位管理。offset 选择 line 内第几个字节，index 选择放在哪个 set，tag 用来确认这条 line 是否就是目标地址对应的数据。

---

## 第2章 Cache 结构

当前阶段建议：可以先简单了解地址拆分、hit/miss、valid/dirty 的直觉，详细 cache 结构可等无 cache 教学核跑通后再看。

### 2.0 地址拆分

以物理地址访问的 set-associative cache 为例，cache lookup 的第一步是把地址拆成三段：

```text
physical address
+----------------+-------------+-------------+
|      tag       |    index    |   offset    |
+----------------+-------------+-------------+
```

其中：

- offset 选择 cache line 内字节。
- index 选择 set。
- tag 判断这个 set 中哪一路命中。

如果 cache 总容量为 $C$，路数为 $W$，line size 为 $B$，则 set 数为：

$$
Sets = \frac{C}{W \times B}
$$

index 位宽为：

$$
index\_bits = \log_2(Sets)
$$

tag 位宽为：

$$
tag\_bits = PA\_bits - index\_bits - offset\_bits
$$

这三个字段不是只为计算题服务，它们直接决定 SRAM 组织和关键路径：

| 字段 | 进入哪里 | 时序影响 | 常见 bug |
|---|---|---|---|
| offset | data array byte/word select | data MUX、byte lane | load byte/halfword 选错 |
| index | tag/data array 读地址 | SRAM 读延迟 | set 数计算错，地址别名 |
| tag | tag compare | 多路比较器延迟 | tag 位宽少一位导致假命中 |

对 set-associative cache，通常同一个 index 会同时读出多路 tag 和 data，然后并行比较 tag。为了缩短 hit time，有些设计会先读 tag，命中后再读 data，牺牲一拍 latency 换 Fmax 和功耗；也有设计用 way prediction 减少多路 data array 读。面试中要明确这是 PPA trade-off，不存在绝对最优。

一个具体例子更直观。假设物理地址 32 bit，cache 容量 32 KiB，4-way，line size 64 byte：

$$
Sets = \frac{32 \times 1024}{4 \times 64} = 128
$$

因此：

$$
offset\_bits = \log_2(64)=6,\quad index\_bits=\log_2(128)=7
$$

$$
tag\_bits = 32 - 7 - 6 = 19
$$

这不是单纯计算题，而是直接变成硬件结构：data array 有 128 个 set，每个 set 有 4 路，每路一条 64 byte line；tag array 每个 set 每路至少保存 19 bit tag，再加 valid/dirty 等状态。

### 2.1 直接映射、组相联、全相联

| 类型 | 命中判断 | 优点 | 缺点 |
|---|---|---|---|
| direct-mapped | 每个 index 只有 1 路 | 简单、快、省面积 | conflict miss 多 |
| set-associative | 每个 set 多路并行比较 | miss 率和复杂度折中 | 多路 tag 比较更慢 |
| fully-associative | 任意 line 可放任意位置 | conflict miss 最少 | 比较器多，面积大 |

可以把映射方式理解成“一个地址来的时候，它有几个候选位置”：

```text
direct-mapped:
  只能放到唯一位置，找得快，但容易和别的地址打架。

set-associative:
  先用 index 找到一个 set，再在 set 内多个 way 里选一个。

fully-associative:
  可以放任何位置，但查找时几乎要全表比较。
```

L1 cache 常用 2-way、4-way、8-way 这类组相联，是因为它在 hit time、面积和 miss rate 之间比较均衡。TLB 因为项数较少，常见 fully-associative 或 set-associative。

### 2.2 tag/data/valid/dirty

cache 常见 SRAM/寄存器阵列：

```text
tag_array[set][way]   : tag + valid + dirty
data_array[set][way]  : cache line data
replacement_state[set]: LRU/PLRU/random state
```

命中条件：

$$
hit = valid \land (tag_{stored} = tag_{req})
$$

写回 cache 还要关心：

$$
evict\_needs\_writeback = valid \land dirty
$$

一次 D-cache hit 写入时，至少要更新三类状态：

```text
data_array: 写入对应 byte lane
dirty bit : write-back cache 中置 1
replacement state: 更新该 way 最近使用信息
```

一次 refill 则要同时写 tag、valid、data，并清理或设置 dirty。若 refill 是为了 store miss 且采用 write-allocate，refill 后还要把原 store 合并进去；如果是 no-write-allocate，则可能完全不填 cache，直接把写事务送到下级。

| 场景 | data | tag/valid | dirty | replacement |
|---|---|---|---|---|
| load hit | 读出 | 不变 | 不变 | 更新 |
| store hit, write-back | byte merge 写入 | 不变 | 置 1 | 更新 |
| clean victim refill | 写新 line | 写新 tag，valid=1 | 通常 0 | 更新 |
| dirty victim eviction | 先 writeback 旧 line | refill 后写新 tag | 按新请求决定 | 更新 |
| uncached access | 不进 array | 不变 | 不变 | 不变 |

`valid` 和 `dirty` 是初学时最该抓住的两个状态位：

| 位 | 回答的问题 | 没有它会怎样 |
|---|---|---|
| valid | 这一项里保存的数据是否可信 | reset 后随机 tag 可能造成假命中 |
| dirty | 这一项是否比下级 memory 更新 | 替换时不知道要不要写回，可能丢数据 |

dirty 只对 write-back cache 有核心意义。write-through 每次写都会同步写下级，通常不需要靠 dirty bit 决定替换时是否 writeback；write-back 为了省带宽，先只改 cache，所以必须记住这条 line 是否“脏”。

### 2.3 miss 类型

| miss 类型 | 原因 | 例子 | 改善方式 |
|---|---|---|---|
| compulsory miss | 第一次访问该 line，cache 里本来没有 | 程序第一次读某个数组元素 | 预取、更大 line |
| capacity miss | 工作集超过 cache 容量 | 同时遍历多个大数组，cache 装不下 | 增大 cache、优化程序局部性 |
| conflict miss | 多个热点地址映射到同一 set/way | 两个数组地址低位模式相同，反复互相替换 | 增加路数、victim cache、调整布局 |

这三类 miss 对应不同优化方向。把 cache 从 direct-mapped 改成 4-way 主要改善 conflict miss；把 32 KiB 改成 64 KiB 主要改善 capacity miss；预取主要针对可预测访问造成的 compulsory 或部分 capacity miss。不能把所有 miss 都简单归因成“cache 不够大”。

### 2.4 写策略

写策略要回答两个问题：

1. store hit 时，是否立刻写下一级 memory。
2. store miss 时，是否把整条 line 拉进 cache。

| 策略 | 回答的问题 | 含义 | 适用 |
|---|---|---|---|
| write-through | hit 写怎么处理 | 每次写 cache 同时写下级 | 简单一致，带宽大 |
| write-back | hit 写怎么处理 | 只写 cache，替换时写回 | 带宽低，dirty 管理复杂 |
| write-allocate | miss 写怎么处理 | 写 miss 时把 line 拉进 cache，再合并 store | 适合写后再读/再写 |
| no-write-allocate | miss 写怎么处理 | 写 miss 直接写下级，不填 cache | 适合流式写 |

简单 MCU 常用 write-through 或 uncached；高性能核更常用 write-back。

常见组合是 write-back + write-allocate。原因是很多 store 后面还会继续访问附近地址，拉进 cache 后能利用时间/空间局部性。但如果是大块流式写，例如清屏、搬运一次性 buffer，write-allocate 可能把原有热点数据挤出去，这时 no-write-allocate 或 cache bypass 更合适。

对 MMIO/device memory，不应套用这些普通 cache 写策略。写 UART doorbell 不能先留在 dirty cache line 里等以后替换；写 DMA start 也不能被合并或延迟到软件无法预期的时间。

### 2.5 替换策略

常见策略：

- random：简单，效果不一定差。
- round-robin：实现简单，可预测。
- true LRU：命中率好，但多路时状态复杂。
- pseudo-LRU：工程折中。

面试回答不要说“LRU 一定最好”。路数高时 true LRU 的面积和时序代价可能不值得。

替换策略只在“一个 set 里没有空 way，必须踢掉一条 line”时生效。工程上常常优先选择容易验证、时序稳定的策略，而不是理论命中率最好的策略。比如 2-way true LRU 很简单；8-way true LRU 状态和更新逻辑明显复杂，pseudo-LRU 或 random 可能更划算。

---

## 第3章 I-cache、D-cache、MMIO 和 Cacheable 属性

当前阶段建议：简单了解本章，重点知道 MMIO 通常不能 cache；当前教学核若无 cache，只需保留这个系统直觉。

### 3.0 I-cache 和 D-cache 的差异

I-cache 和 D-cache 都是 cache，但接在流水线的位置不同。I-cache 服务取指，D-cache 服务 LSU 的 load/store。

| 项目 | I-cache | D-cache |
|---|---|---|
| 访问方向 | 主要只读 | 读写都有 |
| 触发来源 | IF 阶段按 PC 取指 | MEM/LSU 按 load/store 地址访问 |
| 复杂度 | 相对简单 | 需要写策略和一致性 |
| 异常 | instruction access/page fault | load/store fault |
| 旁路 | 预测取指相关 | store buffer、load forwarding |
| 自修改代码 | 需要 I/D 同步 | 需要写入后让 I-cache 可见 |

I-cache 的难点更多在“下一拍取哪里”和“取到的指令是否还在正确路径上”；D-cache 的难点更多在“写什么时候对外可见”“miss 时流水线怎么等”“MMIO 不能被普通缓存语义破坏”。

### 3.1 MMIO 为什么通常不能缓存

MMIO 地址对应外设寄存器，不是普通内存。缓存它会出现：

- 读到旧状态。
- 写被合并或延迟。
- 读清零寄存器被重复读。
- 写触发寄存器被重复触发或不触发。

因此设备区通常标记为 device memory 或 uncached。

系统 OS/driver 视角下，这不是性能优化细节，而是正确性要求。驱动读状态寄存器时希望看到外设当前状态，写 doorbell 寄存器时希望真正触发设备动作；如果 MMIO 被 D-cache 命中、写回或合并，软件会看到“驱动代码没错但硬件不响应”的现象。因此 cache controller、MMU/PMA/PMP 和 SoC memory map 必须对 device memory 属性达成一致。

举一个典型错误：软件写 DMA descriptor 到内存，然后写 MMIO doorbell 启动 DMA。如果 doorbell 写被 cache 当成普通 store 留在 cache 里，设备根本收不到启动命令；如果 status 寄存器被 cache，软件可能一直读到旧的 busy 位。MMIO 的核心是“每次访问都要到达设备，并按设备寄存器语义生效”。

### 3.2 cacheable 属性从哪里来

cacheable/uncached/device 属性可能来自：

- 固定 memory map。
- PMA。
- PMP。
- page table attribute。
- SoC 私有属性表。

简单核可能只按地址段判断；支持 MMU 的核则通常结合页表和 PMA/PMP。

系统 OS 视角下，page table 不只决定虚拟地址翻译，也可能携带页面权限和内存属性；但平台级 PMA/PMP 仍然会限制某些物理区域的最终属性。一个常见原则是：OS 可以把普通内存映射给进程，但不应把 UART/PLIC/CLINT 这类外设错误标成普通 cacheable memory。硬件要在属性合并规则里保证 device memory 不会被错误缓存。

可以把属性合并理解成“多层规则取更保守结果”：

```text
page table 说 cacheable
PMA/PMP 或固定 memory map 说这是 device region
最终仍应按 device/uncached 处理
```

因为 OS 页表是软件配置，可能有 bug；而某些物理地址天然就是外设窗口，硬件平台属性必须兜底。

### 3.3 refill 和 writeback 状态机

典型 D-cache miss 流程：

```text
lookup miss
  |
  v
choose victim
  |
  +-- victim dirty? -- yes --> writeback old line
  |                         |
  |                         v
  +----------------------> refill new line
                            |
                            v
                         update tag/data
                            |
                            v
                         replay request
```

从 `0802` 第7章 structural hazard 的视角看，cache miss 不是普通的 ALU 数据相关，而是 MEM 访问路径暂时服务不了当前 load/store：cache controller 要等待 refill、writeback 或下游 bus response。简单阻塞式 D-cache 会让流水线前级 backpressure；更复杂的非阻塞 cache 则用 MSHR 记录未完成 miss，让部分无关访问继续前进。

这段流程里的关键点是：miss 不是“算错了”，而是 cache 当前没有这条 line，需要去更低层拿。若 victim 是 dirty，还必须先把旧 line 写回，否则下级 memory 会丢掉最新数据。refill 完成后，原来的 load/store 通常要 replay，因为第一次 lookup 时数据还不存在。

对 store miss，如果采用 write-allocate，流程是：

```text
store miss
  -> refill target line
  -> 把原 store 的 byte lane 合并进新 line
  -> dirty=1
  -> store 完成
```

如果采用 no-write-allocate，则可能直接把 store 发到下级，不填 cache。

### 3.4 非阻塞 cache

简单 cache 在 miss 时会阻塞整个流水线。更高性能设计可能引入：

- MSHR：记录多个 outstanding miss。
- hit-under-miss：miss 未完成时允许其他命中继续。
- miss-under-miss：允许多个 miss 并发。

代价是控制和验证复杂度显著增加。

阻塞式 cache 的直觉是“当前 miss 没回来，后面的访存先别动”。非阻塞 cache 的直觉是“这笔 miss 我记下来等它回来，如果后面有无关命中，可以先服务”。MSHR 就是用来记录这些未完成 miss 的表项，里面通常要保存地址、请求类型、目标寄存器或回放信息、等待同一 line 的多个请求等。

入门面试里能讲清阻塞式 cache 已经足够；如果提非阻塞 cache，要强调它不是简单加队列，而是会影响 load/store 顺序、异常回放、同 line 合并、MSHR 满时 backpressure 和验证复杂度。

---

## 第4章 TLB、MMU 和页表

当前阶段建议：可以先跳过大部分内容，只需知道 TLB/MMU 是支持 OS、虚拟内存和权限保护的硬件基础，最小教学核不需要实现。

### 4.0 为什么需要虚拟内存

虚拟内存解决几个问题：

- 每个进程有独立地址空间。
- 操作系统能保护内核和用户程序。
- 物理内存可以不连续。
- 支持 page fault、按需分配和换页。

CPU 发出的地址可以是 virtual address，经过 MMU 转换成 physical address，再访问 cache/内存。

系统 OS 视角下，虚拟内存的核心价值是隔离和管理：用户程序看到自己的连续地址空间，OS kernel 通过 page table 控制哪些页可读、可写、可执行，以及用户态能否访问。数字 IC 不需要实现完整操作系统，但需要理解 MMU/TLB 是 OS 建立进程隔离、缺页处理和权限保护的硬件基础。

没有虚拟内存时，程序直接使用物理地址。这样简单，但很难支持现代 OS 的几个基本需求：

| 需求 | 没有 MMU 的困难 | 有 MMU 后怎么做 |
|---|---|---|
| 进程隔离 | 一个程序可能直接读写另一个程序的内存 | 每个进程用不同页表 |
| 内核保护 | 用户程序可能写内核代码/数据 | 页权限禁止 U-mode 访问内核页 |
| 连续地址假象 | 物理内存碎片会暴露给程序 | 虚拟连续，物理可不连续 |
| 按需分配 | 必须提前分配全部内存 | page fault 后 OS 再分配页 |
| 换页/文件映射 | 很难把磁盘文件映射成内存视图 | 页表和 page fault 配合 OS 完成 |

所以 MMU 不是单纯“地址加一层映射”，而是 OS 管理内存和权限的硬件入口。

### 4.1 TLB 的作用

TLB 是页表转换结果的 cache。没有 TLB，每次访存都要查多级页表，代价太高。一次普通 load 本来只想读数据，如果还要先读好几次页表，流水线性能会非常差。

TLB 项常见字段：

```text
VPN | ASID | PPN | permission | valid | global | attribute
```

命中条件通常是：

$$
tlb\_hit = valid \land (VPN_{entry}=VPN_{req}) \land (ASID_{entry}=ASID_{req} \lor global)
$$

TLB 和 cache 的相似点是“都缓存近期用过的信息”；不同点是：

| 对比项 | cache | TLB |
|---|---|---|
| 缓存内容 | 数据或指令 cache line | 虚拟页到物理页的翻译结果 |
| 查询 key | 地址的 index/tag | VPN + ASID |
| miss 后做什么 | refill cache line | page table walk |
| 错误类型 | access fault、bus error 等 | page fault、权限失败等 |
| 软件关系 | 通常对程序透明 | OS 改页表后要用 `SFENCE.VMA` 管理旧项 |

TLB hit 只是说明“地址翻译找到了”，不是说明这次访问一定合法。权限位、访问类型、特权级、PMA/PMP 还要继续检查。

### 4.2 MMU 转换流程

```text
virtual address
  |
  v
TLB lookup
  | hit
  v
physical address + permission check
  |
  v
cache / memory

TLB miss
  |
  v
page table walk
  |
  v
fill TLB or raise page fault
```

工程上还要区分“转换得到物理地址”和“这次访问被允许”。TLB hit 只说明找到了映射，不代表访问一定成功；权限检查、PMA/PMP、页属性和访问类型还要继续判断。

| 检查 | 输入 | 失败结果 |
|---|---|---|
| TLB tag match | VPN、ASID、global | TLB miss |
| PTE valid | PTE.V 和组合规则 | page fault |
| permission | R/W/X、U/S、MXR、SUM | instruction/load/store page fault |
| accessed/dirty | A/D 位和访问类型 | page fault 或硬件更新 A/D |
| physical protection | PMP/PMA、memory attribute | access fault 或 device/uncached |
| alignment | physical/effective address 低位 | address misaligned 或实现定义处理 |

因此 LSU 的异常优先级需要写清楚。例如一个 store 地址既非对齐又页表无权限，设计应按规格或项目约定选择报告哪个异常。验证时要构造“多个错误条件同时成立”的 directed test，避免 RTL 中异常原因由偶然的组合逻辑优先级决定。

从一条 load 的视角，可以分成三步：

```text
1. 有效地址生成:
   rs1 + imm 得到 virtual/effective address

2. 地址转换和权限检查:
   TLB/MMU 把 virtual address 转成 physical address，并检查 R/W/X、U/S 等权限

3. 物理访问:
   用 physical address 查 D-cache、访问 memory 或 MMIO，并处理 PMA/PMP/access fault
```

page fault 通常发生在第 2 步，access fault 更常发生在第 3 步或物理保护层。这样区分后，`0803` 里的 `stval/mtval` 为什么要记录 fault address 就更好理解：handler 需要知道是哪一次地址访问触发了问题。

### 4.3 page table walk

PTW 是硬件或软件完成的页表遍历。RISC-V 常见监管虚拟内存方案包括 Sv32、Sv39、Sv48。

页表遍历要检查：

- PTE 是否 valid。
- 权限位是否允许当前访问。
- U/S 权限是否匹配。
- 读写执行权限是否满足。
- accessed/dirty 位是否需要更新。

硬件 PTW 本质上是一个小型状态机，它自己也要访问 memory：

```text
TLB miss
  -> read root page table PTE
  -> check valid/leaf
  -> read next-level page table PTE if non-leaf
  -> form PPN + page offset
  -> fill TLB
  -> replay original access
```

PTW 访问页表时通常走物理地址路径，且要避免和普通 D-cache/LSU 请求互相破坏顺序。简单设计会在 TLB miss 时阻塞流水线，只允许 PTW 独占 memory 端口；高性能设计可能让 PTW 走独立端口或 page walk cache，但验证复杂度会显著增加。

页表本身也放在 memory 里，由 OS 建立和修改。`satp` 提供根页表位置和地址空间相关信息，MMU 根据虚拟地址的 VPN 分段逐级索引页表。每一级读出的 PTE 要么指向下一级页表，要么是 leaf PTE，给出最终 PPN 和权限。

因此 TLB miss 不等于 page fault：

| 事件 | 含义 | 后续动作 |
|---|---|---|
| TLB miss | TLB 里没有缓存这个翻译 | PTW 去页表查 |
| PTW 成功 | 页表有合法映射且权限允许 | 填 TLB，replay 原访问 |
| page fault | 页表无效、权限不允许、A/D 位不满足等 | 进入 trap，交给 OS/handler |

把 TLB miss 当成异常是常见误解。TLB miss 是微架构内部事件，通常软件不可见；page fault 才是架构异常。

### 4.4 page fault 和 access fault

| 异常 | 常见原因 | 更像哪一层的问题 | handler 常见处理 |
|---|---|---|---|
| page fault | 页表项无效、权限不允许、缺页、A/D 位问题 | 虚拟内存/页表层 | OS 判断是否分配页、换页、扩栈或杀进程 |
| access fault | 物理访问失败、PMA/PMP 不允许、总线错误 | 物理平台/保护/总线层 | 固件或 OS 报错、终止访问、复位或 debug |

面试中要能区分：

- page fault 是地址转换/权限层面的异常。
- access fault 更接近物理内存或总线访问层面的异常。

系统 OS 视角下，page fault 通常交给内核判断：可能是非法访问，也可能是按需分配页面、栈增长或换页触发的正常机制。access fault 则更像平台硬件层面的拒绝或失败，例如 PMP/PMA 不允许、总线从设备报错。硬件必须把 faulting PC 和 fault address 交给 trap handler，否则 OS 很难定位是哪一次访问出错。

例如用户程序第一次访问一段尚未实际分配的栈页，OS 可能通过 page fault 分配新页，然后返回重试原指令；但如果访问的是不存在的物理外设窗口，总线返回错误，这更像 access fault，通常不能通过“分配一个页”解决。

### 4.5 SFENCE.VMA

软件修改页表后，旧的 TLB 项可能仍然存在。`SFENCE.VMA` 用来保证后续虚拟地址转换看到新的页表状态。

典型场景：

- 切换进程地址空间。
- 修改页表权限。
- 映射或解除映射页面。

`SFENCE.VMA` 的关键不是“清空一个表”这么简单，而是建立页表写入和后续地址转换之间的顺序。没有它，硬件可能继续使用旧 TLB 项：

```text
store new PTE
SFENCE.VMA
later load/store/fetch uses new translation
```

实现可以选择全 TLB flush，也可以按 ASID/VPN 精确失效。简单核全清最容易做对，但性能较差；支持多进程和大 TLB 的核更需要精确失效。

| 实现 | 优点 | 代价 |
|---|---|---|
| 全部失效 | 简单、验证容易 | 性能损失大 |
| 按 ASID 失效 | 进程切换更高效 | TLB 必须保存 ASID |
| 按 VPN+ASID 失效 | 最精确 | 比较逻辑和验证更复杂 |

`SFENCE.VMA` 容易被误解成“清 TLB 指令”。更准确地说，它是软件和硬件之间关于地址转换顺序的同步点：软件先把页表写好，再执行 `SFENCE.VMA`，硬件之后的地址转换不能继续使用不该使用的旧翻译。清 TLB 是一种实现方式，不是唯一语义。

### 4.6 VIPT、PIPT、VIVT

| 类型 | 含义 | 优点 | 风险 |
|---|---|---|---|
| PIPT | 物理索引物理标签 | 简单正确 | 需等地址转换完成 |
| VIPT | 虚拟索引物理标签 | TLB 与 cache 可并行 | synonym/alias 处理 |
| VIVT | 虚拟索引虚拟标签 | 快 | ASID、同名异义复杂 |

L1 cache 常见 VIPT 设计，因为可以并行做 TLB lookup 和 cache index，但必须控制 index 位不越过 page offset，减少 alias 问题。

三种名字可以拆开看：

```text
第一个字母：用 virtual 还是 physical 地址做 index。
第二个字母：用 virtual 还是 physical 地址做 tag。
```

PIPT 最容易做正确，因为所有比较都基于物理地址；缺点是必须等 TLB 翻译完成后才能 index cache。VIPT 试图并行：用虚拟地址低位先读 cache set，同时 TLB 翻译高位，最后用物理 tag 比较。VIVT 最快但最麻烦，因为不同进程可能有相同虚拟地址映射到不同物理页，必须处理 ASID、flush 或同名异义问题。

---

## 第5章 分支预测

当前阶段建议：简单了解即可；五级顺序教学核可以先用静态策略或直接等分支解析后 flush，不必实现 BTB/BHT/RAS。

### 5.0 分支预测解决什么

流水线越深，分支结果越晚知道。如果每遇到分支都停住等待，取指带宽会很差。

在 `0802` 里，控制冒险的核心问题是：下一条 PC 可能被后级指令改掉。分支预测就是把“等后级算完再取指”变成“先猜一个 next PC 继续取，猜错再 flush”。它解决的是取指端的空泡问题，不是改变 ISA 语义。

分支预测提前猜：

- 分支是否 taken。
- 目标地址在哪里。
- call/return 的返回地址是什么。

可以把分支预测分成两个问题：

| 问题 | 谁来回答 | 例子 |
|---|---|---|
| direction | 这条条件分支跳不跳 | BHT/PHT、1-bit/2-bit counter |
| target | 如果跳，目标 PC 是多少 | BTB、RAS、立即数计算 |

条件分支需要 direction 和 target；无条件 jump 主要需要 target；函数 return 的 target 来自寄存器，普通 BTB 不一定准，所以常用 RAS 预测。

### 5.1 基本结构

```text
PC
 |
 +--> BTB : 预测目标地址
 |
 +--> BHT/PHT : 预测 taken/not taken
 |
 +--> RAS : 预测 return target
 |
 v
predicted next PC
```

预测器通常工作在 IF 前后级，目标是尽早给出 `predicted_next_pc`。如果预测 taken 且 BTB 命中，下一拍就能从目标地址取指；如果预测 not taken 或没有有效目标，就顺序取 `PC+4` 或压缩指令下的下一地址。

这些结构都是微架构状态，不是软件架构状态。预测错了可以恢复，不能让 wrong-path 指令提交 GPR/CSR/memory 副作用。

### 5.2 1-bit 和 2-bit 预测器

1-bit predictor 记录上一次是否 taken。它对循环退出很敏感，常在循环入口/出口出现两次错误。

2-bit saturating counter 更稳定：

```text
00 strongly not taken
01 weakly not taken
10 weakly taken
11 strongly taken
```

更新规则：

- 实际 taken：计数器加 1，饱和到 3。
- 实际 not taken：计数器减 1，饱和到 0。

为什么 2-bit 更稳定？以循环分支为例，大部分迭代都是 taken，最后一次退出是 not taken。1-bit 预测器在退出时会从 taken 改成 not taken，下一次重新进入循环时又会错一次；2-bit 饱和计数器需要连续两次反向结果才从 strongly taken 翻到 not taken，因此对偶发一次退出更不敏感。

预测方向通常由 PC 索引一张表。表项可能被不同分支共享，这叫 alias。alias 不一定都是坏事，但会带来互相污染：两个分支映射到同一个 counter，如果行为相反，预测准确率会下降。

### 5.3 BTB

BTB 缓存 branch PC 到 branch target 的映射。没有 BTB，即使方向预测知道“这条分支大概率 taken”，IF 也未必知道目标地址，只能等后级算出 target。

BTB 项通常包含：

- tag。
- target。
- valid。
- branch type。

BTB 命中并且方向预测 taken 时，IF 阶段可直接取 target。

BTB 也需要 tag。只用 index 不够，因为多个 branch PC 可能映射到同一项；如果不比较 tag，可能把 A 分支的 target 错用到 B 分支上。BTB 还常保存 branch type，用来区分 conditional branch、jump、call、return，从而决定是否配合 BHT 或 RAS。

### 5.4 RAS

函数调用和返回用 RAS 预测：

- call 指令把返回地址 push。
- return 指令 pop 顶部地址作为预测目标。

RAS 最容易在异常、错误路径、递归、上下文切换和多线程共享时出 bug。

为什么 return 难预测？`JALR x0, 0(ra)` 这类 return 的目标地址来自寄存器 `ra`，同一条 return 指令在不同调用者下会返回不同位置。BTB 只能记住“这条 PC 上次跳到哪里”，对函数被多个地方调用的情况不够准；RAS 利用 call/return 的栈结构，call 时 push 返回地址，return 时 pop，通常更准确。

### 5.5 预测错误恢复

当 EX 或更晚 stage 知道真实方向/目标：

1. 比较 predicted PC 和 actual PC。
2. 如果错，flush wrong-path 指令。
3. redirect PC 到正确目标。
4. 更新 predictor。

核心原则：

- 推测状态可以错。
- 架构状态不能错。
- wrong-path 指令不能 commit。

为了做到这一点，预测信息必须随指令进入流水线，而不是只停留在 IF：

```text
fetch packet:
  pc
  predicted_taken
  predicted_target
  predicted_next_pc
  predictor_index / history snapshot
```

分支解析时，硬件会得到：

$$
mispredict = (predicted\_next\_pc \ne actual\_next\_pc)
$$

若 mispredict 成立，需要：

1. redirect PC 到 `actual_next_pc`。
2. flush younger wrong-path instruction。
3. 恢复或修正 global history/RAS 等推测 predictor 状态。
4. 在合适时机更新 BHT/BTB/RAS。

预测器更新时机也要小心。若在 fetch 时就永久更新 predictor，wrong-path 上的分支会污染预测表。简单设计可以在 branch resolve 或 commit 时更新；高性能设计会做 speculative update，并在 mispredict 时回滚 history。

| 状态 | 是否架构可见 | 错路上能否更新 | 处理原则 |
|---|---|---|---|
| GPR/CSR/memory | 是 | 不能 | 必须由 valid commit 控制 |
| BHT/PHT | 否 | 可以推测更新但需恢复策略 | 防止严重污染 |
| BTB | 否 | 通常在真实 branch 解析后更新 | 避免错路 target 污染 |
| RAS | 否但强影响性能 | 推测 push/pop 需要 checkpoint | call/return 错路很常见 |

这和 `0802` 里讲的 flush/kill 是同一条主线：预测错不是错误结果提交了，而是前端沿错路径取进来了一批年轻指令。恢复动作就是把这些 wrong-path 指令的 valid 清掉，PC redirect 到真实 `actual_next_pc`，并确保错路上的 store、CSR 写、MMIO 访问等副作用没有发生。

---

## 第6章 内存模型、一致性和原子操作

当前阶段建议：可以先简单了解概念，最小单核无 cache 教学核通常不需要实现 FENCE/AMO/LR/SC 的完整复杂语义。

### 6.0 memory model 解决什么

单核顺序流水里，程序顺序基本等同于执行顺序。多核、store buffer、cache、乱序执行出现后，不同 hart 观察内存操作的顺序可能不同。

memory model 定义软件可以依赖哪些顺序。

更通俗地说，memory model 回答的是：

```text
程序里 A store 写在 B store 前面，
别的 hart 或设备是不是一定也先看到 A，再看到 B？

程序里 store 后面跟着 load，
硬件能不能让 load 先得到结果？
```

在没有 cache、没有 store buffer、没有多核、没有 DMA 的小 MCU 上，这个问题不明显；一旦有写缓冲、D-cache、DMA 或多个 hart，程序顺序和外部可见顺序就可能不同。memory model 给软件和硬件划定边界：硬件可以优化到什么程度，软件需要用什么同步指令表达必须保持的顺序。

### 6.1 coherence 和 consistency

| 概念 | 关注点 | 直觉例子 |
|---|---|---|
| coherence | 多个 cache 对同一地址最终看到一致值 | hart0 写 `X=1`，hart1 之后读 `X` 不应永远读旧值 |
| consistency | 多个地址、多个线程的操作顺序规则 | hart0 先写 `data` 再写 `flag`，hart1 看到 `flag` 后能否保证看到新 `data` |

coherence 更像“同一地址的值对不对”，consistency 更像“不同操作的顺序能不能这样被观察到”。

很多人把两者混在一起。cache coherence 解决的是“同一个地址在多个 cache 里有副本，如何保持一致”；memory consistency 解决的是“多个地址的 load/store，在不同 hart 看来允许出现哪些顺序”。即使 coherence 做对了，如果没有合适的 FENCE/acquire/release，软件仍可能在同步顺序上出错。

### 6.2 store buffer

store buffer 用于让 store 不必阻塞后续指令：

```text
pipeline store -> store buffer -> D-cache / bus
```

它提升性能，但会影响 load/store 顺序：

- 后续 load 可能要从 store buffer forwarding。
- FENCE 可能要等待 store buffer drain。
- device memory store 不能随意延迟或合并。

store buffer 让顺序流水线也出现“提交”和“对外可见”不同步的问题。store 指令可以在 CPU 内部 commit，但写事务还排在 buffer 里，尚未到达 D-cache、总线或外设。

如果 store buffer 已满，新来的 store 没有队列项可用，就会反压流水线。这个现象可以看成 `0802` 第7章 structural hazard 的队列版本：冲突资源不再是 ALU 或 RAM 端口，而是 store buffer entry、D-cache 写入口或下游 bus 通道。

| 访问类型 | 能否进入 store buffer | 是否允许合并/延迟 | 说明 |
|---|---|---|---|
| normal cacheable store | 通常可以 | 可以按 memory model 约束优化 | 性能收益大 |
| uncached normal store | 可以但需保持顺序 | 通常更保守 | 取决于平台属性 |
| device/MMIO store | 通常强顺序或不合并 | 不应随意合并/重排 | 防止外设副作用错序 |
| AMO/LR/SC | 需要特殊处理 | 不能当普通 store | 涉及原子性和 reservation |

后续 load 如果访问地址命中 store buffer，需要 store-to-load forwarding，否则会读到旧值。但如果 load 是 MMIO 或带强顺序属性，通常不能随便从普通 store buffer 绕过规则。

一个最小例子：

```text
store [A] = 1   -> 进入 store buffer，尚未写到 cache/bus
load  [B]       -> 如果和 A 无关，硬件可能先执行
```

这能提升性能，因为 store 不必一直堵住后续指令。但如果 `[A]` 是设备 descriptor，`[B]` 或后续 MMIO doorbell 依赖它对设备可见，就必须用 FENCE 或设备内存属性约束顺序。

### 6.3 RISC-V RVWMO

RISC-V 基础内存模型是 RVWMO，属于弱内存顺序模型。弱内存模型允许硬件做更多重排，但软件需要用 FENCE、acquire/release、AMO、LR/SC 来表达同步。

面试不要求背完整公理，但要知道：

- 普通 load/store 不一定给出最强顺序。
- FENCE 用来约束前后内存操作可见顺序。
- 原子操作用于锁、同步和无锁数据结构。

“弱”不是“乱来”，而是规范允许硬件在不破坏单线程语义和同步规则的前提下重排、缓冲或合并某些 memory 操作。软件如果需要跨 hart 或跨设备建立顺序，必须显式表达。这样硬件能获得性能空间，软件也有明确工具保证正确性。

### 6.4 FENCE

`FENCE` 约束前后内存操作的可见顺序。

典型用途：

- 写 MMIO 配置后再启动设备。
- 读设备状态前保证之前的写已完成。
- 多核同步前后建立顺序。

硬件实现中，FENCE 通常至少要处理三件事：

```text
stop issuing younger memory operations
wait older store buffer entries drain as required
wait older cache/bus/uncached transactions reach required visibility point
```

对简单单核、无 store buffer、无 cache 的核，FENCE 可以近似 NOP；但一旦有 write buffer、D-cache、MMIO 或 DMA，FENCE 就不能随便忽略。尤其是设备驱动常见序列：

```text
write descriptor memory
FENCE
write MMIO doorbell
```

如果 FENCE 不等待 descriptor 写入对设备可见，设备可能先看到 doorbell，却读到旧 descriptor。

系统 driver 视角下，这正是常见的“写描述符，再敲门铃”顺序。普通 C 代码里的两次 store 不一定足以表达硬件可见顺序，尤其在有 store buffer、write-back cache、DMA 或弱内存模型时。`FENCE` 是软件告诉硬件“这里的先后关系必须对外成立”的方式，CPU 不能只从单条指令功能角度把它简化掉。

FENCE 的关键不是“让 CPU 慢一下”，而是规定一个可见性边界。边界之前要求完成到某个可见点的 memory 操作，不能被边界之后的操作在外部观察上越过。具体要等到哪里，取决于访问类型、cache 层次、总线协议和平台规定；简单核可以做得保守，高性能核会尽量精确。

### 6.5 AMO 与 LR/SC

AMO 是单条原子读改写操作，例如原子加、交换、与或异或。这里的“原子”指对其他 hart 来说，这个读-改-写不能被拆开观察：不能让别人看到“读了旧值但新值还没写回”的中间状态。

典型用途是锁：

```text
old = atomic_swap(lock, 1)
if old == 0:
  获得锁
else:
  锁已经被别人占用
```

LR/SC 通过保留机制实现条件存储：

- `LR` 读取并建立 reservation。
- `SC` 在 reservation 仍有效时写入成功，否则失败。

硬件要处理：

- reservation 地址粒度。
- 其他写入导致 reservation 失效。
- exception 和 context switch 对 reservation 的影响。

LR/SC 的直觉是“我先读这个地址并声明关注它，之后如果没人改过它，我的 SC 才能成功写入”。它适合构造更灵活的原子序列，但硬件必须定义 reservation 何时建立、何时失效、SC 成功/失败如何返回。

AMO/LR/SC 和第 2 章 CSR 的“原子读改写”名字相似，但对象不同：CSR 原子性主要是单 hart 内一条 CSR 指令的软件可见语义；AMO/LR/SC 面向 memory，多 hart、多 cache 和一致性系统都要观察到正确原子行为。

### 6.6 cache coherence 简述

多核私有 cache 需要 coherence 协议。常见状态：

- I：无效。
- S：共享。
- E：独占干净。
- M：修改脏。
- O：拥有。

协议可以用 snoop 或 directory 实现。普通校招面试通常讲清 MSI/MESI 的状态意义即可，项目面试才会深入事务和 race。

以 MSI 为例：

| 状态 | 含义 | 直觉 |
|---|---|---|
| I | invalid | 本 cache 没有有效副本 |
| S | shared clean | 可能多个 cache 都有，和 memory 一致 |
| M | modified dirty | 只有本 cache 有最新值，memory 可能是旧的 |

coherence 协议要保证：某个 hart 写一个 cache line 时，其他 hart 不能继续把旧副本当新值使用。snoop 做法是广播观察总线事务；directory 做法是用目录记录哪些 cache 持有副本，再定向发送失效或转发请求。入门阶段不用展开协议竞态，但要知道 coherence 是多核 private cache 正确共享 memory 的基础。

---

## 第7章 RTL 结构骨架

### 7.0 Cache lookup 骨架

```systemverilog
always_comb begin
  cache_hit = 1'b0;
  hit_way   = '0;

  for (int w = 0; w < NUM_WAYS; w++) begin
    if (tag_valid[w] && (tag_array_rdata[w] == req_tag)) begin
      cache_hit = 1'b1;
      hit_way   = w[$bits(hit_way)-1:0];
    end
  end
end
```

工程上要补齐：

- 多路同时命中断言。
- uncached bypass。
- miss 状态机。
- refill 和 writeback 仲裁。

lookup 结果还要和请求属性合并。一个简化选择关系是：

```text
if device_or_uncached:
  bypass cache, send exact-size bus transaction
else if cache_hit:
  return/merge cache data
else:
  start miss FSM
```

这意味着 cache controller 不只是 tag compare，还要接收 MMU/PMA/PMP 给出的 memory attribute。若 device memory 误走 cache hit 路径，外设状态就可能被旧 cache line 覆盖；若 normal memory 误走 uncached path，性能会大幅下降但功能可能暂时看不出问题。

### 7.1 D-cache miss FSM

```text
IDLE
  |
  | lookup miss
  v
CHECK_VICTIM
  |
  +-- dirty --> WRITEBACK --> REFILL
  |
  +-- clean ----------------> REFILL
                              |
                              v
                            REPLAY
                              |
                              v
                            IDLE
```

miss FSM 的关键不是状态名字，而是每个状态对外部接口和流水线的承诺：

| 状态 | 对 CPU | 对下级 memory/bus | 关键风险 |
|---|---|---|---|
| `IDLE/LOOKUP` | 可接受新请求 | 无或普通访问 | hit/miss 判定路径过长 |
| `CHECK_VICTIM` | stall 或保存 miss 请求 | 读 victim tag/dirty | victim 信息和请求错配 |
| `WRITEBACK` | miss 请求保持 | 写回 dirty line | 写回地址由旧 tag+index 组成，不能用新 tag |
| `REFILL` | 等待 refill 数据 | 读新 line | refill beat 顺序和 byte lane |
| `REPLAY` | 重放原 load/store | 可更新 cache | store miss 合并丢失 wstrb |

如果支持 flush/exception，miss 请求被 kill 时也要定义行为。已经发出的 bus transaction 通常不能凭空取消，response 回来后要么丢弃、要么填 cache 但不提交原指令，不能让被 kill 的 load 写回 GPR。

### 7.2 TLB lookup 骨架

```systemverilog
always_comb begin
  tlb_hit  = 1'b0;
  tlb_ppn  = '0;
  tlb_perm = '0;

  for (int i = 0; i < TLB_ENTRIES; i++) begin
    if (tlb_valid[i] &&
        (tlb_vpn[i] == req_vpn) &&
        ((tlb_asid[i] == req_asid) || tlb_global[i])) begin
      tlb_hit  = 1'b1;
      tlb_ppn  = tlb_ppn_array[i];
      tlb_perm = tlb_perm_array[i];
    end
  end
end
```

TLB lookup 后还需要 permission check。通常会把 TLB 输出拆成：

```text
translation:
  hit
  ppn
  permission bits
  memory attribute
  page size
  exception candidate
```

大页(superpage)还会让 VPN/PPN 拼接更复杂：低层 page offset 位直接来自虚拟地址，高层 PPN 来自 PTE。面试中不一定要手写完整 Sv39 PTW，但要能说明 TLB 项里除了 PPN，还有权限、ASID、global 和属性，否则无法处理进程隔离、page fault 和 MMIO/cacheable。

### 7.3 Branch predictor 更新骨架

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    pht_counter[update_index] <= 2'b01;
  end else if (predictor_update_valid) begin
    if (branch_taken_actual) begin
      if (pht_counter[update_index] != 2'b11)
        pht_counter[update_index] <= pht_counter[update_index] + 2'b01;
    end else begin
      if (pht_counter[update_index] != 2'b00)
        pht_counter[update_index] <= pht_counter[update_index] - 2'b01;
    end
  end
end
```

真实 predictor update 还要带上“这是哪条分支”的元数据：

```text
update_valid
update_pc
update_index
update_old_history
actual_taken
actual_target
is_call / is_return
was_squashed
```

若 branch 本身被 flush 或 exception kill，通常不应按正常提交更新 BTB/RAS；若是 mispredict，则需要用真实结果修正预测器，同时恢复 wrong-path 上推测修改过的 history。

### 7.4 FENCE 与 store buffer

```text
FENCE accepted
  |
  v
stop issuing younger memory ops
  |
  v
wait store buffer empty
  |
  v
wait outstanding cache/bus ops done
  |
  v
allow younger ops
```

如果 FENCE 只在 decode 阶段当 NOP 处理，带 store buffer 的核很容易违反内存顺序。

---

## 第8章 验证方法

### 8.0 验证目标

这些结构的验证目标可以分成两层：

1. 性能结构内部正确：hit/miss、替换、refill、writeback、预测更新。
2. ISA 可见行为正确：提交顺序、异常、权限、内存顺序、wrong-path 副作用。

### 8.1 Cache directed test

| 场景 | 关注点 |
|---|---|
| cold miss | 第一次访问正确 refill |
| repeated hit | 后续访问命中 |
| conflict miss | 同 index 不同 tag 替换 |
| dirty eviction | write-back 数据正确 |
| byte store | 字节掩码正确 |
| uncached MMIO | 不进入 cache |
| I/D 同步 | 自修改代码或 FENCE.I 类场景 |

### 8.2 TLB/MMU directed test

| 场景 | 关注点 |
|---|---|
| TLB hit | 转换正确 |
| TLB miss | PTW 填充正确 |
| invalid PTE | page fault |
| permission fault | R/W/X/U/S 权限检查 |
| ASID match | 不同进程地址空间隔离 |
| SFENCE.VMA | 旧 TLB 项被清除或失效 |
| access fault | PMP/PMA 或总线错误 |

### 8.3 Branch predictor directed test

覆盖：

- always taken 循环。
- 循环退出。
- 交替 taken/not taken。
- call/return 嵌套。
- BTB alias。
- mispredict 后 wrong-path 不提交。

### 8.4 Memory model directed test

覆盖：

- store buffer forwarding。
- FENCE 前后顺序。
- AMO 原子性。
- LR/SC 成功和失败。
- device memory 不重排。

### 8.5 SVA 示例

#### 8.5.1 cache 不允许多路命中

```systemverilog
// 不可综合：验证断言
assert property (@(posedge clk) disable iff (!rst_n)
  cache_lookup_valid |-> $onehot0(way_hit_vec)
);
```

#### 8.5.2 wrong-path 不能更新架构状态

```systemverilog
// 不可综合：验证断言
property p_wrong_path_no_commit;
  @(posedge clk) disable iff (!rst_n)
    squash_valid |=> !commit_valid_for_squashed_inst;
endproperty

assert property (p_wrong_path_no_commit);
```

#### 8.5.3 FENCE 等待 store buffer drain

```systemverilog
// 不可综合：验证断言
property p_fence_waits_store_buffer;
  @(posedge clk) disable iff (!rst_n)
    fence_commit |-> store_buffer_empty;
endproperty

assert property (p_fence_waits_store_buffer);
```

### 8.6 coverage

覆盖建议：

- cache：hit/miss、clean/dirty victim、不同 way、不同 byte mask。
- TLB：hit/miss/page fault/access fault/permission fault。
- MMU：用户页、内核页、只读页、可执行页、global 页。
- branch：taken/not taken/mispredict/RAS push-pop。
- memory model：FENCE、AMO、LR/SC、store-load 转发。
- MMIO：cacheable/uncached/device memory。

---

## 第9章 时序、综合、后端和 PPA 影响

### 9.0 时序热点

这些结构都是 CPU 里的高风险时序点：

- I-cache tag compare -> next PC。
- D-cache tag compare -> load data。
- TLB lookup -> permission check -> cache access。
- branch predictor lookup -> IF redirect。
- store buffer forwarding compare。

### 9.1 容量、路数和频率权衡

cache 越大不一定越快：

- 容量大：miss 少，但 SRAM 访问慢。
- 路数多：conflict miss 少，但比较器和 MUX 更复杂。
- line 大：空间局部性好，但 refill 更慢。

典型权衡：

| 增加项 | 好处 | 代价 |
|---|---|---|
| cache 容量 | miss rate 下降 | 面积、功耗、访问延迟上升 |
| associativity | conflict miss 下降 | tag 比较和 data MUX 变慢 |
| TLB entries | TLB miss 下降 | CAM 比较面积和功耗上升 |
| predictor size | mispredict 下降 | 面积、功耗、alias 仍可能存在 |

### 9.2 物理设计影响

- I-cache/D-cache 通常靠近 CPU 前端/LSU。
- TLB CAM 和 tag compare 需要短路径。
- branch predictor 影响 IF 阶段布线。
- L2 cache 和 interconnect 更偏 SoC 中心资源。

### 9.3 低功耗影响

可优化：

- way prediction，减少多路 data array 读。
- clock gating predictor 更新。
- TLB 分级，小 TLB 命中时不访问大 TLB。
- uncached 设备访问绕过 cache。

---

## 第10章 常见 bug、边界条件和 debug 方法

### 10.0 常见 bug

| bug | 现象 | 修复方向 |
|---|---|---|
| tag/index/offset 切错 | 命中错 line | 按容量、路数、line size 重新推导 |
| dirty eviction 丢写回 | 内存数据随机旧值 | eviction 前检查 dirty |
| byte mask 错 | SB/SH 写坏相邻字节 | 小端序 byte lane 校验 |
| MMIO 被缓存 | 外设状态异常 | device memory 走 uncached path |
| TLB 没看 ASID | 进程间串地址 | TLB tag 加 ASID/global |
| SFENCE.VMA 无效 | 页表改了还用旧映射 | flush 或精确失效 TLB |
| 权限检查漏掉 X/W/R | 非法访问没 page fault | PTE 权限表驱动验证 |
| RAS 未随 flush 恢复 | return 预测越来越错 | checkpoint 或保守更新 |
| predictor wrong-path 更新 | 预测器污染 | 在解析点或提交点更新 |
| FENCE 当 NOP | 多核或设备顺序错 | 等 store buffer 和 outstanding 事务完成 |
| LR/SC reservation 没清 | 原子操作错误成功 | 其他写、异常、上下文切换清 reservation |

### 10.1 边界条件

- cache line 跨页时，TLB 和 cache 异常处理要清楚。
- VIPT cache 的 index 位不能随便越过 page offset。
- D-cache miss 与 store buffer 命中同时发生时要定义优先级。
- branch mispredict 与 exception 同拍时，要按指令年龄和提交点处理。
- page fault 的 `stval/mtval` 应给出有用地址。

### 10.2 debug 方法

建议从第一条错误 commit 开始倒查：

1. 是 PC 错、数据错、异常错还是顺序错。
2. PC 错先看 predictor/BTB/RAS/redirect。
3. 数据错先看 cache hit/miss、writeback、byte mask。
4. 地址错先看 TLB、ASID、PTE、SFENCE.VMA。
5. 顺序错先看 store buffer、FENCE、AMO、LR/SC。

---

## 第11章 面试问法

### 11.0 基础题

#### 1. cache 为什么能提高性能

简洁答法：

```text
cache 利用时间局部性和空间局部性，把近期或附近要访问的数据放在更靠近 CPU 的小容量高速存储中，从而降低平均访存时间。
```

#### 2. direct-mapped 和 set-associative 区别

答题要点：

- direct-mapped 一个 index 只有一路，简单快但冲突多。
- set-associative 一个 set 有多路，冲突少但比较器和 MUX 更复杂。

#### 3. TLB 是什么

答题要点：

- TLB 是虚拟地址到物理地址转换结果的缓存。
- 它避免每次访存都走页表遍历。

### 11.1 进阶追问

#### 1. 为什么 MMIO 不能 cache

要点：

- MMIO 有读写副作用。
- cache 会导致读旧值、写延迟、写合并或重复触发。
- 设备区应走 uncached/device path。

#### 2. VIPT cache 有什么问题

要点：

- 可以并行 TLB 和 cache index。
- 但可能有 synonym/alias 问题。
- 通常要求 index 位在 page offset 内，或靠 OS 页着色/硬件处理。

#### 3. 分支预测错误如何恢复

要点：

- flush wrong-path 指令。
- redirect PC 到真实目标。
- 恢复或修正推测状态。
- 保证 wrong-path 不提交。

#### 4. FENCE 解决什么

要点：

- 约束前后内存操作可见顺序。
- 对 store buffer、uncached/device access、多核同步都重要。

### 11.2 项目追问

#### 1. 你的 cache miss 状态机怎么设计

回答框架：

- lookup miss。
- 选 victim。
- dirty 则 writeback。
- refill 新 line。
- 更新 tag/data。
- replay 原请求。

#### 2. 你的 MMU 怎么产生 page fault

回答框架：

- TLB miss 触发 PTW。
- PTW 读取 PTE。
- 检查 valid、R/W/X/U、A/D 等权限。
- 不满足则产生 page fault，并写入 trap 相关 CSR。

#### 3. 如何验证分支预测

回答框架：

- directed 覆盖循环、跳转、call/return、交替分支。
- random 与 ISS 比较 commit trace。
- SVA 保证 wrong-path 不提交。
- coverage 统计预测命中/错误和 RAS 行为。

---

## 第12章 练习题与答案要点

### 12.1 练习题 1：计算 cache 位划分

题目：

```text
32KB cache，4-way，line size 64B，物理地址 32 bit，求 offset/index/tag 位宽。
```

答案：

$$
Sets = \frac{32KB}{4 \times 64B} = 128
$$

$$
offset = \log_2(64) = 6
$$

$$
index = \log_2(128) = 7
$$

$$
tag = 32 - 7 - 6 = 19
$$

### 12.2 练习题 2：为什么 write-back 需要 dirty bit

答案要点：

- dirty 表示 cache line 已被修改但还没写回下级。
- 替换 dirty line 前必须 writeback。
- clean line 可以直接丢弃。

### 12.3 练习题 3：TLB miss 和 page fault 区别

答案要点：

- TLB miss 是转换缓存没有命中，可能通过 PTW 填上。
- page fault 是页表或权限不允许，必须进入 trap。

### 12.4 练习题 4：2-bit predictor 循环行为

题目：

```text
一个循环分支连续 taken 9 次，最后 not taken 1 次。2-bit 预测器从 strongly taken 开始，会错几次？
```

答案要点：

- 前 9 次 taken 都预测正确。
- 最后一次 not taken 预测为 taken，错 1 次。
- 计数器从 strongly taken 降到 weakly taken。

### 12.5 练习题 5：FENCE 为什么不能当 NOP

答案要点：

- 带 store buffer 或 outstanding bus transaction 时，后续 load/store 可能越过前面的 store。
- 对设备寄存器和多核同步会产生可见顺序错误。
- FENCE 应等待相关事务达到规定顺序点。

---

## 第13章 与其他章节的关联

### 13.1 必须回看的章节

- `0802 RISC-V五级流水线与Hazard.md`：branch flush、load-use、stall 和精确提交。
- `0803 CSR、异常中断与特权级.md`：page fault/access fault 如何进入 trap。
- `0804 RISC-V SoC、MMIO与外设互联.md`：device memory、MMIO 和外设访问。
- `060x` 存储器、FIFO、cache 类专题：更底层的 SRAM/cache 结构。
- `070x` 总线、DMA、SoC 互联专题：cache miss refill、DMA 和一致性。
- `100x` 验证专题：随机指令、reference model、SVA 和 coverage。

### 13.2 本篇总结

cache、TLB、MMU、分支预测和内存模型，是 CPU 从“能顺序执行指令”走向“能高性能运行复杂软件”的核心结构。

面试中最重要的不是背名词，而是能把每个结构说成四句话：

- 它解决什么性能或功能问题。
- 硬件结构怎么实现。
- 和流水线、异常、MMIO、总线有什么交互。
- 验证中最容易错在哪里。
