# Checksum 问题交接总结

## 1. 问题背景

### 当前要解决的问题
- 自动模式切换时触发程序校验和不一致报警：
  - `ALARM_PROGRAM_CHANGE_ERR`
  - 典型日志：
    - `AUTO checksum mismatch action=2 mode=... mold=0 program_sum=62716 mold_sum=25219`

### 预期行为 vs 实际问题
- 预期行为：
  - 上位机下发模具程序后，主机重新计算的程序 checksum 应与上位机下发的 `mold_sum` 一致，切换 `CMD_AUTO` 不应报警。
- 实际问题：
  - 主机稳定算出 `program_sum=62716`
  - 上位机稳定下发 `mold_sum=25219`
  - 两边不一致，进入自动时报错。

## 2. 当前进展

### 已做尝试
- 给主机加了定位日志，确认：
  - `mold_sum` 的写入来源
  - `CMD_AUTO` 的触发来源
  - `programCheckSum()` 的分项结果
  - 实际下发到主机的每条教导指令
  - 主机参与 checksum 的每条已解析指令
- 对照了上位机仓库 `/home/harry/robot/HMI-RX_` 的 checksum 实现。
- 对照了 Host/HMI 两边 `FunctionCmd` 枚举。
- 已抓到一组 Host/HMI 同时日志，完成了两边逐条 checksum 对账。

### 已改文件
- `/home/harry/robot/EC-APRobotHost_/ec_develop/action/action.cpp`
  - `SetCurrentAction()` 增加 `CMD_AUTO` 触发日志
  - `CMD_AUTO` 分支增加 checksum mismatch 日志
  - mismatch 时调用 `AutoRun->DumpProgramCheckSumDetail()`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/action/action.h`
  - 新增 `GetCurrentAction()`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/action/AutoAction.cpp`
  - `programCheckSum()` 增加 `action_sum/use_p_sum/tool_sum` 分项日志
  - 新增 `DumpProgramCheckSumDetail()`，打印 `program/row/step/cmd/sum`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/action/AutoAction.h`
  - 声明 `DumpProgramCheckSumDetail()`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/Src/module/data.cpp`
  - `setMoldSum` 打印
  - `ICAddr_System_Retain_1` 写 `CMD_AUTO` 打印
  - 教导程序初始化、写入、解析成功时打印 `group/program/row/step/cmd/sum`
- `/home/harry/robot/HMI-RX_/datamanerger/icrobotmold.cpp`
  - 在 `ICRobotMold::CheckSum()` 中新增 HMI 侧逐条 checksum 日志：
    - `hmi checksum detail`
    - `hmi checksum program_sum`
    - `hmi checksum mold_addr`
    - `hmi checksum total_sum`
- `/home/harry/robot/HMI-RX_/datamanerger/icrobotmold.h`
  - 将 `UIStepFromCompiledLine(int)` 改为 `const`
  - 原因：修复在 `CheckSum() const` 中调用时报的 `discards qualifiers` 编译错误

## 3. 本次最新结论

### 3.1 已确认：Host/HMI 当前 checksum 算法结果一致
- 这次抓到的 HMI 日志显示：
  - `hmi checksum total_sum 854788 ret 62716`
- 同一时刻 Host 日志显示：
  - `programCheckSum mold=0 action_sum=854771 use_p_sum=17 tool_sum=0 total_sum=854788 ret=62716`
- 且两边逐条动作的 `cmd/sum` 完全一致：
  - 主程序 `program=0` 的 16 条动作逐项一致
  - `program=1..16` 的 `F_CMD_END` 各自 `sum=5536`，两边一致
- 结论：
  - 当前看到的 Host/HMI checksum 算法没有分歧
  - “Host 现场重算为 62716，但 HMI 现场重算不是 62716” 这一条已经被本次日志排除

### 3.2 本次报警的直接原因：Host 先拿到了旧的 `mold_sum=25219`
- 本次首次报警前 Host 日志顺序是：
  - `setMoldSum ... old=25219 new=25219`
  - 随后进入 `CMD_AUTO`
  - `program_sum=62716 mold_sum=25219`
  - 于是触发 `ALARM_PROGRAM_CHANGE_ERR`
