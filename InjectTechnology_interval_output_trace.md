# InjectTechnology 喷油/传输带/预留1~4 插入指令追踪说明

## 1. 结论

`InjectTechnology.qml` 里这 6 个“插入指令”:

- `Fuel injection`
- `conveyor`
- `reveserve1`
- `reveserve2`
- `reveserve3`
- `reveserve4`

插入到程序时，统一走的是 `ExtentActionDefine.extentIntervalOutputAction`，也就是自定义动作 `action: 201`。

这条动作在主机 `/home/harry/robot/EC-APRobotHost` 中对应:

- `F_CMD_IO_INTERVAL_OUTPUT` (`hccommparagenericdef.h`)
- 动作类 `IOIntervalOutput`
- 解析创建位置 `ec_develop/Src/module/data.cpp`
- 实际执行函数 `IOIntervalOutput::process(...)`
- 最终底层输出调用 `IOOperation(...)`

也就是说，这 6 个功能在主机侧没有各自独立的“喷油函数/传输带函数/预留函数”，而是共用同一个“间隔输出”指令类。

## 2. 界面到 action 的映射

### 2.1 插入程序时实际使用的点号

`syncyMode()` 初始化模型时:

- `equipmentIO = [25, 26]`
- `reserveIO = [27, 28, 29, 30]`

见:

- `qml/App_HAMOUI/teach/InjectTechnology.qml:4262-4263`
- `qml/App_HAMOUI/teach/InjectTechnology.qml:4319-4332`

因此插入程序时的映射是:

| 界面项 | 模型 | point | type | 生成的 action |
| --- | --- | ---: | ---: | --- |
| Fuel injection | `timeYModel[0]` | 25 | 0 | `action: 201` |
| conveyor | `timeYModel[1]` | 26 | 0 | `action: 201` |
| reveserve1 | `reserveModel[0]` | 27 | 0 | `action: 201` |
| reveserve2 | `reserveModel[1]` | 28 | 0 | `action: 201` |
| reveserve3 | `reserveModel[2]` | 29 | 0 | `action: 201` |
| reveserve4 | `reserveModel[3]` | 30 | 0 | `action: 201` |

插入代码位置:

- 预留 1~4: `qml/App_HAMOUI/teach/InjectTechnology.qml:95-103`
- 喷油/传输带: `qml/App_HAMOUI/teach/InjectTechnology.qml:105-112`

### 2.2 生成 action 的方式

`extentIntervalOutputAction` 定义:

- `action = 201`
- 属性顺序:
  - `intervalType`
  - `isBindingCount`
  - `pointStatus`
  - `point`
  - `type`
  - `counterID`
  - `cnt`
  - `delay`

见 `qml/App_HAMOUI/teach/extents/ExtentActionDefine.js:605-659`。

这个页面插入动作时实际调用:

```js
ExtentActionDefine.extentIntervalOutputAction.generateActionObject(
    type, point, cnt, pointStatus, delay
)
```

该函数返回:

```js
{"action":201, "type":type, "point":point, "cnt":cnt, "pointStatus":pointStatus, "delay":delay, "intervalType":0}
```

关键点:

- `intervalType` 被硬编码为 `0`
- `isBindingCount` 没传
- `counterID` 没传

因此这 6 个界面项插入程序时，默认都是:

- 时间输出模式，不是常输出模式
- 不绑定计数器
- 使用动作自身内部计数

## 3. HMI 编译到主机指令

### 3.1 自定义动作注册与字段精度

`Teach.js` 会把 `action 201` 的字段序列和小数位注册给编译器，见:

- `qml/App_HAMOUI/teach/Teach.js:3968-4049`

`ICRobotMold` 编译自定义动作时，会按注册的小数位把浮点值转成整数:

- `datamanerger/icrobotmold.cpp:134-152`
- `vendor/IndustrialSystemFramework/ICUtility/icutility.h:59-63`

这里 `delay` 的 decimal 是 `1`，所以:

- 界面填 `0.5`
- 编译后写入主机的是 `5`

也就是 `delay/time` 在链路中按 `0.1s` 精度编码。

### 3.2 主机 action 枚举

主机定义:

```cpp
F_CMD_IO_OUTPUT = 200,
F_CMD_IO_INTERVAL_OUTPUT,
```

见 `ec_develop/Include/hmi/protocol/hccommparagenericdef.h:1738-1747`。

所以 `F_CMD_IO_INTERVAL_OUTPUT` 的实际数值就是 `201`，和 HMI 的 `action: 201` 对上了。

### 3.3 主机创建的动作类

主机解析时:

```cpp
case F_CMD_IO_INTERVAL_OUTPUT:
    *cmd_action = new IOIntervalOutput;
```

见 `ec_develop/Src/module/data.cpp:288-289`。

所以这 6 个界面项进入主机后，统一被创建成 `IOIntervalOutput` 对象。

## 4. 主机中最终走到哪个函数

### 4.1 解析函数

`IOIntervalOutput::Analytical(...)` 负责把指令参数读入:

- `base.func.type`
- `base.func.binding_counter`
- `base.func.status`
- `out.b.id`
- `out.b.board`
- `cnt_id`
- `cnt`
- `time`

