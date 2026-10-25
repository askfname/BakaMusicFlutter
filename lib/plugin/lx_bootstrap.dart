/// LX 取流脚本运行时前置
///
/// 求值顺序：[jsBridgePrelude] → 模块工厂 → [jsRuntimeBootstrap] → 本源码
/// 提供全局 `lx` 对象（同步 request 桥 + 事件注册 + utils）、
/// `__lxRequestHandler` 注册点与 `__lxInvoke` 调用入口；
/// 脚本源码经 stripAsyncAwait 处理后，挂起标记以同步异常传播，
/// 复用 js_worker 的挂起-重放机制
library;

import 'dart:convert';

/// 生成注入脚本元信息（currentScriptInfo）的 LX 运行时前置源码
String lxRuntimeSource(String infoJson) =>
    _lxPrelude.replaceFirst('__BAKA_LX_INFO_JSON__', jsonEncode(infoJson));

const String _lxPrelude = r'''
var __bakaLxSourcesDeclaredRaw = null;
globalThis.window = globalThis; globalThis.self = globalThis; globalThis.global = globalThis;
globalThis.__lxRequestHandler = null;
(function(){
  function b64ToBytes(b64){ var bin = atob(String(b64)); var u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i) & 255; return u; }
  function bytesToB64(u){ var bin = ''; for (var i = 0; i < u.length; i++) bin += String.fromCharCode(u[i]); return btoa(bin); }
  function parseBody(text){
    if (typeof text !== 'string') return text;
    var t = text.trim();
    if (t.charAt(0) === '{' || t.charAt(0) === '[') { try { return JSON.parse(text); } catch (e) { return text; } }
    return text;
  }
  var __info = (function(){ try { var v = JSON.parse(__BAKA_LX_INFO_JSON__); return (v && typeof v === 'object') ? v : {}; } catch (e) { return {}; } })();
  globalThis.lx = {
    EVENT_NAMES: {request: 'request', inited: 'inited', updateAlert: 'updateAlert', showConfigView: 'showConfigView'},
    request: function(url, options, callback){
      if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) throw new Error('LX request URL is invalid');
      if (typeof callback !== 'function') throw new Error('LX request callback is required');
      var opts = (options && typeof options === 'object') ? options : {};
      var method = typeof opts.method === 'string' ? opts.method : 'GET';
      var headers = (opts.headers && typeof opts.headers === 'object') ? opts.headers : {};
      var timeout = (typeof opts.timeout === 'number' && opts.timeout > 0) ? opts.timeout : 15000;
      var binary = opts.binary === true;
      var outHeaders = {};
      for (var hk in headers) { if (Object.prototype.hasOwnProperty.call(headers, hk)) outHeaders[hk] = String(headers[hk]); }
      var cfg = {url: url, method: method, timeout: timeout, responseType: binary ? 'arraybuffer' : 'text'};
      var contentType = null;
      if (opts.form && typeof opts.form === 'object') {
        var parts = []; for (var k in opts.form) { if (Object.prototype.hasOwnProperty.call(opts.form, k)) parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(opts.form[k]))); }
        cfg.data = parts.join('&'); contentType = 'application/x-www-form-urlencoded';
      } else if (opts.formData && typeof opts.formData === 'object') {
        var p2 = []; for (var k2 in opts.formData) { if (Object.prototype.hasOwnProperty.call(opts.formData, k2)) p2.push(encodeURIComponent(k2) + '=' + encodeURIComponent(String(opts.formData[k2]))); }
        cfg.data = p2.join('&'); contentType = 'application/x-www-form-urlencoded';
      } else if (opts.body !== undefined && opts.body !== null) {
        if (typeof opts.body === 'string') cfg.data = opts.body;
        else { try { cfg.data = JSON.stringify(opts.body); } catch (e) { cfg.data = String(opts.body); } contentType = 'application/json;charset=UTF-8'; }
      }
      if (contentType !== null) {
        var hasCT = false;
        for (var ck in outHeaders) { if (ck.toLowerCase() === 'content-type') { hasCT = true; break; } }
        if (!hasCT) outHeaders['Content-Type'] = contentType;
      }
      cfg.headers = outHeaders;
      var r = JSON.parse(BakaHttp.request(JSON.stringify(cfg)));
      if (r && r.__error) { var err = new Error(r.__error); try { callback(err, null, null); } catch (e2) {} throw err; }
      var data = r ? r.data : null;
      var base64 = (data && typeof data === 'object' && typeof data.__base64 === 'string') ? data.__base64 : null;
      var body = base64 !== null ? b64ToBytes(base64) : parseBody(data);
      var bytes = base64 !== null ? body.length : 0;
      try { if (base64 === null && typeof data === 'string') bytes = unescape(encodeURIComponent(data)).length; } catch (e3) {}
      var resp = {statusCode: r ? r.status : 0, statusMessage: '', headers: (r && r.headers) || {}, bytes: bytes, raw: (base64 !== null ? body : (typeof data === 'string' ? data : '')), body: body};
      try { callback(null, resp, resp.body); } catch (e4) {}
      return resp;
    },
    send: function(eventName, data){
      var name = String(eventName);
      var payload = (data === undefined || data === null) ? null : data;
      if (name === 'inited') {
        try {
          var raw = payload === null ? '{}' : JSON.stringify(payload);
          __bakaLxSourcesDeclaredRaw = (typeof raw === 'string' && raw.length > 0) ? raw : '{}';
        } catch (e) { __bakaLxSourcesDeclaredRaw = '{}'; }
        return 'ok';
      }
      if (name === 'updateAlert') { try { console.log('[lx] ' + String(payload === null ? '' : payload.log)); } catch (e2) {} return 'ok'; }
      if (name === 'showConfigView') return 'ok';
      throw new Error('LX event unsupported: ' + name);
    },
    on: function(eventName, handler){
      if (typeof handler !== 'function') throw new Error('LX event unsupported: ' + String(eventName));
      if (eventName === 'showConfigView') return true;
      if (eventName !== 'request') throw new Error('LX event unsupported: ' + String(eventName));
      globalThis.__lxRequestHandler = handler;
      return true;
    },
    utils: {
      crypto: {
        md5: function(v){ return BakaHttp.md5(String(v)); },
        randomBytes: function(n){ return b64ToBytes(BakaHttp.randomBytes(Number(n) || 0)); },
        aesEncrypt: function(buf, mode, key, iv){
          return b64ToBytes(BakaHttp.aesBytes(String(mode), bytesToB64(buf), bytesToB64(key), bytesToB64(iv || new Uint8Array(0))));
        },
        rsaEncrypt: function(buf, key){ return b64ToBytes(BakaHttp.rsaEncrypt(bytesToB64(buf), String(key))); }
      },
      buffer: {
        from: function(input, encoding){
          var enc = String(encoding || 'utf8').toLowerCase();
          if (typeof input === 'string') {
            if (enc === 'base64') return b64ToBytes(input);
            if (enc === 'hex') { var h = input.replace(/^0x/i, ''); if (h.length % 2) h = '0' + h; var u = new Uint8Array(h.length / 2); for (var i = 0; i < u.length; i++) u[i] = parseInt(h.substr(i * 2, 2), 16); return u; }
            var bin = unescape(encodeURIComponent(input)); var u2 = new Uint8Array(bin.length); for (var j = 0; j < bin.length; j++) u2[j] = bin.charCodeAt(j); return u2;
          }
          var u3 = new Uint8Array(input.length || 0); for (var k = 0; k < u3.length; k++) u3[k] = (input[k] || 0) & 255; return u3;
        },
        bufToString: function(buf, encoding){
          var enc = String(encoding || 'utf8').toLowerCase();
          var bin = ''; for (var i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
          if (enc === 'base64') return btoa(bin);
          if (enc === 'hex') { var out = ''; for (var j = 0; j < bin.length; j++) { var h = bin.charCodeAt(j).toString(16); out += (h.length < 2 ? '0' : '') + h; } return out; }
          try { return decodeURIComponent(escape(bin)); } catch (e) { return bin; }
        }
      },
      zlib: {
        inflate: function(buf){ return b64ToBytes(BakaHttp.inflate(bytesToB64(buf))); },
        deflate: function(buf){ return b64ToBytes(BakaHttp.deflate(bytesToB64(buf))); }
      }
    },
    currentScriptInfo: __info,
    version: '2.0.0',
    env: 'desktop'
  };
})();
function __lxUnwrapUrl(raw, depth){
  if (depth > 3 || raw === undefined || raw === null) return null;
  if (typeof raw === 'string') { var t = raw.replace(/^\s+|\s+$/g, ''); return t.toLowerCase().indexOf('http') === 0 ? t : null; }
  if (typeof raw === 'object') {
    if (raw.__baka_error !== undefined && raw.__baka_error !== null) throw new Error(String(raw.__baka_error));
    var v = raw._v;
    if (typeof v === 'string') { var t2 = v.replace(/^\s+|\s+$/g, ''); if (t2.toLowerCase().indexOf('http') === 0) return t2; }
    var u = raw.url;
    if (typeof u === 'string') { var t3 = u.replace(/^\s+|\s+$/g, ''); if (t3.toLowerCase().indexOf('http') === 0) return t3; }
    if (v !== undefined && v !== null && typeof v === 'object') { var inner = __lxUnwrapUrl(v, depth + 1); if (inner !== null) return inner; }
  }
  return null;
}
function __lxInvoke(source, quality, musicInfoJson){
  var handler = globalThis.__lxRequestHandler;
  if (typeof handler !== 'function') throw new Error('LX 脚本未注册 request 处理器');
  var musicInfo = null;
  try { musicInfo = JSON.parse(musicInfoJson); } catch (e) { musicInfo = null; }
  var raw = handler.call(globalThis.lx, {source: source, action: 'musicUrl', info: {type: quality, musicInfo: musicInfo}});
  var url = __lxUnwrapUrl(raw, 0);
  if (url === null || url.length > 8192) throw new Error('LX 脚本返回了无效的播放地址');
  return JSON.stringify({url: url});
}
''';
