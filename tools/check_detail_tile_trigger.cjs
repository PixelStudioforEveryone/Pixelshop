// 高清局部渲染（放大后的瓦片）为什么可能"不触发"。
//
// 这条路径跨四个文件：EditorPage → EditorLayout → PhoneLayout/TabletLayout → EditorCanvas，
// 再回调 EditorPage.requestDetailRender 去读源瓦片。任何一跳漏传，放大后都不会出高清瓦片，
// 而且不会报错。本套件把这条链路和两个门槛都钉死。
//
// 注意：这些是**源码级结构断言**——本环境无法运行 UI 或手势，所以不能声称在真机上验证过。
const fs = require('fs'), path = require('path'), assert = require('assert');

let checks = 0;
function ok(cond, msg) { checks++; assert(cond, msg); }
const read = (p) => fs.readFileSync(p, 'utf8');
const canvas = read('entry/src/main/ets/components/EditorCanvas.ets');
const page = read('entry/src/main/ets/pages/EditorPage.ets');
const layout = read('entry/src/main/ets/views/EditorLayout.ets');
const phone = read('entry/src/main/ets/views/PhoneLayout.ets');
const tablet = read('entry/src/main/ets/views/TabletLayout.ets');

// --- 1. 回调链路必须四跳完整 -------------------------------------------
// 断了会有默认空实现顶上（= () => {}），静默失效。
ok(/onRequestDetailRender\s*:\s*\(region:\s*DetailRegion \| null\)\s*=>\s*void\s*=\s*\(\)\s*=>\s*\{\}/.test(canvas),
  'EditorCanvas 声明了 onRequestDetailRender，并带一个空实现默认值（所以断链不会报错，只会静默不触发）');
ok(/EditorCanvas\(\{\s*onRequestDetailRender:\s*this\.onRequestDetailRender\s*\}\)/.test(phone),
  'PhoneLayout 把回调透传给 EditorCanvas');
ok(/EditorCanvas\(\{\s*onRequestDetailRender:\s*this\.onRequestDetailRender\s*\}\)/.test(tablet),
  'TabletLayout 把回调透传给 EditorCanvas');
ok(/PhoneLayout\(\{\s*onRequestDetailRender:\s*this\.onRequestDetailRender\s*\}\)/.test(layout),
  'EditorLayout 把回调透传给 PhoneLayout');
