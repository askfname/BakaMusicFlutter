/// QuickJS 运行时共享脚本
///
/// 组成：
/// 1. [jsBridgePrelude]：BakaHttp 同步桥、挂起/错误/取消标记、CommonJS require
///    垫片与 `__bakaInvoke` 方法调用助手；
/// 2. [jsModuleScripts]：内置模块（axios/buffer/crypto-js 等），经
///    [buildModuleFactoriesSource] 注册到 `__bakaModuleFactories`；
/// 3. [jsRuntimeBootstrap]：同步 Promise/CryptoJS/Buffer/TextDecoder 等 polyfill；
/// 4. [stripAsyncAwait]：状态机剥离 async/await 为同步调用；
/// 5. 插件源码补丁与包装 [buildWrappedPluginSource]。
library;

import 'dart:convert';

/// JS 原语层。sendMessage 返回 Dart 侧处理的 JSON 字符串；挂起/取消/错误
/// 通过约定标记回传（Dart 不向 JS 抛异常，避免 FFI 边界不确定行为）
const String jsBridgePrelude = r'''
var __BAKA_SUSPEND__ = '__BAKA_SUSPEND__';
var __BAKA_ERROR__ = '__BAKA_ERROR__';
var __BAKA_CANCELED__ = '__BAKA_CANCELED__';

function __bakaCall(op, args){
  var raw = sendMessage('BakaNative', JSON.stringify({op: op, args: args}));
  if (raw === __BAKA_SUSPEND__) throw new Error('BakaSuspended');
  if (raw === __BAKA_CANCELED__) throw new Error('BakaCanceled');
  if (typeof raw === 'string' && raw.indexOf(__BAKA_ERROR__) === 0) {
    throw new Error(raw.substring(__BAKA_ERROR__.length));
  }
  return raw;
}

var BakaHttp = {
  request: function(configText){ return __bakaCall('request', [String(configText)]); },
  md5: function(value){ return __bakaCall('md5', [String(value)]); },
  sha1: function(value){ return __bakaCall('sha1', [String(value)]); },
  sha256: function(value){ return __bakaCall('sha256', [String(value)]); },
  sha512: function(value){ return __bakaCall('sha512', [String(value)]); },
  hmacSha256: function(key, value){ return __bakaCall('hmacSha256', [String(key), String(value)]); },
  hmacSha1: function(key, value){ return __bakaCall('hmacSha1', [String(key), String(value)]); },
  hmacMd5: function(key, value){ return __bakaCall('hmacMd5', [String(key), String(value)]); },
  modPowHex: function(base, exp, mod){ return __bakaCall('modPowHex', [String(base), String(exp), String(mod)]); },
  textDecode: function(base64, charset){ return __bakaCall('textDecode', [String(base64), String(charset)]); },
  inflate: function(base64){ return __bakaCall('inflate', [String(base64)]); },
  aes: function(mode, key, iv, plain){ return __bakaCall('aes', [String(mode), String(key), String(iv), String(plain)]); },
  aesDecrypt: function(mode, key, iv, cipher){ return __bakaCall('aesDecrypt', [String(mode), String(key), String(iv), String(cipher)]); },
  randomBytes: function(size){ return __bakaCall('randomBytes', [String(size)]); },
  aesBytes: function(mode, data, key, iv){ return __bakaCall('aesBytes', [String(mode), String(data), String(key), String(iv)]); },
  rsaEncrypt: function(data, pem){ return __bakaCall('rsaEncrypt', [String(data), String(pem)]); },
  deflate: function(base64){ return __bakaCall('deflate', [String(base64)]); }
};

// CommonJS 垫片：引擎不提供 require，模块工厂由 buildModuleFactoriesSource 注入
var module = {exports: {}};
var exports = module.exports;
var __bakaModuleFactories = {};
var __bakaModuleCache = {};
function __bakaRequire(name){
  if (Object.prototype.hasOwnProperty.call(__bakaModuleCache, name)) {
    return __bakaModuleCache[name];
  }
  var factory = __bakaModuleFactories[name];
  var m = {exports: {}};
  if (typeof factory === 'function') factory(m, m.exports);
  __bakaModuleCache[name] = m.exports;
  return m.exports;
}
var require = __bakaRequire;
var __musicfree_require = __bakaRequire;
try { globalThis.require = __bakaRequire; globalThis.__musicfree_require = __bakaRequire; } catch (e) {}

// 插件导出对象与方法调用
var __bakaPlugin = null;
function __bakaApplyPlugin(){
  var eo = module.exports;
  if (eo === undefined || eo === null) throw new Error('插件没有导出对象');
  var d = (typeof eo === 'object' && Object.prototype.hasOwnProperty.call(eo, 'default')) ? eo['default'] : undefined;
  __bakaPlugin = (d !== undefined && d !== null && typeof d === 'object') ? d : eo;
}
function __bakaInvoke(method, argsJson){
  var p = __bakaPlugin;
  if (p === null || p === undefined) return '{}';
  var fn = p[method];
  if (fn === undefined || fn === null) return '{}';
  if (typeof fn !== 'function') throw new Error('插件方法不是函数: ' + String(method));
  var args = JSON.parse(argsJson);
  var result = fn.apply(p, args);
  if (result === undefined || result === null) return '{}';
  if (Object.prototype.toString.call(result) === '[object Array]') return JSON.stringify({data: result});
  if (typeof result === 'object') return JSON.stringify(result);
  return '{}';
}
''';

/// 插件信息读取：platform 与 supportedQualities
const String jsPluginInfo = r'''
JSON.stringify({
  platform: (__bakaPlugin && typeof __bakaPlugin.platform === 'string') ? __bakaPlugin.platform : '',
  qualities: (function(){
    var list = [];
    var q = __bakaPlugin ? __bakaPlugin.supportedQualities : null;
    if (q && typeof q.length === 'number') {
      for (var i = 0; i < q.length; i++) {
        var v = q[i];
        if (typeof v !== 'string') continue;
        var t = v.replace(/^\s+|\s+$/g, '');
        if (t.length > 0) list.push(t);
      }
    }
    return list;
  })()
})
''';