- 随后 Host 又收到一次新的 checksum：
  - `setMoldSum ... old=25219 new=62716`
- 从这一刻开始再次进入自动：
  - Host 现场重算仍是 `62716`
  - 保存的 `mold_sum` 也已经变成 `62716`
  - 因此报警消失，不再复现
- 结论：
  - 这次故障的直接原因不是“重算结果算错”
  - 而是“切到自动时，Host 内存里暂时还保存着旧的 mold_sum”

### 3.3 当前最可疑方向：HMI 不同时机通过不同路径发送了不同的 `mold_sum`
- HMI 中 `SendMoldSum()` 有多条调用路径：
  - 自动旋钮切自动时：
    - `PanelRobotController::sendKnobCommandToHost()`
    - 使用 `GetAppointmentMold(rid)->CheckSum()`
  - 保存主程序/子程序后：
    - `saveMainProgram()/saveSubProgram()`
    - 使用 `CurrentMold()->CheckSum()`
  - 加载当前模具后：
    - `panelrobotcontroller.cpp:3974`
    - 使用 `CurrentMold()->CheckSum()`
  - 发送预约模具到 Host 时：
    - `panelrobotcontroller.cpp:7027`
    - 使用 `mold->CheckSum()`
- 由于不同路径使用的对象并不完全相同：
  - `CurrentMold()`
  - `GetAppointmentMold(rid)`
  - `mold`
- 当前高优先级怀疑：
  - 某条发送路径在某个时机先发出了旧对象上的 `25219`
  - 后续另一条路径又重新计算并发出了正确的 `62716`
- 这能解释为什么：
  - 同一套程序，HMI 现场重算明明是 `62716`
  - 但 Host 之前已经收到过一次 `25219`

## 4. 关键代码上下文

### A. Host 自动模式切换时比较 checksum
文件：`/home/harry/robot/EC-APRobotHost_/ec_develop/action/action.cpp`

```cpp
case CMD_AUTO: {
    MotionSetAllJogAccAndDecTime(false);
    MotionSetRouteAccAndDecTime(false);
    all_para->d.P.sys.para.internal[ICAddr_System_Retain_16] = 0;
    ResetCoor();
    ResetTimer();
    AutoRun->ProgremRunningInfo(4, -1, -1);

    int program_sum = AutoRun->programCheckSum();
    uint32_t mold_sum = MoldManage::getCurrentMold()->getMoldSum();
    if (program_sum != (int)mold_sum) {
        hc_debug("AUTO checksum mismatch action=%u mode=%d mold=%d "
                 "program_sum=%d mold_sum=%u",
                 current_action, mode,
                 MoldManage::getCurrentMoldIndex(), program_sum, mold_sum);
        AutoRun->DumpProgramCheckSumDetail();
        errPLC = ALARM_PROGRAM_CHANGE_ERR;
    }
} break;
```

### B. Host checksum 算法
文件：`/home/harry/robot/EC-APRobotHost_/ec_develop/action/AutoAction.cpp`