见 `ec_develop/action/ActionBase.h:2037-2083`。

### 4.2 实际执行函数

真正执行在:

- `ec_develop/action/ActionBase.cpp:5376-5433`

函数名:

```cpp
int IOIntervalOutput::process(AutoAction* autoaction, ActionBase* l, ActionBase* n)
```

执行分两种:

1. `base.func.type == 1`
   说明是“常输出”
   直接调用 `IOOperation(&io_)`

2. `base.func.type == 0`
   说明是“时间输出”
   创建/复用 `OPERATION`
   然后调用 `IOOperation(io)`

而本界面生成时 `intervalType` 固定为 `0`，因此这 6 个界面项实际都会走“时间输出”分支。

## 5. 动作时间和间隔个数的实际用法

这是这次追踪里最重要的部分。

### 5.1 动作时间 `Act Time`

界面上:

- 喷油/传输带使用 `equipmentDelayEdit`
- 预留 1~4 使用 `delayEdit`
- 两者都是 `decimal: 1`

见:

- `qml/App_HAMOUI/teach/InjectTechnology.qml:3368-3385`
- `qml/App_HAMOUI/teach/InjectTechnology.qml:3497-3514`

插入程序后，这个值进入 `delay`
主机解析后进入 `time`
主机执行时在时间输出分支里使用:

```cpp
io->bit.time = time;
io->bit.c_count = time * 100;
```

见 `ec_develop/action/ActionBase.cpp:5418-5424`。

可直接确认的结论:

- 这个界面的“动作时间”只在时间输出模式下生效
- 这 6 个插入指令正好都固定是时间输出模式
- HMI 以 `0.1s` 精度编码时间

示例:

- 界面填 `0.5s`
- 编译后 `time = 5`
- 主机执行时 `c_count = 500`

### 5.2 间隔个数 `interval number`

界面上:

- 喷油/传输带使用 `equipmentInterval`
- 预留 1~4 使用 `interval`
- 默认值都是 `10`

主机判定是否触发的核心代码:

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

见 `ec_develop/action/ActionBase.cpp:5382-5397`。

因此这里的“间隔个数”不是“每 cnt 次触发一次”，而是按 `cnt + 1` 为周期。

实际效果:

- `cnt = 0` 时，每次执行都触发
- `cnt = 1` 时，每 2 次触发 1 次
- `cnt = 10` 时，每 11 次触发 1 次

这 6 个界面项因为没有传 `isBindingCount`，编译时会补 `0`，所以默认走:

- `binding_counter = 0`
- 使用 `my_cnt` 自身计数
- 不使用外部计数器

也就是说，默认是“该动作在程序里被执行到第 `cnt+1` 次时触发一次，然后重新计数”。

## 6. 一个需要特别注意的点

界面上的“手动按钮”与“插入程序动作”用的点号不是同一组。

手动按钮当前切的是:

- Fuel injection -> `teachYOut[13]`
- conveyor -> `teachYOut[19]`
- reveserve1~4 -> `teachYOut[15]~[18]`

见:

- `qml/App_HAMOUI/teach/InjectTechnology.qml:3405-3444`
- `qml/App_HAMOUI/teach/InjectTechnology.qml:3531-3627`

但插入程序时模型里用的是:

- Fuel injection -> `point 25`
- conveyor -> `point 26`
- reserve1~4 -> `point 27~30`

见:

- `qml/App_HAMOUI/teach/InjectTechnology.qml:4262-4263`
- `qml/App_HAMOUI/teach/InjectTechnology.qml:4319-4332`

当前 `IOConfigs.js` 里的 `teachYOut` 是顺序数组，不会把 `13` 自动映射成 `25`。所以从现有代码看:

- “按钮测试”的 IO 点
- “插入程序”的 IO 点

并不一致。

如果现场现象是“手动按钮能动，但程序插入后打到的是另一组点”，这一处就是第一嫌疑点。

## 7. 最终追踪链路

完整链路可以概括为:

1. `InjectTechnology.qml` 勾选喷油/传输带/预留1~4
2. 调用 `extentIntervalOutputAction.generateActionObject(...)`
3. 生成自定义动作 `action: 201`
4. `Teach.js` 注册字段顺序和小数位
5. `ICRobotMold::CustomActionCompiler` 编译成主机指令数据
6. 主机把 `201` 识别为 `F_CMD_IO_INTERVAL_OUTPUT`
7. `data.cpp` 创建 `new IOIntervalOutput`
8. `IOIntervalOutput::Analytical(...)` 解析参数
9. `IOIntervalOutput::process(...)` 判断是否达到间隔条件
10. 达到条件后调用 `IOOperation(...)` 输出 IO

## 8. 一句话总结

这 6 个插入指令在主机里统一走 `F_CMD_IO_INTERVAL_OUTPUT -> IOIntervalOutput::process() -> IOOperation()`；`动作时间` 是时间输出持续时长，`间隔个数` 实际按 `cnt + 1` 周期生效，而且当前页面生成的动作默认是“时间输出 + 自身计数”，不绑定外部计数器。