/// 内置模块脚本
const Map<String, String> jsModuleScripts = {
  'axios': r'''
var axios=function(c){var cfg=c||{};var __d=cfg&&cfg.data;if(__d&&typeof Uint8Array!=='undefined'&&__d instanceof Uint8Array){var __bin='';for(var __i=0;__i<__d.length;__i++)__bin+=String.fromCharCode(__d[__i]);try{cfg=Object.assign({},cfg,{data:{__bytes_base64:btoa(__bin)}});}catch(__e){}}var r=JSON.parse(BakaHttp.request(JSON.stringify(cfg)));if(r.__error)throw new Error(r.__error);var ok=cfg.validateStatus?cfg.validateStatus(r.status):r.status>=200&&r.status<300;if(!ok){var err=new Error('Request failed with status code '+r.status);err.response={status:r.status,data:r.data,headers:r.headers||{}};throw err;}var d=r.data;var tr=cfg.transformResponse;if(tr){var fns=Array.isArray(tr)?tr:[tr];for(var i=0;i<fns.length;i++){if(typeof fns[i]==='function')d=fns[i](d);}}if(d&&d.__base64){var raw=atob(d.__base64),u=new Uint8Array(raw.length);for(var i=0;i<raw.length;i++)u[i]=raw.charCodeAt(i);d=u;}return {data:d,status:r.status,statusText:String(r.status),headers:r.headers||{},config:cfg};};
axios.defaults={};axios.request=axios;axios.get=function(u,c){return axios(Object.assign({},c||{},{url:u,method:'GET'}));};axios.post=function(u,d,c){return axios(Object.assign({},c||{},{url:u,method:'POST',data:d}));};axios.head=function(u,c){return axios(Object.assign({},c||{},{url:u,method:'HEAD'}));};axios.delete=function(u,c){return axios(Object.assign({},c||{},{url:u,method:'DELETE'}));};axios.put=function(u,d,c){return axios(Object.assign({},c||{},{url:u,method:'PUT',data:d}));};axios.patch=function(u,d,c){return axios(Object.assign({},c||{},{url:u,method:'PATCH',data:d}));};axios.options=function(u,c){return axios(Object.assign({},c||{},{url:u,method:'OPTIONS'}));};axios.getUri=function(c){c=c||{};var u=c.url||'';var p=c.params||{};var q=Object.keys(p).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(p[k]);}).join('&');return q?(u+(u.indexOf('?')>=0?'&':'?')+q):u;};axios.all=function(values){return Promise.all(values);};axios.spread=function(fn){return function(values){return fn.apply(null,values);};};axios.default=axios;axios.create=function(def){var inst=function(c){return axios(Object.assign({},def||{},c||{}));};inst.get=function(u,c){return inst(Object.assign({},c||{},{url:u,method:'GET'}));};inst.post=function(u,d,c){return inst(Object.assign({},c||{},{url:u,method:'POST',data:d}));};inst.head=function(u,c){return inst(Object.assign({},c||{},{url:u,method:'HEAD'}));};inst.delete=function(u,c){return inst(Object.assign({},c||{},{url:u,method:'DELETE'}));};inst.put=function(u,d,c){return inst(Object.assign({},c||{},{url:u,method:'PUT',data:d}));};inst.patch=function(u,d,c){return inst(Object.assign({},c||{},{url:u,method:'PATCH',data:d}));};inst.options=function(u,c){return inst(Object.assign({},c||{},{url:u,method:'OPTIONS'}));};inst.request=inst;inst.defaults=axios.defaults;return inst;};module.exports=axios;
''',
  'buffer': r'''module.exports={Buffer:globalThis.Buffer};''',
  'crypto-js': r'''module.exports=globalThis.CryptoJs;''',
  'big-integer': r'''
function __Big(v){ this.h=v; }
__Big.prototype.modPow=function(e,m){
    var eh=(e instanceof __Big)?e.h:String(e), mh=(m instanceof __Big)?m.h:String(m);
    return new __Big(BakaHttp.modPowHex(this.h, eh, mh));
};
__Big.prototype.toString=function(r){ var h=String(this.h); if(h.substr(0,2)==='0x'||h.substr(0,2)==='0X')h=h.substr(2); while(h.length>1&&h.charAt(0)==='0')h=h.substr(1); return h||'0'; };
__Big.prototype.valueOf=function(){ return this.h; };
module.exports=function(v,base){ if(v instanceof __Big)return v; if(typeof v==='number')return new __Big(Math.floor(v).toString(16)); var s=String(v); if(s.substr(0,2)==='0x'||s.substr(0,2)==='0X')s=s.substr(2); return new __Big(s); };
''',
  'qs': r'''
function __qsVal(v){ if(v===null||v===undefined)return ''; if(typeof v==='object')return JSON.stringify(v); return String(v); }
module.exports={
  stringify:function(o,opts){ var out=[]; var src=o||{}; for(var k in src){ if(!Object.prototype.hasOwnProperty.call(src,k))continue; var v=src[k]; if(v===undefined||v===null)continue; if(Array.isArray(v)){ for(var i=0;i<v.length;i++)out.push(encodeURIComponent(k)+'='+encodeURIComponent(__qsVal(v[i]))); } else if(typeof v==='object'){ out.push(encodeURIComponent(k)+'='+encodeURIComponent(JSON.stringify(v))); } else out.push(encodeURIComponent(k)+'='+encodeURIComponent(String(v))); } return out.join('&'); },
  parse:function(s){ var out={}; try{ String(s||'').split('&').forEach(function(p){ if(!p)return; var kv=p.split('='); var k=decodeURIComponent(kv[0]); var v=kv.length>1?decodeURIComponent(kv.slice(1).join('=')):''; if(out[k]===undefined)out[k]=v; else if(Array.isArray(out[k]))out[k].push(v); else out[k]=[out[k],v]; }); }catch(e){} return out; }
};
''',
  'dayjs': r'''
function __dayjsPad(n){ n=Number(n); return (n<10?'0':'')+n; }
function __dayjsFmt(d,f){ try{ var s=String(f||''); var Y=d.getFullYear(),M=__dayjsPad(d.getMonth()+1),D=__dayjsPad(d.getDate()),h=__dayjsPad(d.getHours()),m=__dayjsPad(d.getMinutes()),sec=__dayjsPad(d.getSeconds()); return s.replace(/YYYY/g,Y).replace(/MM/g,M).replace(/DD/g,D).replace(/HH/g,h).replace(/mm/g,m).replace(/ss/g,sec); }catch(e){ return ''; } }
function __dayjs(v){ var d=(v===undefined||v===null)?new Date():new Date(v); if(isNaN(d.getTime()))d=new Date(); return {format:function(f){ return __dayjsFmt(d,f); }, valueOf:function(){ return d.getTime(); }, toString:function(){ return d.toString(); }}; };
__dayjs.unix=function(t){ var d=new Date(Number(t)*1000); return {format:function(f){ return __dayjsFmt(d,f); }, valueOf:function(){ return d.getTime(); }}; };
module.exports=__dayjs;
''',
  'he': r'''
function __heDecode(s){
  return String(s==null?"":s).replace(/&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g,function(m,e){
    if(e.charAt(0)==="#"){ var hex=e.charAt(1)==="x"||e.charAt(1)==="X"; var code=parseInt(hex?e.slice(2):e.slice(1),hex?16:10); if(isFinite(code)){ if(code>65535){code-=65536;return String.fromCharCode(55296+(code>>10),56320+(code&1023));} return String.fromCharCode(code); } return m; }
    if(e==="amp")return "&"; if(e==="lt")return "<"; if(e==="gt")return ">"; if(e==="quot")return '"'; if(e==="apos"||e==="#39")return "'"; if(e==="nbsp")return String.fromCharCode(160); return m;
  });
}
function __heEncode(s){ return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;"); }
module.exports={decode:__heDecode, encode:__heEncode};
''',
  'pako': r'''
function __pakoBytes(v){
    if (typeof v === 'string') { var bin = __bakaUtf8Encode(v); var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }
    var u2 = new Uint8Array(v.length); for (var j = 0; j < v.length; j++) u2[j] = v[j] & 255; return u2;
}
function __pakoUnpack(u){ var bin = ''; for (var i = 0; i < u.length; i++) bin += String.fromCharCode(u[i]); return bin; }
function __pakoB64ToBytes(b64){ return __pakoBytes(atob(String(b64)).split('').map(function(c){ return c.charCodeAt(0); })); }
module.exports = {
    inflate: function(v, opts){
        var out = __pakoB64ToBytes(BakaHttp.inflate(btoa(__pakoUnpack(__pakoBytes(v)))));
        if (opts && opts.to === 'string') return __bakaUtf8Decode(__pakoUnpack(out));
        return makeBuffer(out);
    },
    ungzip: function(v){ return this.inflate(v); }
};
''',
  // cheerio 子集：支持榜单页解析所需的 load、选择器、children、find、attr、text 等，属性与文本进行实体解码
  'cheerio': r'''
function __cqDecode(s){
return String(s==null?"":s).replace(/&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g,function(m,e){
if(e.charAt(0)==="#"){
var hex=e.charAt(1)==="x"||e.charAt(1)==="X";
var code=parseInt(hex?e.slice(2):e.slice(1),hex?16:10);
if(isFinite(code)){
if(code>65535){code-=65536;return String.fromCharCode(55296+(code>>10),56320+(code&1023));}
return String.fromCharCode(code);
}
return m;
}
if(e==="amp")return "&";
if(e==="lt")return "<";
if(e==="gt")return ">";
if(e==="quot")return '"';
if(e==="apos")return "'";
if(e==="nbsp")return String.fromCharCode(160);
return m;
});
}
var __cqVoids={area:1,base:1,br:1,col:1,embed:1,hr:1,img:1,input:1,link:1,meta:1,param:1,source:1,track:1,wbr:1};
function __cqAttrs(s){
var out={};
var re=/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
var m;
while((m=re.exec(s))!==null){var v=m[2]!==undefined?m[2]:(m[3]!==undefined?m[3]:(m[4]!==undefined?m[4]:""));out[m[1].toLowerCase()]=__cqDecode(v);}
return out;
}
function __cqParse(html){
var root={type:"root",name:"",tagName:"",attribs:{},children:[],parent:null};
var stack=[root];
var src=String(html==null?"":html);
var re=/<!--[\s\S]*?-->|<![^>]*>|<(\/?)([a-zA-Z][a-zA-Z0-9]*)((?:"[^"]*"|'[^']*'|[^>"'])*)(\/?)>|([^<]+)/g;
var m;var raw=null;
while((m=re.exec(src))!==null){
if(m[5]!==undefined){var holder=raw||stack[stack.length-1];holder.children.push({type:"text",data:m[5],parent:holder});continue;}
if(m[2]===undefined)continue;
var name=m[2].toLowerCase();
if(raw){if(m[1]==="/"&&name===raw.name){raw=null;}else{raw.children.push({type:"text",data:m[0],parent:raw});}continue;}
if(m[1]==="/"){for(var i=stack.length-1;i>0;i--){if(stack[i].name===name){stack.length=i;break;}}continue;}
var top=stack[stack.length-1];
var el={type:"tag",name:name,tagName:name,attribs:__cqAttrs(m[3]||""),children:[],parent:top};
top.children.push(el);
if(m[4]!=="/"&&!__cqVoids[name]){stack.push(el);if(name==="script"||name==="style"){raw=el;}}
}
return root;
}
function __cqMatch(el,sel){
if(!el||el.type!=="tag")return false;
var s=String(sel||"").replace(/^\s+|\s+$/g,"");
if(!s||s==="*")return true;
// 去掉伪类，按基础部分匹配
s=s.replace(/:(first|last|even|odd|eq\(\d+\)|nth-child\(\d+\)|contains\([^)]*\))/g,"").replace(/^\s+|\s+$/g,"");
if(!s)return true;
// 属性选择器
var attr=null; var attrVal=null; var hasAttr=false;
var lb=s.indexOf("[");
if(lb>=0){ var rb=s.lastIndexOf("]"); if(rb>lb){ var inside=s.slice(lb+1,rb); s=(s.slice(0,lb)+s.slice(rb+1)).replace(/^\s+|\s+$/g,""); var eq=inside.indexOf("="); if(eq>=0){ attr=inside.slice(0,eq).replace(/^\s+|\s+$/g,"").toLowerCase(); attrVal=inside.slice(eq+1).replace(/^\s+|\s+$/g,"").replace(/^["']|["']$/g,""); } else { attr=inside.replace(/^\s+|\s+$/g,"").toLowerCase(); } hasAttr=true; } }
// id 选择器
var hash=s.indexOf("#");
if(hash>=0){ var after=s.slice(hash+1).split(".")[0].split(" ")[0]; if((el.attribs["id"]||"")!==after)return false; s=(s.slice(0,hash)+" "+s.slice(hash+1+after.length)).replace(/^\s+|\s+$/g,""); if(!s&&!hasAttr)return true; if(!s)return !hasAttr||(attr?(attrVal!=null?(el.attribs[attr]||"")==__cqDecode(attrVal):(el.attribs[attr]!==undefined)):true); }
if(!s){ if(!hasAttr)return true; if(attrVal!=null)return (el.attribs[attr]||"")==__cqDecode(attrVal); return el.attribs[attr]!==undefined; }
// 支持 tag/.cls/tag.cls、id 与属性选择器
var dot=s.indexOf(".");
var tag=dot<0?s:s.slice(0,dot).split(" ")[0];
// 后代选择器按最后一节匹配
if(tag.indexOf(" ")>=0){ var parts=tag.split(" "); tag=parts[parts.length-1]; }
if(tag&&tag!=="*"&&el.name!==tag.toLowerCase())return false;
if(dot<0){ if(!hasAttr)return true; if(attrVal!=null)return (el.attribs[attr]||"")==__cqDecode(attrVal); return el.attribs[attr]!==undefined; }
var need=s.slice(dot+1).split(".");
var cls=" "+(el.attribs["class"]|| "")+" ";
for(var i=0;i<need.length;i++){ var c=need[i].split(" ")[0]; if(c&&cls.indexOf(" "+c+" ")<0)return false; }
if(!hasAttr)return true;
if(attrVal!=null)return (el.attribs[attr]||"")==__cqDecode(attrVal);
return el.attribs[attr]!==undefined;
}
function __cqSelChain(root,sel,out){
var groups=String(sel||"").split(",");
for(var gi=0;gi<groups.length;gi++){ var g=groups[gi].replace(/^\s+|\s+$/g,""); if(!g)continue; var chain=g.split(">").map(function(p){return p.replace(/^\s+|\s+$/g,"");}).filter(function(p){return p;}); if(chain.length<=1){ var parts=g.split(" ").filter(function(p){return p;}); var last=parts.length?parts[parts.length-1]:g; __cqDesc(root,last,out); } else { var cur=[root]; for(var ci=0;ci<chain.length;ci++){ var next=[]; for(var a=0;a<cur.length;a++){ var kids=cur[a].children||[]; for(var b=0;b<kids.length;b++){ if(kids[b].type==="tag"&&__cqMatch(kids[b],chain[ci]))next.push(kids[b]); } } cur=next; } for(var k=0;k<cur.length;k++)out.push(cur[k]); } }
return out;
}
function __cqDesc(el,sel,out){
var kids=el.children||[];
for(var i=0;i<kids.length;i++){var k=kids[i];if(k.type==="tag"){if(__cqMatch(k,sel))out.push(k);__cqDesc(k,sel,out);}}
return out;
}
function __cqText(el){
if(!el)return "";
if(el.type==="text")return el.data;
var s="";var kids=el.children||[];
for(var i=0;i<kids.length;i++)s+=__cqText(kids[i]);
return s;
}
function __cqWrap(nodes){
var arr=[];
for(var i=0;i<nodes.length;i++)arr.push(nodes[i]);
arr.children=function(sel){var out=[];for(var a=0;a<arr.length;a++){var kids=arr[a].children||[];for(var b=0;b<kids.length;b++){if(kids[b].type==="tag"&&(sel==null||__cqMatch(kids[b],sel)))out.push(kids[b]);}}return __cqWrap(out);};
arr.find=function(sel){var out=[];for(var a=0;a<arr.length;a++){ if(String(sel||"").indexOf(",")>=0||String(sel||"").indexOf(">")>=0||String(sel||"").replace(/^\s+|\s+$/g,"").split(" ").length>1){__cqSelChain(arr[a],sel,out);} else __cqDesc(arr[a],sel,out);}return __cqWrap(out);};
arr.parent=function(){var out=[];for(var a=0;a<arr.length;a++){var p=arr[a].parent;if(p&&p.type==="tag"&&out.indexOf(p)<0)out.push(p);}return __cqWrap(out);};
arr.parents=function(sel){var out=[];for(var a=0;a<arr.length;a++){var p=arr[a].parent;while(p){if(p.type==="tag"&&(sel==null||__cqMatch(p,sel))&&out.indexOf(p)<0)out.push(p);p=p.parent;}}return __cqWrap(out);};
arr.siblings=function(sel){var out=[];for(var a=0;a<arr.length;a++){var p=arr[a].parent;if(!p)continue;var kids=p.children||[];for(var b=0;b<kids.length;b++){if(kids[b].type==="tag"&&kids[b]!==arr[a]&&(sel==null||__cqMatch(kids[b],sel))&&out.indexOf(kids[b])<0)out.push(kids[b]);}}return __cqWrap(out);};
arr.next=function(){var out=[];for(var a=0;a<arr.length;a++){var p=arr[a].parent;if(!p)continue;var kids=p.children||[];for(var b=0;b<kids.length;b++){if(kids[b]===arr[a]){for(var c=b+1;c<kids.length;c++){if(kids[c].type==="tag"){out.push(kids[c]);break;}}break;}}}return __cqWrap(out);};
arr.prev=function(){var out=[];for(var a=0;a<arr.length;a++){var p=arr[a].parent;if(!p)continue;var kids=p.children||[];for(var b=0;b<kids.length;b++){if(kids[b]===arr[a]){for(var c=b-1;c>=0;c--){if(kids[c].type==="tag"){out.push(kids[c]);break;}}break;}}}return __cqWrap(out);};
arr.filter=function(sel){var out=[];for(var a=0;a<arr.length;a++){if(typeof sel==="function"){if(sel.call(arr[a],a,arr[a]))out.push(arr[a]);}else if(__cqMatch(arr[a],sel))out.push(arr[a]);}return __cqWrap(out);};
arr.is=function(sel){for(var a=0;a<arr.length;a++){if(__cqMatch(arr[a],sel))return true;}return false;};
arr.hasClass=function(c){for(var a=0;a<arr.length;a++){var cls=" "+(arr[a].attribs?arr[a].attribs["class"]||"":"")+" ";if(cls.indexOf(" "+c+" ")>=0)return true;}return false;};
arr.attr=function(name,value){if(value===undefined){for(var a=0;a<arr.length;a++){var el=arr[a];if(el&&el.type==="tag"&&el.attribs){var v=el.attribs[String(name).toLowerCase()];if(v!==undefined)return v;}}return undefined;}return arr;};
arr.text=function(){var s="";for(var a=0;a<arr.length;a++)s+=__cqText(arr[a]);return __cqDecode(s);};
arr.html=function(){var s="";for(var a=0;a<arr.length;a++){var kids=arr[a].children||[];for(var b=0;b<kids.length;b++)s+=__cqHtml(kids[b]);}return s;};
arr.each=function(fn){for(var a=0;a<arr.length;a++)fn.call(arr[a],a,arr[a]);return arr;};
arr.map=function(fn){var out=[];for(var a=0;a<arr.length;a++){var r=fn.call(arr[a],a,arr[a]);if(r!=null){if(Object.prototype.toString.call(r)==="[object Array]"){for(var b=0;b<r.length;b++)out.push(r[b]);}else out.push(r);}}return __cqWrap(out);};
arr.toArray=function(){var c=[];for(var a=0;a<arr.length;a++)c.push(arr[a]);return c;};
arr.get=function(i){return i==null?arr.toArray():arr[i];};
arr.first=function(){return __cqWrap(arr.length?[arr[0]]:[]);};
arr.last=function(){return __cqWrap(arr.length?[arr[arr.length-1]]:[]);};
arr.eq=function(i){var n=i<0?arr.length+i:i;return __cqWrap((n>=0&&n<arr.length)?[arr[n]]:[]);};
arr.length=arr.length;
return arr;
}
function __cqHtml(el){
if(!el)return "";
if(el.type==="text")return el.data;
var s="<"+el.name; for(var k in el.attribs){ if(Object.prototype.hasOwnProperty.call(el.attribs,k))s+=' '+k+'="'+String(el.attribs[k]).replace(/"/g,"&quot;")+'"'; } s+=">"; var kids=el.children||[]; for(var i=0;i<kids.length;i++)s+=__cqHtml(kids[i]); s+="</"+el.name+">"; return s;
}
function __cqLoad(html,opts){
var root=__cqParse(html);
var fn=function(sel){
if(typeof sel==="string"){var out=[];__cqSelChain(root,sel,out);return __cqWrap(out);}
if(sel&&sel.type)return __cqWrap([sel]);
if(Object.prototype.toString.call(sel)==="[object Array]")return __cqWrap(sel);
return __cqWrap([]);
};
return fn;
}
module.exports={load:__cqLoad};
''',
  '@react-native-cookies/cookies': r'''module.exports={get:function(){return {};},set:function(){return true;}};''',
  'webdav': r'''module.exports={createClient:function(){return {getDirectoryContents:function(){return [];},getFileContents:function(){return null;},putFileContents:function(){return false;}};}};''',
  'musicfree/storage': r'''module.exports={getItem:function(){return null;},setItem:function(){},removeItem:function(){}};''',
};