```cpp
int AutoAction::programCheckSum(void) {
    UINT64 sum = 0;
    UINT64 action_sum = 0;
    UINT64 use_p_sum = 0;
    UINT64 tool_sum = 0;

    for (int i = 0; i <= ProgramSub16; i++) {
        UINT64 program_action_sum = 0;
        ActionQueue *a_queue =
            MoldManage::getCurrentMold()->GetActionQueueHandle(i);
        int s = a_queue->size();
        if (s) {
            for (int m = 0; m < s; m++) {
                ActionRow *a_row = a_queue->get(m);
                int a = a_row->size();
                for (int n = 0; n < a; n++) {
                    ActionBase *a_base = a_row->get(n);
                    UINT32 one_sum = a_base->GetSum();
                    sum += one_sum;
                    action_sum += one_sum;
                    program_action_sum += one_sum;
                }
            }
            hc_debug("programCheckSum program=%d rows=%d action_sum=%llu", i, s,
                     (unsigned long long)program_action_sum);
        }
    }

    use_p_sum += all_para->d.P.m.para.use_p.bit.main_p +
                 all_para->d.P.m.para.use_p.bit.sub1 +
                 all_para->d.P.m.para.use_p.bit.sub2 +
                 all_para->d.P.m.para.use_p.bit.sub3 +
                 all_para->d.P.m.para.use_p.bit.sub4 +
                 all_para->d.P.m.para.use_p.bit.sub5 +
                 all_para->d.P.m.para.use_p.bit.sub6 +
                 all_para->d.P.m.para.use_p.bit.sub7 +
                 all_para->d.P.m.para.use_p.bit.sub8 +
                 all_para->d.P.m.para.use_p.bit.sub9 +
                 all_para->d.P.m.para.use_p.bit.sub10 +
                 all_para->d.P.m.para.use_p.bit.sub11 +
                 all_para->d.P.m.para.use_p.bit.sub12 +
                 all_para->d.P.m.para.use_p.bit.sub13 +
                 all_para->d.P.m.para.use_p.bit.sub14 +
                 all_para->d.P.m.para.use_p.bit.sub15 +
                 all_para->d.P.m.para.use_p.bit.sub16 +
                 all_para->d.P.m.para.use_p.bit.install +
                 all_para->d.P.m.para.use_p.bit.type +
                 all_para->d.P.m.para.use_p.bit.s_IO_enable +
                 all_para->d.P.m.para.use_p.bit.res;
    sum += use_p_sum;

    for (int i = 0; i < 36; i++) tool_sum += all_para->d.P.m.para.tool.p[i];
    sum += tool_sum;

    int ret = (-sum) & 0xFFFF;
    hc_debug("programCheckSum mold=%d action_sum=%llu use_p_sum=%llu "
             "tool_sum=%llu total_sum=%llu ret=%d",
             MoldManage::getCurrentMoldIndex(), (unsigned long long)action_sum,
             (unsigned long long)use_p_sum, (unsigned long long)tool_sum,
             (unsigned long long)sum, ret);
    return ret;
}
```

### C. Host 收到并解析教导程序
文件：`/home/harry/robot/EC-APRobotHost_/ec_develop/Src/module/data.cpp`

```cpp
} else if (start == ICAddr_System_Retain_80) {
    union {
        struct {
            UINT32 len : 20;
            UINT32 teach_group_id : 4;
            UINT32 teach_id : 7;
            UINT32 is_clear : 1;
        };
        int32_t all;
    } teach_info;
    teach_info.all = data_block.data_block32[ICAddr_System_Retain_80];
    teach_id = teach_info.teach_id;
    teach_group_id = teach_info.teach_group_id;
    hc_debug("teach init group=%u program=%u len=%u is_clear=%u",
             teach_group_id, teach_id, teach_info.len, teach_info.is_clear);
}

UINT16 DataWriteTeach32(const UINT32 *data, UINT16 start, UINT16 length) {
    if (teach_buff != NULL) {
        memcpy(teach_buff + start, data, length * sizeof(UINT32));
        teach_buff_lenth_cnt = start + length;
        hc_debug("teach write group=%u program=%u start=%u len=%u first=%u "
                 "last=%u total_written=%u/%u",
                 teach_group_id, teach_id, start, length, data[0],
                 data[length - 1], teach_buff_lenth_cnt, teach_buff_lenth);
    }
    return length;
}

void TeachDataAnalytical(void) {
    if (teach_buff != NULL && teach_buff_lenth_cnt == teach_buff_lenth) {
        int cmd_len = 0;
        hc_debug("teach parse begin group=%u program=%u total_len=%u",
                 teach_group_id, teach_id, teach_buff_lenth);
        while (cmd_len < teach_buff_lenth) {
            UINT32 cmd = teach_buff[cmd_len];
            UINT32 temp_len = cmd_analytical(cmd, &action);
            if (action->Analytical(temp_len, teach_buff + cmd_len)) {
                action->AnalyticalEnd(teach_id);
                hc_debug("teach parse single group=%u program=%u row=%d "
                         "step=0 offset=%d cmd=%u para_len=%u sum=%d",
                         teach_group_id, teach_id, action_queue->size(),
                         cmd_len, action->GetFunctionCmd(), temp_len,
                         action->GetSum());
                cmd_len += action->GetParaLen();
            }
        }
    }
}
```

