// 共通の日付フォーマット関数
// usage: const fmt = require('./date-fmt');  // or inline via FMT_JS env
const fmt = (dt) => {
  const y = dt.getFullYear();
  const m = String(dt.getMonth() + 1).padStart(2, '0');
  const d = String(dt.getDate()).padStart(2, '0');
  return y + '-' + m + '-' + d;
};
module.exports = fmt;