/// 生成模块工厂注册代码（在 [jsBridgePrelude] 之后求值）
String buildModuleFactoriesSource() {
  final buf = StringBuffer();
  jsModuleScripts.forEach((name, source) {
    buf.write('__bakaModuleFactories[');
    buf.write(jsonEncode(name));
    buf.write('] = function(module, exports){\n');
    buf.write(source);
    if (!source.endsWith('\n')) buf.write('\n');
    buf.write('};\n');
  });
  return buf.toString();
}

/// 同步运行时兼容实现：提供同步 Promise、任意值的 then/catch、同步 setTimeout，与 stripAsyncAwait 配套使用
const String jsRuntimeBootstrap = r'''
var __root = this;
function setTimeout(fn){ try { if (typeof fn === 'function') fn(); } catch (e) {} return 0; }
function clearTimeout(id) {}
function setInterval(fn){ return 0; }
function clearInterval(id) {}
__root.setTimeout = setTimeout;
__root.clearTimeout = clearTimeout;
__root.setInterval = setInterval;
__root.clearInterval = clearInterval;
function __BakaRejected(err){ this.__baka_error = err; }
// 空结果占位：链式 .then/.catch 不因 undefined 中断（真 Promise 语义近似）
var __bakaVoid = {};
__bakaVoid.then = function(){ return __bakaVoid; };
__bakaVoid.catch = function(){ return __bakaVoid; };
function __bakaWrap(r){ return (r === undefined || r === null) ? __bakaVoid : r; }
function __bakaUnwrap(v){ var g = 0; while ((v instanceof Promise) && g++ < 8) v = v._v; return v; }
__BakaRejected.prototype.then = function(onF, onR){
  if (typeof onR === 'function') {
    try { return __bakaWrap(onR(this.__baka_error)); }
    catch (e2) { return new __BakaRejected(e2); }
  }
  return this;
};
__BakaRejected.prototype.catch = function(onR){ return this.then(undefined, onR); };
Object.defineProperty(Object.prototype, 'then', {configurable: true, writable: true, enumerable: false, value: function(onF, onR){
  var self = __bakaUnwrap(this);
  // 同步垫片：字符串等基元调用 .then 时 this 会被装箱为 String/Number/Boolean 对象，
  // 若直接透传会导致 typeof 变为 object（如 validateUrl 误判），此处拆箱回基元
  try {
    if (self instanceof String || self instanceof Number || self instanceof Boolean) self = self.valueOf();
  } catch (e0) {}
  if (self instanceof __BakaRejected) {
    if (typeof onR === 'function') {
      try { return __bakaWrap(onR(self.__baka_error)); }
      catch (e2) { return new __BakaRejected(e2); }
    }
    return self;
  }
  try { return __bakaWrap((typeof onF === 'function') ? onF(self) : self); }
  catch (e) {
    if (typeof onR === 'function') {
      try { return __bakaWrap(onR(e)); }
      catch (e2) { return new __BakaRejected(e2); }
    }
    return new __BakaRejected(e);
  }
}});
Object.defineProperty(Object.prototype, 'catch', {configurable: true, writable: true, enumerable: false, value: function(onR){ return this.then(undefined, onR); }});
// 同步垫片必须提供 finally，否则安装期直接 TypeError 中断，inited 永不发送
// finally 回调无参执行，抛错则转为 rejected，否则透传原值/原拒绝态
Object.defineProperty(Object.prototype, 'finally', {configurable: true, writable: true, enumerable: false, value: function(onF){
  try { if (typeof onF === 'function') onF(); } catch (e) { return new __BakaRejected(e); }
  return this;
}});
function Promise(executor){
  var self = this;
  self._v = undefined;
  function resolve(v){ self._v = (v instanceof Promise) ? v._v : v; }
  function reject(e){ self._v = new __BakaRejected(e); }
  try { executor(resolve, reject); } catch (e) { reject(e); }
  // 同步垫片：await 被剥离后 `const res = httpRequest(...)` 直接拿到 Promise，
  // 而原生语义应拿到 resolved 值。经 Proxy 将未知属性透传到 _v（如 res.body/statusCode），
  // 原生 `then/catch/finally/_v/__baka_error` 优先走自身，避免透传破坏链式语义
  if (typeof Proxy !== 'undefined') {
    try {
      return new Proxy(self, {
        get: function(t, p, r){
          if (p in t) return t[p];
          var v = t._v;
          if (v !== null && typeof v === 'object' && !(v instanceof __BakaRejected) && v !== __bakaVoid) {
            if (p in Object(v)) return v[p];
          }
          return undefined;
        }
      });
    } catch (e2) {}
  }
}
Promise.resolve = function(v){ return (v instanceof Promise) ? v._v : v; };
Promise.reject = function(e){ return new __BakaRejected(e); };
Promise.all = function(values){
  var out = []; var list = values || [];
  for (var i = 0; i < list.length; i++) {
    var v = list[i];
    if (v instanceof Promise) v = v._v;
    if (v instanceof __BakaRejected) throw v.__baka_error;
    out.push(v);
  }
  return out;
};
Promise.race = function(values){
  var list = values || [];
  for (var i = 0; i < list.length; i++) {
    var v = list[i];
    if (v instanceof Promise) v = v._v;
    if (!(v instanceof __BakaRejected)) return v;
  }
  if (list.length) { var last = list[list.length - 1]; return (last instanceof Promise) ? last._v : last; }
  return undefined;
};
Promise.allSettled = function(values){
  var out = []; var list = values || [];
  for (var i = 0; i < list.length; i++) {
    var v = list[i];
    if (v instanceof Promise) v = v._v;
    if (v instanceof __BakaRejected) out.push({status: 'rejected', reason: v.__baka_error});
    else out.push({status: 'fulfilled', value: v});
  }
  return out;
};
// 剥离 async 后 handler.fn 抛同步异常会导致原生 map 直接抛错、中断 allSettled 与后续顺序回退
//（原生 async 下只会返回 rejected Promise），此处仅对处理器链特征数组按元素捕获转 rejected，
// 普通数据 map 仍走原生抛错语义，避免误吞业务异常
try {
  var __origMap = Array.prototype.map;
  Array.prototype.map = function(fn, thisArg){
    try {
      if (this != null && this.length > 0 && this.length <= 10) {
        var f0 = this[0];
        if (f0 != null && typeof f0 === 'object' && typeof f0.fn === 'function') {
          var o = new Array(this.length);
          for (var mi=0; mi<this.length; mi++){
            try { o[mi] = fn.call(thisArg, this[mi], mi, this); }
            catch(me){ o[mi] = Promise.reject(me); }
          }
          return o;
        }
      }
    } catch(e2){}
    return __origMap.call(this, fn, thisArg);
  };
} catch(eMap){}
Promise.any = function(values){
  var list = values || []; var firstErr = null; var seen = false;
  for (var i = 0; i < list.length; i++) {
    var v = list[i];
    if (v instanceof Promise) v = v._v;
    if (v instanceof __BakaRejected) { if (!seen) { firstErr = v.__baka_error; seen = true; } continue; }
    return v;
  }
  throw seen ? firstErr : new Error('All promises were rejected');
};
globalThis.Promise = Promise;
function HashValue(value, enc){ this.value = String(value); this.enc = enc || null; }
HashValue.prototype.toString = function(fmt){
  if (fmt === CryptoJs.enc.Hex) {
    if (this.enc === 'hex') return this.value;
    if (this.enc === 'base64') return __bakaBinToHex(atob(this.value));
    return __bakaBinToHex(__bakaUtf8Encode(this.value));
  }
  if (fmt === CryptoJs.enc.Base64) {
    if (this.enc === 'base64') return this.value;
    if (this.enc === 'hex') return btoa(__bakaHexToBin(this.value));
    return btoa(__bakaUtf8Encode(this.value));
  }
  if (fmt === CryptoJs.enc.Utf8) {
    if (this.enc === 'base64') return __bakaUtf8Decode(atob(this.value));
    if (this.enc === 'hex') return __bakaUtf8Decode(__bakaHexToBin(this.value));
    return this.value;
  }
  return this.value;
};
function hash(name, value){ return new HashValue(BakaHttp[name](String(value)), 'hex'); }
var CryptoJs = {};
CryptoJs.MD5 = function(value){ return hash('md5', value); };
CryptoJs.SHA1 = function(value){ return hash('sha1', value); };
CryptoJs.SHA256 = function(value){ return hash('sha256', value); };
CryptoJs.SHA512 = function(value){ return hash('sha512', value); };
CryptoJs.HmacSHA256 = function(value, key){ return new HashValue(BakaHttp.hmacSha256(String(key), String(value)), 'hex'); };
CryptoJs.HmacSHA1 = function(value, key){ return new HashValue(BakaHttp.hmacSha1(String(key), String(value)), 'hex'); };
CryptoJs.HmacMD5 = function(value, key){ return new HashValue(BakaHttp.hmacMd5(String(key), String(value)), 'hex'); };
CryptoJs.enc = {
  Utf8: {parse: function(value){ return new HashValue(value, 'utf8'); }, stringify: function(value){ return String(value.value || value); }},
  Hex: {parse: function(value){ return new HashValue(value, 'hex'); }, stringify: function(value){ return String(value.value || value); }},
  Base64: {parse: function(value){ return new HashValue(__bakaUtf8Decode(atob(String(value))), 'utf8'); }, stringify: function(value){ return String(value.value || value); }}
};
CryptoJs.mode = {ECB: {name: 'ECB'}, CBC: {name: 'CBC'}};
CryptoJs.pad = {Pkcs7: {}};
CryptoJs.AES = {encrypt: function(value, key, config){
  var mode = config && config.mode && config.mode.name ? config.mode.name : 'CBC';
  var iv = config && config.iv ? String(config.iv.value || config.iv) : '';
  var cipher = new HashValue(BakaHttp.aes(mode, String(key.value || key), iv, String(value.value || value)), 'base64');
  return {ciphertext: cipher, toString: function(){ return cipher.toString(); }};
}, decrypt: function(cipher, key, config){
  var mode = config && config.mode && config.mode.name ? config.mode.name : 'CBC';
  var iv = config && config.iv ? String(config.iv.value || config.iv) : '';
  var ctext = (cipher && cipher.ciphertext) ? String(cipher.ciphertext.value || cipher.ciphertext) : String(cipher);
  var plain = BakaHttp.aesDecrypt(mode, String(key.value || key), iv, ctext);
  return {toString: function(fmt){ if (fmt === CryptoJs.enc.Utf8 || fmt === undefined) return plain; if (fmt === CryptoJs.enc.Hex) return __bakaBinToHex(__bakaUtf8Encode(plain)); if (fmt === CryptoJs.enc.Base64) return btoa(__bakaUtf8Encode(plain)); return plain; }};
}};
function atob(value){
  var table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  var input = String(value).replace(/=+$/, ''); var output = ''; var buffer = 0; var bits = 0;
  for (var i = 0; i < input.length; i++) { var n = table.indexOf(input.charAt(i)); if (n < 0) continue; buffer = (buffer << 6) | n; bits += 6; if (bits >= 8) { bits -= 8; output += String.fromCharCode((buffer >> bits) & 255); } }
  return output;
}
function btoa(value){
  var table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/='; var output = '';
  for (var i = 0; i < value.length; i += 3) { var a = value.charCodeAt(i), b = value.charCodeAt(i + 1), c = value.charCodeAt(i + 2); var n = (a << 16) | ((isNaN(b) ? 0 : b) << 8) | (isNaN(c) ? 0 : c); output += table[(n >> 18) & 63] + table[(n >> 12) & 63] + (isNaN(b) ? '=' : table[(n >> 6) & 63]) + (isNaN(c) ? '=' : table[n & 63]); }
  return output;
}
function __bakaUtf8Encode(s){ return unescape(encodeURIComponent(String(s))); }
function __bakaUtf8Decode(bin){ try { return decodeURIComponent(escape(bin)); } catch (e) { return bin; } }
function __bakaHexToBin(hex){ var h = String(hex).replace(/^0x/i, ''); if (h.length % 2) h = '0' + h; var out = ''; for (var i = 0; i < h.length; i += 2) out += String.fromCharCode(parseInt(h.substr(i, 2), 16)); return out; }
function __bakaBinToHex(bin){ var out = ''; for (var i = 0; i < bin.length; i++) { var h = bin.charCodeAt(i).toString(16); out += (h.length < 2 ? '0' : '') + h; } return out; }
function makeBuffer(value){
  value.toString = function(encoding){
    var bin = ''; for (var i = 0; i < value.length; i++) bin += String.fromCharCode(value[i]);
    if (encoding === 'base64') return btoa(bin);
    if (encoding === 'hex') return __bakaBinToHex(bin);
    return __bakaUtf8Decode(bin);
  };
  var _slice = value.slice, _sub = value.subarray;
  value.slice = function(s, e){ return makeBuffer(_slice.call(value, s, e)); };
  value.subarray = function(s, e){ return makeBuffer(_sub.call(value, s, e)); };
  return value;
}
var Buffer = {};
Buffer.from = function(value, encoding){
  if (typeof value === 'string') {
    var enc = String(encoding || 'utf8').toLowerCase();
    var bin = enc === 'base64' ? atob(value) : enc === 'hex' ? __bakaHexToBin(value) : __bakaUtf8Encode(value);
    var bytes = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 255; return makeBuffer(bytes);
  }
  if (value instanceof Uint8Array) { var c = new Uint8Array(value.length); c.set(value); return makeBuffer(c); }
  var arr = new Uint8Array((value && value.length) || 0); for (var j = 0; j < arr.length; j++) arr[j] = (value[j] || 0) & 255; return makeBuffer(arr);
};
Buffer.alloc = function(size, fill){ var a = new Uint8Array(size || 0); if (fill) a.fill(typeof fill === 'number' ? fill : 0); return makeBuffer(a); };
Buffer.concat = function(list){ var size = 0; for (var i = 0; i < list.length; i++) size += list[i].length; var result = new Uint8Array(size); var offset = 0; for (var j = 0; j < list.length; j++) { result.set(list[j], offset); offset += list[j].length; } return makeBuffer(result); };
Buffer.isBuffer = function(value){ return value instanceof Uint8Array; };
Buffer.byteLength = function(s){ return __bakaUtf8Encode(s).length; };
globalThis.Buffer = Buffer; globalThis.atob = atob; globalThis.btoa = btoa;
function TextEncoder(){ this.encode = function(value){ var bin = __bakaUtf8Encode(value); var out = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return makeBuffer(out); }; }
function TextDecoder(label){
  var enc = String(label || 'utf-8').toLowerCase();
  this.decode = function(value){
    if (!value) return '';
    if (typeof value === 'string') return value;
    var bin = ''; for (var i = 0; i < value.length; i++) bin += String.fromCharCode(value[i]);
    if (enc === 'utf-8' || enc === 'utf8') return __bakaUtf8Decode(bin);
    try { return BakaHttp.textDecode(btoa(bin), enc); } catch (e) { return __bakaUtf8Decode(bin); }
  };
}
globalThis.TextEncoder = TextEncoder; globalThis.TextDecoder = TextDecoder;
function URL(value){
  var self = this;
  self.href = String(value);
  self.protocol = (self.href.match(/^https?:/i) || [''])[0];
  self.hostname = (self.href.match(/^https?:\/\/([^/:?#]+)/i) || ['', ''])[1];
  self.host = self.hostname;
  Object.defineProperty(self, 'pathname', {configurable: true, enumerable: true,
    get: function(){ return (self.href.match(/^https?:\/\/[^/]+([^?#]*)/i) || ['', '/'])[1]; },
    set: function(p){ self.href = self.href.replace(/^((?:https?:)?\/\/[^/?#]+)[^?#]*/, function(m, o){ return o + p; }); }
  });
  self.searchParams = {set: function(key, val){
    var part = encodeURIComponent(key) + '=' + encodeURIComponent(val);
    self.href += (self.href.indexOf('?') >= 0 ? '&' : '?') + part;
  }, get: function(key){
    try { var m = self.href.match(/[?&]([^#]*)/); if (!m) return null; var pairs = m[1].split('&'); for (var i = 0; i < pairs.length; i++) { var kv = pairs[i].split('='); if (decodeURIComponent(kv[0]) === String(key)) return kv.length > 1 ? decodeURIComponent(kv.slice(1).join('=')) : ''; } } catch (e) {}
    return null;
  }, append: function(key, val){ this.set(key, val); }};
  Object.defineProperty(self, 'search', {configurable: true, enumerable: true, get: function(){ var m = self.href.match(/\?([^#]*)/); return m ? ('?' + m[1]) : ''; }});
  Object.defineProperty(self, 'origin', {configurable: true, enumerable: true, get: function(){ var m = self.href.match(/^(https?:\/\/[^/?#]+)/i); return m ? m[1] : ''; }});
  self.toString = function(){ return self.href; };
}
globalThis.URL = URL; globalThis.CryptoJS = CryptoJs; globalThis.CryptoJs = CryptoJs;
// 补齐透传的 env/process 全局，缺失会导致 ReferenceError
try {
  if (typeof process === 'undefined') { globalThis.process = {platform: 'android', version: '1.0.0', env: {}}; }
  if (typeof env === 'undefined') { globalThis.env = {}; }
} catch (e) {}
// 重放确定性补丁：Date.now/Math.random 经桥按同一次 invoke 的位置记忆返回，
// 避免插件签名/时间戳参数在重放轮次间漂移导致请求序列永远失配；
// 桥不可用（操作未知等）时回退原生实现，Baka 挂起/取消标记原样抛出
(function(){
  var __realNow = Date.now;
  var __realRandom = Math.random;
  var __bakaThrow = function(e){
    if (e && typeof e.message === 'string' && e.message.indexOf('Baka') === 0) throw e;
  };
  Date.now = function(){
    try {
      var v = Number(__bakaCall('timeNow', []));
      if (isFinite(v) && v > 0) return v;
    } catch (e) { __bakaThrow(e); }
    return __realNow.call(Date);
  };
  Math.random = function(){
    try {
      var v = Number(__bakaCall('randomUnit', []));
      if (isFinite(v) && v >= 0 && v < 1) return v;
    } catch (e) { __bakaThrow(e); }
    return __realRandom.call(Math);
  };
})();
''';

