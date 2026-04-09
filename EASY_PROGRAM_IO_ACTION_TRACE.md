# Easy Program 插入指令动作追踪说明

## 范围

关注界面中的这 6 个快捷插入项：

- 喷油
- 传送带
- 预留1
- 预留2
- 预留3
- 预留4

对应界面文件：

- `qml/App_HAMOUI/teach/EasyProgramFunctionPanel.qml`
- `qml/App_HAMOUI/teach/extents/ExtentActionDefine.js`

主机代码追踪到：

- `/home/harry/robot/EC-APRobotHost_/ec_develop/Include/hmi/protocol/hccommparagenericdef.h`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/Src/module/data.cpp`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/instruction/IOOutput.h`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/instruction/IOOutput.cpp`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/instruction/IOIntervalOutput.h`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/instruction/IOIntervalOutput.cpp`
- `/home/harry/robot/EC-APRobotHost_/ec_develop/action/IOTask.cpp`

## 结论先看

这 6 个快捷插入项当前都走同一条动作链：

`EasyProgramFunctionPanel.qml`
-> `createOutputQuickAction()`
-> `ExtentActionDefine.extentOutputAction`
-> `action = 200`
-> 主机 `F_CMD_IO_OUTPUT`
-> `new IOOutput`
-> `IOOutput::process()`
-> `IOOperation()`
-> `SetIO()`

也就是说：

1. 它们当前走的是普通输出动作 `F_CMD_IO_OUTPUT = 200`。
2. 没有走间隔输出动作 `F_CMD_IO_INTERVAL_OUTPUT = 201`。
3. 界面上的“间隔次数”当前没有参与生成 action，主机也就不会进入 `IOIntervalOutput`。
4. 这些点位都是普通 `Y` 点，当前“动作时间”落到主机里实际用的是 `delay`，语义更接近“延时后输出”，不是“保持输出这么久”。

## 界面层映射

### 1. 点位名

在 `EasyProgramFunctionPanel.qml` 中：

- `auxiliaryDeviceRows = [喷油, 传送带]`
- `auxiliarySignalPoints = ["Y025", "Y033"]`
- `reserveSignalRows = [预留1, 预留2, 预留3, 预留4]`
- `reserveSignalPoints = ["Y034", "Y035", "Y036", "Y037"]`

因此按索引对应关系：

| 界面项 | 点位 |
| --- | --- |
| 喷油 | Y025 |
| 传送带 | Y033 |
| 预留1 | Y034 |
| 预留2 | Y035 |
| 预留3 | Y036 |
| 预留4 | Y037 |

### 2. 生成 action 的入口

这几项最终都调用 `createOutputQuickAction(pointName, isOn, delay, title)`：

- 预留1~4：`createReserveSignalQuickAction()`
- 喷油/传送带：`createAuxiliaryQuickAction()`

两者都只传了 3 个核心参数：

- 点位名 `pointName`
- 开/关 `isOn`
- 时间框 `delay`

没有传“间隔次数”。

### 3. 实际生成的 action

`createOutputQuickAction()` 内部调用：

```js
Teach.generateCustomAction(
    ExtentActionDefine.extentOutputAction.generateActionObject(
        yDefine.type,
        yDefine.hwPoint,
        isOn ? 1 : 0,
        yDefine.hwPoint,
        delay,
        false))
```

而 `extentOutputAction.generateActionObject()` 返回的是：

```js
{"action":200, "type":type, "point":point, "pointStatus":pointStatus,
 "valveID":valveID, "delay":delay, "isWaitInput":isWaitInput}