### D. HMI 发 checksum 的地方
文件：`/home/harry/robot/HMI-RX_/virtualhost/icrobotvirtualhost.cpp`

```cpp
bool ICRobotVirtualhost::SendMoldSum(ICVirtualHostPtr hostPtr,
                                     const quint32 &sum, int aid) {
    ICRobotTransceiverData *toSentFrame = new ICRobotTransceiverData();
    toSentFrame->SetAddr(ICAddr_System_Retain_11);
    QVector<quint32> sdata;
    sdata.append(aid);
    sdata.append(sum);
    toSentFrame->SetData(sdata);
    hostPtr->AddCommunicationFrame(toSentFrame);
    return true;
}
```

### E. HMI checksum 算法
文件：`/home/harry/robot/HMI-RX_/datamanerger/icrobotmold.cpp`

```cpp
quint32 CompileInfo::CheckSum() const {
    quint32 sum = 0;
    for(int i = 0; i < compiledProgram_.size(); ++i) {
        if(compiledProgram_.at(i).at(0) != F_CMD_SYNC_END &&
           compiledProgram_.at(i).at(0) != F_CMD_SYNC_START &&
           compiledProgram_.at(i).at(0) != F_CMD_PATH_SMOOTH_BEGIN &&
           compiledProgram_.at(i).at(0) != F_CMD_PATH_SMOOTH_END)
            sum += compiledProgram_.at(i).last();
    }
    return sum;
}

quint32 ICRobotMold::CheckSum() const {
    quint64 sum = 0;
    for(int i = 0; i < programs_.size(); ++i) {
        sum += programs_.at(i).CheckSum();
    }
    QList<const ICAddrWrapper*> moldAddr = ICAddrWrapper::MoldAddrs();
    for(int i = 0, size = moldAddr.count(); i < size; ++i) {
        const ICAddrWrapper* ma = moldAddr.at(i);
        if(ma != &m_rw_0_32_2_214 &&
           ma != &m_rw_0_32_2_215 &&
           ma != &m_rw_0_32_2_216 &&
           ma != &m_rw_0_32_2_217 &&
           ma != &m_rw_0_32_2_218 &&
           ma != &m_rw_0_32_2_219) {
            sum += fncCache_.ConfigValue(ma);
        }
    }
    return (-sum) & 0xFFFF;
}
```

### F. HMI 新增逐条 checksum 日志
文件：`/home/harry/robot/HMI-RX_/datamanerger/icrobotmold.cpp`

```cpp
quint32 ICRobotMold::CheckSum() const
{
    quint64 sum = 0;
    for(int i = 0; i < programs_.size(); ++i)
    {
        const CompileInfo& program = programs_.at(i);
        const ICActionProgram compiledProgram = program.ProgramToBareData();
        quint64 programSum = 0;

        for(int line = 0; line < compiledProgram.size(); ++line)
        {
            const ICMoldItem& item = compiledProgram.at(line);
            if(item.isEmpty()) continue;

            quint32 cmd = item.at(0);
            if(cmd == F_CMD_SYNC_END || cmd == F_CMD_SYNC_START ||
               cmd == F_CMD_PATH_SMOOTH_BEGIN || cmd == F_CMD_PATH_SMOOTH_END)
                continue;

            quint32 lineSum = item.last();
            QPair<int, int> realStep =
                program.UIStepToRealStep(program.UIStepFromCompiledLine(line));
            qDebug() << "hmi checksum detail"
                     << "program" << i
                     << "compiled_line" << line
                     << "real_row" << realStep.first
                     << "real_step" << realStep.second
                     << "cmd" << cmd
                     << "line_sum" << lineSum
                     << "item_len" << item.size();
            programSum += lineSum;
        }
        qDebug() << "hmi checksum program_sum" << "program" << i << "sum" << programSum;
        sum += programSum;
    }

    for (auto ma : ICAddrWrapper::MoldAddrs()) {
        quint32 value = fncCache_.ConfigValue(ma);
        if(value != 0) {
            qDebug() << "hmi checksum mold_addr" << ma->ToString() << "value" << value;
        }
        sum += value;
    }
    qDebug() << "hmi checksum total_sum" << sum << "ret" << ((-sum) & 0xFFFF);
    return (-sum) & 0xFFFF;
}
```