/// 网易搜索补丁：跳过逐首查询音质的串行请求，仅保留批量查询以保证搜索速度
/// 需在 stripAsyncAwait 之前执行
String patchNeteaseSearchBloat(String source) {
  const needle = 'await getBatchMusicQualityInfo(idList)';
  if (!source.contains(needle)) return source;
  return source.replaceAll(needle, '({})');
}

/// 酷我榜单补丁：榜单详情仅解析列表字段以快速呈现，无封面的歌曲由 UI 层按需补全；
/// 歌单导入仍通过单次搜索补全信息。仅修改运行时加载的源码副本
String patchKuwoTopListDetail(String source) {
  if (!source.contains('kbangserver.kuwo.cn/ksong.s')) return source;
  var out = source;
  out = out.replaceAll(
    'res.data.musiclist.map((_) => {\n'
        '        const rid = _.musicrid || _.id;\n'
        '\n'
        '        return Promise.all([\n'
        '          getPicByRid(rid),\n'
        '          getQualityByMusicId(_.id, _.name, _.artist)\n'
        '        ]).then(([artwork, qualities]) => {',
    'res.data.musiclist.map((_) => {\n'
        '        const rid = _.musicrid || _.id;\n'
        '\n'
        '        // 首屏快速呈现：封面稍后由 UI 层调用搜索补全\n'
        '        return [null, {}].then(([artwork, qualities]) => {',
  );
  out = out.replaceAll(
    'return Promise.all([\n'
        '          getPicByRid(rid),\n'
        '          getQualityByMusicId(_.id, _.name, _.artist)\n'
        '        ]).then(([artwork, qualities]) => {',
    'return kuwoTopListEnrich(_).then(([artwork, qualities]) => {',
  );
  if (!out.contains('function kuwoTopListEnrich')) {
    out = out.replaceAll(
      'function getTopListDetail(topListItem) {',
      'function kuwoTopListEnrich(_) {\n'
          'var params = { client: "kt", all: ((_.name || "") + " " + (_.artist || "")), pn: 0, rn: 1, uid: 2574109560, ver: "kwplayer_ar_8.5.4.2", vipver: 1, ft: "music", cluster: 0, strategy: 2012, encoding: "utf8", rformat: "json", vermerge: 1, mobi: 1 };\n'
          'var res = null;\n'
          'try { res = axios_1.default.get("http://search.kuwo.cn/r.s", { params: params, timeout: 5000 }); } catch (e) { res = null; }\n'
          'var hit = res && res.data && res.data.abslist && res.data.abslist[0];\n'
          'var same = hit && String(hit.MUSICRID || "") === "MUSIC_" + String(_.id || "");\n'
          'var qualities = same && hit.N_MINFO ? parseKuWoQualityInfo(hit.N_MINFO) : {};\n'
          'var artwork = (same && artworkShort2Long(hit.web_albumpic_short)) || null;\n'
          'return [artwork, qualities];\n'
          '}\n'
          'function getTopListDetail(topListItem) {',
    );
  }
  out = out.replaceAll(
    '.then(res => /^http/.test(res.data) ? res.data : null)',
    '.then(res => { var t = String(res.data == null ? "" : res.data).trim(); return /^https?:\\/\\//i.test(t) ? t : null; })',
  );
  out = out.replaceAll(
    'const rawDuration = item?.duration ?? item?.DURATION ?? item?.songtime ?? item?.song_duration;',
    'const rawDuration = item?.song_duration ?? item?.duration ?? item?.DURATION ?? item?.songtime;',
  );
  return out;
}

