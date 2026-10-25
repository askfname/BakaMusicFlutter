/// 封面网络请求头：网易云等 CDN 会拒绝 Dart HttpClient 默认 UA（返回 403），
/// 统一改用移动浏览器 UA，避免封面加载失败
library;

const Map<String, String> kArtworkHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
};