```

所以这 6 项最终都是 `action = 200`。

## 这些点在 HMI 里会变成什么 type/point

`IODefines.getYDefineFromPointName()` 对普通 `Y` 点的返回规则是：

```js
return {"yDefine": yDefines[i], "hwPoint": i, "type": IO_BOARD_0 + Math.floor(i / 32)};
```

这 6 个点都在第一块普通 Y 板上，所以 `type = 0`，`point = hwPoint`：

| 点位 | hwPoint | type |
| --- | ---: | ---: |
| Y025 | 13 | 0 |
| Y033 | 19 | 0 |
| Y034 | 20 | 0 |
| Y035 | 21 | 0 |
| Y036 | 22 | 0 |
| Y037 | 23 | 0 |

所以主机最终看到的是“普通 IO 板 0 的普通输出点”。

## 为什么可以确认它们不是 201

虽然 `ExtentActionDefine.js` 中确实定义了间隔输出动作：

- `extentIntervalOutputAction.action = 201`

协议头里也定义了：

- `F_CMD_IO_INTERVAL_OUTPUT = 201`

但这个界面没有调用 `extentIntervalOutputAction.generateActionObject()`。

另外，界面回填时 `resolveQuickPanelIndex(actionObject)` 也只认：

```js
if(actionObject.action !== Teach.actions.F_CMD_IO_OUTPUT) {
    return -1;
}
```

也就是说这套快捷面板从生成到回显都只按 `200` 处理。

## 主机追踪

### 1. 协议定义

`hccommparagenericdef.h` 中：

- `F_CMD_IO_OUTPUT = 200`
- `F_CMD_IO_INTERVAL_OUTPUT = 201`

注释里对 201 的定义很明确：

- `cnt: 间隔个数`
- `time: 输出时间`

### 2. 指令工厂分发

`ec_develop/Src/module/data.cpp` 中：

- `case F_CMD_IO_OUTPUT: *cmd_action = new IOOutput;`
- `case F_CMD_IO_INTERVAL_OUTPUT: *cmd_action = new IOIntervalOutput;`

因此当前这 6 个快捷动作进入的类是：

- `IOOutput`

不是：

- `IOIntervalOutput`

### 3. 当前实际执行函数

当前链路是：

1. `IOOutput::Analytical()` 解析 `200`
2. `IOOutput::get_ready()`
3. `IOOutput::process()`
4. `IOOutput::ParrallelProcess()`
5. `IOOperation(OPERATION* op)`
6. `SetIO(board, id, status)`

其中对于当前这 6 个点，因为 `type = 0`，会进入 `IOOutput::ParrallelProcess()` 里的普通 IO 分支：

```cpp
if (type < 8) {
    io_.bit.out_type = 0;
    io_.bit.board_id1 = type;
    io_.bit.io_id1 = out.b.p;
    io_.bit.io_status = out.b.on;
    IOOperation(&io_);
}
```

接着 `IOOperation()` 的 `case 0` 执行：

```cpp
SetIO(op->bit.board_id1, op->bit.io_id1, op->bit.io_status);
```

所以对这 6 个快捷项来说，主机最终落到的执行函数就是：

- `IOOutput::process() / IOOutput::ParrallelProcess()`
- `IOOperation()`
- `SetIO()`

## 动作时间的实际使用

这里要分“当前这 6 个快捷项的实际行为”和“协议本来支持的时间输出”两件事。

### 1. 当前这 6 个快捷项

当前这 6 个快捷项生成的是：

- `action = 200`
- `type = 0`

在主机 `IOOutput::get_ready()` 里：

```cpp
if (type >= 100) {
    out.b.time_up = FALSE;
} else {
    if (delay == 0)
        out.b.time_up = FALSE;
    else
        out.b.time_up = TRUE;
}
```

在 `IOOutput::ParrallelProcess()` 里：

```cpp
if (out.b.time_up) {
    if (t >= delay) {
        out.b.time_up = FALSE;
        time = AutoAction::GetAutoRunTime()[id];
    }
    return PROCESS_DOING;
}
```

这表示：

- 对普通输出 `type < 100`，`delay` 先被当成“等待多久后再执行输出”。
- 等到 `delay` 到了，才真正 `SetIO(...)`。
- 对当前普通 Y 点，不会因为这个 `delay` 自动关断。

所以当前这 6 个快捷项里界面显示的“动作时间”，主机侧真实语义是：

- `延时后输出`

而不是：

- `输出保持这么长时间`

这是当前实现里最需要注意的点。

### 2. 什么情况下才是“输出保持一段时间后自动关闭”

在 `IOOutput::ParrallelProcess()` 里，只有 `type >= 100` 才会走 `out_type = 4` 的时间输出逻辑：

```cpp
io->bit.out_type = 4;
io->bit.board_id1 = board;
io->bit.io_id1 = out.b.p;
io->bit.io_status = out.b.on;
io->bit.time = delay;
io->bit.c_count = delay;
IOOperation(io);
```

再由 `IOOperation()` 的 `case 4` 执行自动关闭：

```cpp
if (op->bit.c_time >= op->bit.c_count / 10) {
    SetIO(op->bit.board_id1, op->bit.io_id1, !op->bit.io_status);
}
```

也就是说，只有“时间输出类型”才会把这个时间当成脉宽/保持时间使用。

而当前喷油、传送带、预留1~4没有生成这种类型。

## 间隔个数的实际使用

### 1. 当前这 6 个快捷项

当前界面里虽然有“间隔次数”输入框，但它没有 `id`，也没有被任何生成函数读取：

- `createReserveSignalQuickAction()` 只取 `reserveActionTimeEdit.configValue`
- `createAuxiliaryQuickAction()` 只取 `auxiliaryActionTimeEdit.configValue`
- 回填时也只回填 `actionObject.delay`

所以当前这 6 个快捷项中：

- “间隔次数”不参与 action 生成
- 不会下发到主机
- 主机不会进入 `IOIntervalOutput`

结论就是：

- 当前版本下，这个字段对喷油/传送带/预留1~4插入指令是未生效状态

### 2. 如果真的走 201，主机会怎么用“间隔个数”

`IOIntervalOutput` 中：

```cpp
if (base.func.binding_counter) {
    reach = (current_cnt % (cnt + 1) == cnt);
} else {
    current_cnt = my_cnt;
    my_cnt++;
    if (my_cnt > cnt) {
        my_cnt = 0;
        reach = true;
    }
}
```

这说明 `cnt` 的语义不是“总共输出几次”，而是“间隔多少个计数触发一次”。

更准确地说：

- `cnt = 0`：每次都触发
- `cnt = 1`：隔 1 次触发一次
- `cnt = 2`：隔 2 次触发一次
- 一般可以理解为“每 `cnt + 1` 次触发一次输出”

### 3. 201 里的动作时间怎么用

`IOIntervalOutput::process()` 中：

- `base.func.type = 1` 时，走常输出
- `base.func.type = 0` 时，走时间输出

时间输出分支：

```cpp
io->bit.out_type = 4;
io->bit.io_status = base.func.status;
io->bit.time = time;
io->bit.c_count = time * 100;
IOOperation(io);
```

也就是说在 201 场景里：

- `cnt` 控制“隔几个计数触发一次”
- `time`/`delay` 控制“每次触发后输出保持多久”

但再次强调，这不是当前这 6 个快捷插入项正在走的链路。

## 最终结论

### 喷油

- 点位：`Y025`
- HMI action：`200`
- Host 指令类：`IOOutput`
- Host 执行函数：`IOOutput::process()` -> `IOOperation()` -> `SetIO()`
- “动作时间”当前语义：普通输出前延时
- “间隔次数”当前语义：未使用

### 传送带

- 点位：`Y033`
- HMI action：`200`
- Host 指令类：`IOOutput`
- Host 执行函数：`IOOutput::process()` -> `IOOperation()` -> `SetIO()`
- “动作时间”当前语义：普通输出前延时
- “间隔次数”当前语义：未使用

### 预留1~4

- 预留1 -> `Y034`
- 预留2 -> `Y035`
- 预留3 -> `Y036`
- 预留4 -> `Y037`
- HMI action：全部都是 `200`
- Host 指令类：全部都是 `IOOutput`
- Host 执行函数：全部都是 `IOOutput::process()` -> `IOOperation()` -> `SetIO()`
- “动作时间”当前语义：普通输出前延时
- “间隔次数”当前语义：未使用

## 风险提示

当前界面文案与实际执行语义存在偏差：

1. 界面显示“动作时间”，但对这 6 个快捷项实际不是脉宽，而是普通输出前延时。
2. 界面显示“间隔次数”，但当前没有参与生成 action，属于未生效字段。
3. 如果业务预期是“隔 N 次输出一次，并保持 T 秒”，那应该走 `F_CMD_IO_INTERVAL_OUTPUT = 201`，而不是当前的 `F_CMD_IO_OUTPUT = 200`。

