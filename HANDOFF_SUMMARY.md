## 1. 问题背景

- 目标模块：`EasyProgramSignalPage.qml`、`EasyProgramFunctionPanel.qml`、`EasyProgramQuickPage.qml`
- 当前需求/bug有两条主线：
  1. “正向/反向” 与检测动作 `xDir` 的语义要正确。
  2. 模板快设 `QuickPage` 初始化时会报：
     - `Failed to build quick template preset action: ...`
     - `QuickPage FS check custom action is not registered yet, fallback to raw action object 106`
- 预期行为：
  - 信号页选择“正向/反向”后，检测动作方向正确。
  - “通/断检测” 与 “开始/结束检测” 是两个独立维度，不应互相硬绑定。
  - 模板快设加载时，preset 动作应正常构建，不应报注册失败。
- 实际问题：
  - 早期出现“怎么插入都是反向”。
  - 曾误把“结束检测”硬绑定为“断检测”。
  - 当前模板初始化仍报警，但用户反馈“程序实际上是插入了”。

## 2. 当前进展

### 已做尝试
- 梳理了三条链路：
  - `SignalPage`：提供基础方向
  - `FunctionPanel`：`通/断检测` 决定是否对基础方向取反，`开始/结束` 决定 `types`
  - `QuickPage`：模板 preset 构建动作对象
- 修正了 `QuickPage` 不再用 `checkPhase === "end"` 自动翻转方向。
- 为 `FunctionPanel` / `QuickPage` 生成的 check 动作增加了 `checkOnState` 字段，用来显式区分“通检测/断检测”，避免再用 `end/start` 猜。
- 给 `QuickPage` / `FunctionPanel` 的 `Teach.generateCustomAction(...)` 增加了 fallback，避免 `null` 上取属性崩溃。

### 改过的地方
- [`qml/App_HAMOUI/teach/EasyProgramSignalPage.qml`](/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/EasyProgramSignalPage.qml)
  - 新增 `invertCheckDirectionValue()`
  - `getCheckDirectionValue()` / `refreshCheckDirectionConfigs()` / `saveCheckDirectionConfigs()` 统一做了方向取反映射
- [`qml/App_HAMOUI/teach/EasyProgramFunctionPanel.qml`](/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/EasyProgramFunctionPanel.qml)
  - 新增 `actionCheckOnState()`、`pointNameToSignalKey()`
  - `findCheckRowByAction()` 不再用 `isEnd -> preferEnd` 匹配，而改为按 `checkOnState`
  - `createCheckQuickAction()` 给 actionObject 增加 `checkOnState`
  - 还存在一个无关 UI 小改动：确认时间 `visible:false`、check repeater `y` 从 `82` 改到 `46`
- [`qml/App_HAMOUI/teach/EasyProgramQuickPage.qml`](/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/EasyProgramQuickPage.qml)
  - `presetCheckDirectionValue()` 改为只在显式 `isOnCheck:false` 时才反转方向
  - `buildPresetCheckActionObject()` 给动作增加 `checkOnState`
  - `Teach.generateCustomAction()` 返回 `null` 时 fallback 到 raw action object，并打日志

## 3. 关键代码上下文

### A. SignalPage 对外提供基础方向
文件：`/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/EasyProgramSignalPage.qml`

```qml
function normalizeCheckDirectionValue(value) {
    return Number(value) === 1 ? 1 : 0;
}

function invertCheckDirectionValue(value) {
    return normalizeCheckDirectionValue(value) === 1 ? 0 : 1;
}

function getCheckDirectionValue(signalKey) {
    var editor = checkDirectionEditorByKey(signalKey);
    var addr = checkDirectionConfigAddr(signalKey);
    if(editor) {
        return invertCheckDirectionValue(editor.configValue);
    }
    if(addr === "" || typeof panelRobotController === "undefined") {
        return 0;
    }
    return normalizeCheckDirectionValue(panelRobotController.getConfigValue(addr));
}
```

### B. FunctionPanel：通/断检测决定方向是否取反；开始/结束决定 types
文件：`/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/EasyProgramFunctionPanel.qml`

```qml
property variant checkSignalRows: [
    {name: qsTr("吸1通检测"), pointName: "X014", signalKey: "suction1", isOnCheck: true, preferEnd: false},
    {name: qsTr("吸1断检测"), pointName: "X014", signalKey: "suction1", isOnCheck: false, preferEnd: true}
]

function getConfiguredDirectionValue(signalKey) {
    if(checkDirectionProvider && checkDirectionProvider.getCheckDirectionValue) {
        return normalizeDirectionValue(checkDirectionProvider.getCheckDirectionValue(signalKey));
    }
    return 0;
}

function getCheckRowDirectionValue(checkRow) {
    var configuredDir = getConfiguredDirectionValue(checkRow ? checkRow.signalKey : "");
    if(checkRow && checkRow.isOnCheck === false) {
        return reverseDirectionValue(configuredDir);
    }
    return configuredDir;
}

function actionCheckOnState(actionObject, pointName) {
    var configuredDir;
    var actionDir;
    if(actionObject.hasOwnProperty("checkOnState")) {
        return Number(actionObject.checkOnState) !== 0;
    }
    configuredDir = getConfiguredDirectionValue(pointNameToSignalKey(pointName));
    actionDir = normalizeDirectionValue(actionObject.xDir);
    return actionDir === configuredDir;
}

function findCheckRowByAction(actionObject) {
    ...
    isOnCheck = actionCheckOnState(actionObject, pointName);
    for(i = 0; i < checkSignalRows.length; ++i) {
        if(checkSignalRows[i].pointName !== pointName) continue;
        if(!!checkSignalRows[i].isOnCheck === isOnCheck) {
            return checkSignalRows[i];
        }
    }
    return null;
}
```