### G. 当前已确认的主程序内容
来源：
- Host `teach parse single ...`
- Host `programCheckSum detail ...`

主程序 `program=0` 当前解析结果：

```text
row 0:  cmd=10    F_CMD_LINE3D_MOVE_POSE
row 1:  cmd=910   F_CMD_INJECT_WAIT_MODE_OPEN
row 2:  cmd=10    F_CMD_LINE3D_MOVE_POSE
row 3:  cmd=200   F_CMD_IO_OUTPUT
row 4:  cmd=10    F_CMD_LINE3D_MOVE_POSE
row 5:  cmd=200   F_CMD_IO_OUTPUT
row 6:  cmd=10    F_CMD_LINE3D_MOVE_POSE
row 7:  cmd=10    F_CMD_LINE3D_MOVE_POSE
row 8:  cmd=106   F_CMD_FSIO_CHECK
row 9:  cmd=200   F_CMD_IO_OUTPUT
row 10: cmd=10    F_CMD_LINE3D_MOVE_POSE
row 11: cmd=10    F_CMD_LINE3D_MOVE_POSE
row 12: cmd=106   F_CMD_FSIO_CHECK
row 13: cmd=200   F_CMD_IO_OUTPUT
row 14: cmd=10    F_CMD_LINE3D_MOVE_POSE
row 15: cmd=60000 F_CMD_END
```

子程序现状：

```text
program 1..16: 各只有 1 条 F_CMD_END
program 18 (RETURN): row0 cmd=4(F_CMD_JOINT_MOVE_POINT), row1 cmd=60000(F_CMD_END)
program 19 (ORIGIN): 仅 1 条 F_CMD_END
```

### H. 本次对账得到的关键信息

- HMI 本次逐条日志最终结果：
  - `hmi checksum total_sum 854788 ret 62716`
- Host 本次逐条日志最终结果：
  - `programCheckSum mold=0 action_sum=854771 use_p_sum=17 tool_sum=0 total_sum=854788 ret=62716`
- Host 首次报警前保存的 `mold_sum`：
  - `setMoldSum target_mold=0 current_mold=0 old=25219 new=25219`
- Host 后续被覆盖为正确值：
  - `setMoldSum target_mold=0 current_mold=0 old=25219 new=62716`
- 说明：
  - 本次报警不是“双方现场重算口径不同”
  - 而是“Host 在切自动前拿到的是旧 checksum”

## 5. 问题卡点

### 当前卡在哪里
- 已经确认本次 Host/HMI 现场重算结果一致，问题不在当前 checksum 算法本身。
- 现在真正未闭环的是：
  - `25219` 是哪一条 HMI 发送路径发出来的
  - 当时使用的是哪个 mold 对象
  - 为什么它在后续又会被 `62716` 覆盖

### 还没解释清楚的现象
- 为什么 HMI 某次发送给 Host 的值是 `25219`，而同一版本 HMI 现场重算又是 `62716`。
- `sendKnobCommandToHost(CMD_AUTO)` 使用 `GetAppointmentMold(rid)`，它和 `CurrentMold()` / `mold` 的生命周期、刷新时机是否完全一致，还没核实。
- 是否存在：
  - 切自动时先发旧预约模具 checksum
  - 随后加载/保存/同步流程再发新 checksum
- Host 与 HMI 的 `hccommparagenericdef.h` 已分叉这件事仍建议保留关注，但从本次日志看，它不是这次故障的一阶原因。