/// 汽水播放补丁：取流内层 3 次重试改为单次，外层 Router 已按音质循环重试，
/// 内层重复签名+取流只会串行放大耗时直至 50s 超时。仅修改运行时加载的源码副本
String patchQishuiPlayback(String source) {
  if (!source.contains('fetchTrackPlaybackData') ||
      !source.contains('QISHUI_ANDROID_TRACK_BODY_TEMPLATE')) {
    return source;
  }
  return source.replaceAll(
    'for (let attempt = 1; attempt <= 3; attempt++)',
    'for (let attempt = 1; attempt <= 1; attempt++)',
  );
}

/// 插件源码包装
String buildWrappedPluginSource(String source) {
  return 'var exports = module.exports;\n'
      "var __musicfree_require = typeof require !== 'undefined' ? require : globalThis.__musicfree_require;\n"
      '${patchQishuiPlayback(patchKuwoTopListDetail(patchNeteaseSearchBloat(source)))}';
}

const String _regexAllowedPrevious = '([{,;:!&|?+-*%=<>^~>';

const List<String> _regexKeywords = [
  'return',
  'typeof',
  'instanceof',
  'in',
  'of',
  'new',
  'delete',
  'void',
  'throw',
  'case',
  'do',
  'else',
  'yield',
  'await',
];