ok(/TabletLayout\(\{\s*onRequestDetailRender:\s*this\.onRequestDetailRender/.test(layout),
  'EditorLayout 把回调透传给 TabletLayout');
ok(/EditorLayout\(\{\s*onRequestDetailRender:/.test(page),
  'EditorPage 把回调交给 EditorLayout');
ok(/private async requestDetailRender\(region:\s*DetailRegion \| null\)/.test(page),
  'EditorPage 真的实现了 requestDetailRender');
console.log('四跳回调链路完整：EditorPage -> EditorLayout -> Phone/TabletLayout -> EditorCanvas -> EditorPage');

// --- 2. 放大手势必须真的写 canvasScale ---------------------------------
// 门槛读的是 session.canvasScale；如果手势只改局部变换而不写它，门槛永远不满足。
const scaleWrites = (canvas.match(/this\.editSession\.canvasScale\s*=/g) || []).length;
ok(scaleWrites >= 3, '捏合/缩放按钮/重置都写 canvasScale（' + scaleWrites + ' 处），门槛才有输入');
ok(/this\.pinchStartScale\s*=\s*this\.editSession\.canvasScale/.test(canvas),
  '捏合开始时读取当前缩放');
ok(/this\.editSession\.canvasScale\s*=\s*Math\.max\(0\.5,/.test(canvas), '捏合过程中按比例写入新缩放');
ok(/private readonly detailZoomThreshold:\s*number\s*=\s*1\.35/.test(canvas),
  '触发阈值是 1.35 倍；低于它（例如只点一次放大到 1.25）不会出瓦片，这是设计如此');

// --- 3. 门槛：裁剪必须不再禁止（本轮修复） ----------------------------
// 只看 scheduleDetailRequest 这一块：文件里另有合法的裁剪判断（例如决定显示矩形是否
// 按裁剪后计算），那不是瓦片门槛，用整文件正则会把它们误判成本回归。
const gate = canvas.slice(canvas.indexOf('private scheduleDetailRequest'), canvas.indexOf('private getVisibleDetailRegion'));
ok(gate.length > 200, 'scheduleDetailRequest 的守卫块被定位到（' + gate.length + ' 字符）');
// 剥掉注释再判断：本函数上方那段说明文字里正好写着 cropLeft/cropRight 这些名字，
// 直接搜子串会把注释当成代码。
const gateCode = gate.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
ok(gateCode.indexOf('cropLeft') < 0 && gateCode.indexOf('cropTop') < 0 &&
  gateCode.indexOf('cropRight') < 0 && gateCode.indexOf('cropBottom') < 0,
  '裁剪不再禁止高清瓦片：守卫代码里已无任何裁剪判断。此前四个边界一刀切，导致只要裁过一次图，' +
  '之后无论怎么放大都不会再触发高清局部渲染');
ok(gateCode.indexOf('isCropping') >= 0, '但正在裁剪过程中仍然不请求（避免裁剪框拖动时反复重渲染）');
ok(gateCode.indexOf('rotation !== 0') >= 0 && gateCode.indexOf('flipH') >= 0 && gateCode.indexOf('flipV') >= 0,
  '旋转与翻转仍然禁用：瓦片路径按未旋转的源帧取像素，这两条不是本轮要改的');

// --- 4. 裁剪支持必须真的在下游存在（否则放开门槛就是错的） -----------
ok(/const cropLeft = Math\.max\(0, Math\.min\(1, this\.editSession\.cropLeft\)\)/.test(page),
  'requestDetailRender 读取裁剪左边界');
ok(/const sourceLeft = cropLeft \+ currentRegion\.left \* cropWidth/.test(page),
  '并把画布区域按裁剪换算回源坐标（注释也写明：否则裁剪后放大会采到错的像素）');
ok(/detailSession\.cropLeft = \(x - tileX\) \/ \(tileRight - tileX\)/.test(page),
  '再给瓦片会话设上"瓦片内的相对可见区"裁剪，避免同一裁剪被应用两次');
ok(/detailSession\.cropRight = \(right - tileX\) \/ \(tileRight - tileX\)/.test(page),
  '右边界同样换算');
// 数值核对：同一个公式在"已裁剪"的画布区域上应还原出正确的源矩形。
const cropLeft = 0.2, cropTop = 0.1, cropRight = 0.8, cropBottom = 0.9;
const cropWidth = cropRight - cropLeft, cropHeight = cropBottom - cropTop;
const region = { left: 0.25, top: 0.25, width: 0.5, height: 0.5 };
const sourceLeft = cropLeft + region.left * cropWidth;
const sourceTop = cropTop + region.top * cropHeight;
const sourceRight = cropLeft + (region.left + region.width) * cropWidth;
ok(Math.abs(sourceLeft - 0.35) < 1e-12 && Math.abs(sourceRight - 0.65) < 1e-12,
  '裁剪 0.2..0.8 时，画布中 0.25..0.75 的区域换算回源帧是 0.35..0.65（与实现的公式一致）');
ok(sourceLeft > cropLeft && sourceRight < cropRight,
  '并且换算结果落在裁剪窗口内部，不会读到裁剪框外的像素');
ok(Math.abs(sourceTop - 0.3) < 1e-12, '纵向同理');

// --- 5. 瓦片只在"真的放大到看得见一部分"时才请求 ----------------------
const regionFn = canvas.slice(canvas.indexOf('private getVisibleDetailRegion'));
ok(/width > 0\.96 && height > 0\.96/.test(regionFn),
  '可见区域几乎等于整幅图时返回 null：这是"还没真正放大"的判断，避免为全图出瓦片');
ok(/previewWidth <= 0 \|\| this\.editSession\.previewHeight <= 0/.test(regionFn),
  '并且首帧预览尺寸未知时返回 null——所以第一帧不会请求瓦片，这是正常的');
// 首个 previewWidth 的写入点必须在渲染完成/区域渲染里，否则这道 guard 永远为真。
const ip = read('entry/src/main/ets/edit/engine/ImageProcessor.ets');
ok(/session\.previewWidth = output\.width/.test(ip) && /session\.previewWidth = width/.test(ip),
  'previewWidth 在渲染完成后被写入（两处），所以首帧之后这道 guard 会放开');
ok(/this\.editSession\.detailRegion = currentRegion/.test(page) && /detailRevision\+\+/.test(page),
  '瓦片渲染成功后会发布 detailRegion 并递增 revision，画布据此贴图');

console.log('PASS 高清瓦片：四跳回调链路完整、缩放确实写入 canvasScale、裁剪不再一刀切禁用，');
console.log('     且下游的裁剪坐标换算与瓦片内相对裁剪都真实存在（数值已核对）。');
console.log('NOTE 这是源码级结构验证：本环境不能运行 UI 与捏合手势，未在真机上确认过触发与贴图。');
console.log(checks + ' 项通过');