### `program_sum` / `mold_sum` 与现有日志的关系
- `program_sum=62716`
  - 对应 Host 日志：
    - `programCheckSum mold=0 action_sum=854771 use_p_sum=17 tool_sum=0 total_sum=854788 ret=62716`
  - 关系：
    - `program_sum == ret`
    - `ret = (-total_sum) & 0xFFFF`
  - 其中 `total_sum` 来自：
    - 所有已解析动作的 `ActionBase::GetSum()`
    - `use_p_sum`
    - `tool_sum`
  - 这些动作明细已由下列日志展开：
    - `teach parse single ... cmd=... sum=...`
    - `programCheckSum detail ... row=... cmd=... sum=...`

- `mold_sum=25219`
  - 对应 Host 日志：
    - `setMoldSum target_mold=0 current_mold=0 old=0 new=25219`
    - 后续重复写入时：
      - `setMoldSum target_mold=0 current_mold=0 old=25219 new=25219`
  - 关系：
    - `mold_sum == setMoldSum` 日志里的 `new`
  - 它不是 Host 现场重算的值，而是 HMI 通过 `ICAddr_System_Retain_11` 下发并写入 `MoldInfo::mold_sum` 的值。

- 结论：
  - `program_sum` 是 Host 基于当前内存中已解析程序现场重算出来的结果
  - `mold_sum` 是 HMI 之前下发并存储的结果
  - 当前报警本质就是这两者不一致

- 本次新增关键事实：
  - 同版本 HMI 后续又下发了 `62716`
  - Host 收到后：
    - `setMoldSum target_mold=0 current_mold=0 old=25219 new=62716`
  - 之后再次进入自动即不再报警

### 为什么现在“又复现不了”
- 因为当前 Host 内存里的 `mold_sum` 已经被后续正确值 `62716` 覆盖。
- 在不重置到旧状态、且 HMI 不再次先发旧值 `25219` 的情况下：
  - Host 现场重算是 `62716`
  - 保存值也是 `62716`
  - 所以不会再触发 `ALARM_PROGRAM_CHANGE_ERR`

## 6. 已排除的方向

- 不是“当前模号切错了”
  - 日志已确认一直是 `mold=0`
- 不是“主机收到的数据包丢了/解析失败了”
  - `teach init -> teach write -> teach parse` 全链路正常
  - 主程序 `program=0` 成功解析为 16 行
- 不是“主机运行时数据在漂”
  - 两次进入自动时 `program_sum` 都稳定为 `62716`
- 不是单纯 `use_p` / `tool` 导致
  - Host 日志：`use_p_sum=17`，`tool_sum=0`
  - 主要差异来自 `action_sum=854771`
- 不是“当前 Host/HMI checksum 算法不同”
  - 本次 HMI 逐条日志与 Host 逐条日志已逐项对齐
  - 双方最终都算出：
    - `total_sum=854788`
    - `ret=62716`

## 7. 下一步建议

如果继续分析，优先做这些：

1. 在 HMI 所有 `SendMoldSum()` 调用点前再加一层来源日志：
   - 打印：
     - 调用函数名
     - `rid/id`
     - mold 名称
     - 指针地址或对象来源（`CurrentMold` / `GetAppointmentMold` / `mold`）
     - 即将发送的 `sum`
   - 重点调用点：
     - `sendKnobCommandToHost(CMD_AUTO)`
     - `saveMainProgram()`
     - `saveSubProgram()`
     - `panelrobotcontroller.cpp:3974`
     - `panelrobotcontroller.cpp:7027`

2. 下次若再次复现，优先观察日志顺序：
   - 第一条发给 Host 的 `mold_sum` 是多少
   - 哪个发送路径先发
   - `25219` 是否总是来自同一个调用点

3. 若想继续缩小范围，重点核对：
   - `GetAppointmentMold(rid)` 与 `CurrentMold()` 是否可能在某些时机内容不同步
   - 自动切换时是否存在：
     - 旧模具对象先发送 checksum
     - 新模具对象后发送 checksum

4. 若后续再次复现且需要临时规避报警：
   - 优先确认在发送 `CMD_AUTO` 前，HMI 是否已经把正确的 `62716` 发到 Host
   - 问题本质更像“发送时序 / 对象不一致”，而不是“算法公式错误”

5. 中长期建议：
  - Host 与 HMI 共用同一份 `FunctionCmd` 协议头，避免继续分叉。