final RegExp _unicodeLetterOrDigit = RegExp(r'[\p{L}\p{Nd}]', unicode: true);
final RegExp _unicodeLetter = RegExp(r'\p{L}', unicode: true);
final Map<int, bool> _unicodeLetterOrDigitCache = {};
final Map<int, bool> _unicodeLetterCache = {};

bool _isUnicodeLetterOrDigit(int cu) {
  final cached = _unicodeLetterOrDigitCache[cu];
  if (cached != null) return cached;
  final value = _unicodeLetterOrDigit.hasMatch(String.fromCharCode(cu));
  _unicodeLetterOrDigitCache[cu] = value;
  return value;
}

bool _isIdChar(int cu) =>
    (cu >= 48 && cu <= 57) ||
    (cu >= 65 && cu <= 90) ||
    (cu >= 97 && cu <= 122) ||
    cu == 0x5F ||
    cu == 0x24 ||
    (cu > 127 && _isUnicodeLetterOrDigit(cu));


bool _isLetterChar(int cu) {
  if ((cu >= 65 && cu <= 90) || (cu >= 97 && cu <= 122)) return true;
  if (cu <= 127) return false;
  final cached = _unicodeLetterCache[cu];
  if (cached != null) return cached;
  final value = _unicodeLetter.hasMatch(String.fromCharCode(cu));
  _unicodeLetterCache[cu] = value;
  return value;
}