```qml
function createCheckQuickAction() {
    ...
    rawActionObject = ExtentActionDefine.generateFSCheckAction.generateActionObject(
                xDefine.hwPoint,
                checkStartBox.isChecked ? 1 : 0,
                checkDelay.configValue,
                xDir,
                1);
    actionObject = Teach.generateCustomAction(rawActionObject);
    if(!actionObject) {
        console.log("FunctionPanel FS check custom action is not registered yet, fallback to raw action object", rawActionObject.action);
        actionObject = rawActionObject;
    }
    actionObject.checkOnState = checkRow.isOnCheck ? 1 : 0;
    return {"ok": true, "actionObject": actionObject, ...};
}
```

### C. QuickPage：模板预设构建动作
文件：`/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/EasyProgramQuickPage.qml`

```qml
function presetCheckDirectionValue(preset) {
    var direction = 0;
    var isOnCheck = true;
    if(checkDirectionProvider && checkDirectionProvider.getCheckDirectionValue) {
        direction = normalizeCheckDirectionValue(
                    checkDirectionProvider.getCheckDirectionValue(preset.signalKey || ""));
    }
    if(preset && preset.hasOwnProperty("isOnCheck")) {
        isOnCheck = !!preset.isOnCheck;
    }
    if(!isOnCheck) {
        return direction === 0 ? 1 : 0;
    }
    return direction;
}
```

```qml
function buildPresetCheckActionObject(preset) {
    var xDefine = IODefines.getXDefineFromPointName(preset.pointName);
    var actionObject;
    var rawActionObject;
    if(!xDefine) {
        return null;
    }
    rawActionObject = ExtentActionDefine.generateFSCheckAction.generateActionObject(
                xDefine.hwPoint,
                preset.checkPhase === "end" ? 0 : 1,
                preset.hasOwnProperty("delay") ? preset.delay : "0.000",
                presetCheckDirectionValue(preset),
                1);
    actionObject = Teach.generateCustomAction(rawActionObject);
    if(!actionObject) {
        console.log("QuickPage FS check custom action is not registered yet, fallback to raw action object", rawActionObject.action);
        actionObject = rawActionObject;
    }
    actionObject.checkOnState = (preset && preset.hasOwnProperty("isOnCheck") && !preset.isOnCheck) ? 0 : 1;
    return actionObject;
}
```

### D. 根因相关：Teach 的自定义动作注册
文件：`/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/Teach.js`

```js
var generateCustomAction = function(actionObject){
    if(!actionObject.hasOwnProperty("action")) return null;
    if(!customActions.hasOwnProperty(actionObject.action)) return null;
    return customActions[actionObject.action].generate(actionObject);
}
```

文件：`/home/harry/robot/HMI-RX_/qml/App_HAMOUI/teach/ProgramFlowPage.qml`

```qml
Teach.registerCustomActions(panelRobotController, ExtentActionDefine.extentActions);
```

## 4. 问题卡点

- 当前卡点不是“数据没设”，而是：
  - `QuickPage` 模板初始化时调用 `Teach.generateCustomAction(...)`
  - 但 `Teach.customActions` 可能尚未注册完成
  - 导致 `wait/output/check` preset 初始化时报 “Failed to build...”
- 用户反馈：
  - 虽然报了这些 warning
  - 但程序“实际上插入了”
- 还没完全解释清楚的点：
  - 为什么 `QuickPage` 初始化时报 preset build 失败，但后续槽位仍能插入/保存成功
  - 很可能是因为“模板初始化预填失败”和“后续手动插入/快照恢复/保存程序”走的是不同路径
  - 但还没把完整用户操作路径逐条验证

## 5. 已排除的方向

- 已排除“只是 `checkPhase=end` 导致方向翻转”的单一原因
  - 这只解释了旧 QuickPage 的一部分问题，不是全部
- 已排除“结束检测必须等于断检测”的模型
  - 现在已显式加 `checkOnState`，不再用 `end/start` 去推断通断
- 已排除“报错是因为 preset 本身没数据”
  - `templateStepDefinitions` 里的 preset 数据是有的
- 已排除“FS check generateActionObject 本身返回空”
  - `ExtentActionDefine.generateFSCheckAction.generateActionObject(...)` 正常返回 raw object
  - 真正返回 `null` 的是 `Teach.generateCustomAction(...)`

## 6. 下一步建议

1. 优先确认 `QuickPage` 模板初始化与 `Teach.registerCustomActions(...)` 的先后时序
   - 核对 `EasyProgramWizard` / `QuickPage.loadTemplate()` 是否早于 `ProgramFlowPage` 完成注册
2. 二选一修复：
   - 方案 A：把 `Teach.registerCustomActions(panelRobotController, ExtentActionDefine.extentActions)` 提前到进入 `QuickPage` 前
   - 方案 B：`QuickPage` 初始化 preset 时彻底不要走 `Teach.generateCustomAction()`，统一只存 raw action object
3. 如果选方案 B，要一起检查：
   - `editFilledStepAction()`
   - `loadQuickActionObject()`
   - `save()`
   - `refreshCheckActionDirectionsBySignalConfig()`
   是否都能处理 raw object
4. 顺手清理当前临时 fallback/log，避免长期把注册时序问题掩盖掉