bool _isJsWhitespaceChar(int cu) =>
    (cu >= 0x09 && cu <= 0x0D) ||
    (cu >= 0x1C && cu <= 0x1F) ||
    cu == 0x20 ||
    cu == 0x1680 ||
    (cu >= 0x2000 && cu <= 0x2006) ||
    (cu >= 0x2008 && cu <= 0x200A) ||
    cu == 0x2028 ||
    cu == 0x2029 ||
    cu == 0x205F ||
    cu == 0x3000;

/// 剥离 async/await 为同步调用。跳过字符串/模板文本/注释与正则字面量，
/// `obj.await` 形式的属性访问会被保留
String stripAsyncAwait(String source) {
  final out = StringBuffer();
  final stack = <int>[];
  final exprDepths = <int>[];
  // 0=code 1=lineComment 2=blockComment 3=sq 4=dq 5=template 6=expr
  var state = 0;
  var exprDepth = 0;
  var lastCode = 0;
  var lastWord = '';
  var i = 0;
  final n = source.length;

  int pop() {
    state = stack.isEmpty ? 0 : stack.removeLast();
    return state;
  }

  outer:
  while (i < n) {
    final cu = source.codeUnitAt(i);
    if (state == 1) {
      out.writeCharCode(cu);
      i++;
      if (cu == 0x0A) pop();
    } else if (state == 2) {
      if (cu == 0x2A && i + 1 < n && source.codeUnitAt(i + 1) == 0x2F) {
        out.write('*/');
        i += 2;
        pop();
      } else {
        out.writeCharCode(cu);
        i++;
      }
    } else if (state == 3 || state == 4) {
      final q = state == 3 ? 0x27 : 0x22;
      if (cu == 0x5C && i + 1 < n) {
        out.writeCharCode(cu);
        out.writeCharCode(source.codeUnitAt(i + 1));
        i += 2;
      } else {
        out.writeCharCode(cu);
        i++;
        if (cu == q) pop();
      }
    } else if (state == 5) {
      if (cu == 0x5C && i + 1 < n) {
        out.writeCharCode(cu);
        out.writeCharCode(source.codeUnitAt(i + 1));
        i += 2;
      } else if (cu == 0x60) {
        out.writeCharCode(cu);
        i++;
        pop();
      } else if (cu == 0x24 && i + 1 < n && source.codeUnitAt(i + 1) == 0x7B) {
        out.write(r'${');
        i += 2;
        stack.add(5);
        exprDepths.add(exprDepth);
        exprDepth = 1;
        state = 6;
      } else {
        out.writeCharCode(cu);
        i++;
      }
    } else {
      // state == 0 || state == 6
      if (cu == 0x2F && i + 1 < n && source.codeUnitAt(i + 1) == 0x2F) {
        out.write('//');
        i += 2;
        stack.add(state);
        state = 1;
        continue outer;
      }
      if (cu == 0x2F && i + 1 < n && source.codeUnitAt(i + 1) == 0x2A) {
        out.write('/*');
        i += 2;
        stack.add(state);
        state = 2;
        continue outer;
      }
      if (cu == 0x27) {
        out.writeCharCode(cu);
        i++;
        stack.add(state);
        state = 3;
        continue outer;
      }
      if (cu == 0x22) {
        out.writeCharCode(cu);
        i++;
        stack.add(state);
        state = 4;
        continue outer;
      }
      if (cu == 0x60) {
        out.writeCharCode(cu);
        i++;
        stack.add(state);
        state = 5;
        continue outer;
      }
      if (cu == 0x2F &&
          (i + 1 >= n ||
              (source.codeUnitAt(i + 1) != 0x2F &&
                  source.codeUnitAt(i + 1) != 0x2A))) {
        // 区分正则字面量与除法，避免错误进入字符串状态
        final regexAllowed =
            lastCode == 0 ||
            _regexAllowedPrevious.codeUnits.contains(lastCode) ||
            _regexKeywords.contains(lastWord);
        if (regexAllowed) {
          out.writeCharCode(cu);
          i++;
          var inClass = false;
          var terminated = false;
          while (i < n) {
            final r = source.codeUnitAt(i);
            out.writeCharCode(r);
            if (r == 0x5C && i + 1 < n) {
              out.writeCharCode(source.codeUnitAt(i + 1));
              i += 2;
              continue;
            }
            if (r == 0x0A) break;
            if (r == 0x5B) {
              inClass = true;
            } else if (r == 0x5D) {
              inClass = false;
            } else if (r == 0x2F && !inClass) {
              i++;
              terminated = true;
              break;
            }
            i++;
          }
          if (terminated) {
            while (i < n && _isLetterChar(source.codeUnitAt(i))) {
              out.writeCharCode(source.codeUnitAt(i));
              i++;
            }
          }
          lastCode = 0x78;
          lastWord = '';
          continue outer;
        }
        out.writeCharCode(cu);
        lastCode = cu;
        lastWord = '';
        i++;
        continue outer;
      }
      if (state == 6) {
        if (cu == 0x7B) exprDepth++;
        if (cu == 0x7D) {
          exprDepth--;
          if (exprDepth == 0) {
            out.writeCharCode(cu);
            i++;
            lastCode = cu;
            exprDepth = exprDepths.isEmpty ? 0 : exprDepths.removeLast();
            pop();
            continue outer;
          }
        }
      }
      if (_isIdChar(cu)) {
        var j = i;
        while (j < n && _isIdChar(source.codeUnitAt(j))) {
          j++;
        }
        final word = source.substring(i, j);
        if (word == 'async' &&
            (i == 0 || !_isIdChar(source.codeUnitAt(i - 1))) &&
            lastCode != 0x2E) {
          var k = j;
          while (k < n && _isJsWhitespaceChar(source.codeUnitAt(k))) {
            k++;
          }
          final nextIsParen = k < n && source.codeUnitAt(k) == 0x28;
          // async 字符串方法名（如 async "search"()）
          final nextIsQuotedName =
              k < n &&
              (source.codeUnitAt(k) == 0x22 ||
                  source.codeUnitAt(k) == 0x27 ||
                  source.codeUnitAt(k) == 0x60);
          var nextWord = '';
          var m = k;
          if (!nextIsParen && !nextIsQuotedName) {
            while (m < n && _isIdChar(source.codeUnitAt(m))) {
              m++;
            }
            nextWord = source.substring(k, m);
          }
          var p = m;
          while (p < n && _isJsWhitespaceChar(source.codeUnitAt(p))) {
            p++;
          }
          final identFollowedByParen =
              nextWord.isNotEmpty &&
              nextWord != 'function' &&
              p < n &&
              source.codeUnitAt(p) == 0x28;
          // async 箭头函数同样剥离 async
          var arrowAfterIdent = false;
          if (nextWord.isNotEmpty && nextWord != 'function') {
            if (source.startsWith('=>', p)) {
              arrowAfterIdent = true;
            } else {
              var q = p;
              if (q < n && source.codeUnitAt(q) == 0x3F) q++;
              arrowAfterIdent = source.startsWith('=>', q);
            }
          }
          var arrowAfterParen = false;
          if (nextIsParen) {
            var depth = 0;
            var q = k;
            while (q < n) {
              final ch = source.codeUnitAt(q);
              if (ch == 0x28) {
                depth++;
              } else if (ch == 0x29) {
                depth--;
                if (depth == 0) {
                  q++;
                  break;
                }
              } else if (ch == 0x27 || ch == 0x22 || ch == 0x60) {
                break;
              }
              q++;
            }
            while (q < n && _isJsWhitespaceChar(source.codeUnitAt(q))) {
              q++;
            }
            arrowAfterParen = source.startsWith('=>', q);
          }
          if (nextIsParen ||
              nextIsQuotedName ||
              nextWord == 'function' ||
              identFollowedByParen ||
              arrowAfterIdent ||
              arrowAfterParen) {
            i = k;
            continue outer;
          }
        }
        if (word == 'await' &&
            (i == 0 || !_isIdChar(source.codeUnitAt(i - 1))) &&
            lastCode != 0x2E) {
          var k2 = j;
          while (k2 < n && _isJsWhitespaceChar(source.codeUnitAt(k2))) {
            k2++;
          }
          i = k2;
          continue outer;
        }
        // for await 剥离为 for
        if (word == 'for' &&
            (i == 0 || !_isIdChar(source.codeUnitAt(i - 1))) &&
            lastCode != 0x2E) {
          var k3 = j;
          while (k3 < n && _isJsWhitespaceChar(source.codeUnitAt(k3))) {
            k3++;
          }
          if (source.startsWith('await', k3) &&
              (k3 + 5 >= n || !_isIdChar(source.codeUnitAt(k3 + 5)))) {
            var k4 = k3 + 5;
            while (k4 < n && _isJsWhitespaceChar(source.codeUnitAt(k4))) {
              k4++;
            }
            if (k4 < n && source.codeUnitAt(k4) == 0x28) {
              out.write(word);
              out.write(' ');
              lastCode = 0x72;
              lastWord = word;
              i = k4;
              continue outer;
            }
          }
        }
        out.write(word);
        for (var t = i; t < j; t++) {
          if (!_isJsWhitespaceChar(source.codeUnitAt(t))) {
            lastCode = source.codeUnitAt(t);
          }
        }
        lastWord = word;
        i = j;
        continue outer;
      }
      out.writeCharCode(cu);
      if (!_isJsWhitespaceChar(cu)) lastCode = cu;
      i++;
    }
  }
  return out.toString();
}
