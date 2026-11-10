#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 AstrBot 官方后台（6185）注入「自动登录」引导脚本 v2。

关键发现：AstrBot 前端路由守卫只在「导航到 /auth/login」时才把已登录用户送去 /welcome；
如果页面直接开在 #/auth/login（比如上次退出登录留下的 hash），它就一直停在登录页。
所以注入逻辑必须：拿到 token 后主动 replace 到 #/welcome 并重载。
"""
import os
import shutil

BASE = "/root/src/AstrBot-master/data/dist"
HTML = os.path.join(BASE, "index.html")
ORIG = os.path.join(BASE, "index.html.orig")
MARK = "AB_AUTO_LOGIN"

SNIPPET = """<script>
/* %s v3 */
(function(){
  try{
    var has = !!localStorage.getItem('token');
    var atLogin = location.hash.indexOf('auth/login') >= 0;
    if (has && !atLogin) { return; }
    var go = function(){ location.replace(location.pathname + '#/welcome'); };
    if (has && atLogin) { go(); return; }
    if (sessionStorage.getItem('ab_auto_try')) { return; }
    sessionStorage.setItem('ab_auto_try','1');
    var bases = ['http://127.0.0.1:8080', 'http://' + location.hostname + ':8080'];
    var tryNext = function(i){
      if (i >= bases.length) { return; }
      fetch(bases[i] + '/api/abtoken', {cache:'no-store'})
        .then(function(r){ return r.json(); })
        .then(function(d){
          if (d && d.ok && d.token) {
            localStorage.setItem('token', d.token);
            localStorage.setItem('user', d.user || 'astrbot');
            go();
          } else { tryNext(i + 1); }
        })
        .catch(function(){ tryNext(i + 1); });
    };
    tryNext(0);
  }catch(e){}
})();
</script>
""" % MARK


def main():
    if not os.path.exists(HTML):
        print("NO_INDEX")
        return
    # 有备份就从备份重建，保证脚本可重复执行不会叠加
    src = ORIG if os.path.exists(ORIG) else HTML
    with open(src, encoding="utf-8") as f:
        html = f.read()
    if "AB_AUTO_LOGIN" in html:
        print("SRC_ALREADY_INJECTED")
        return
    if src == HTML and not os.path.exists(ORIG):
        shutil.copy2(HTML, ORIG)
    if "</head>" not in html:
        print("NO_HEAD")
        return
    html = html.replace("</head>", SNIPPET + "</head>", 1)
    with open(HTML, "w", encoding="utf-8") as f:
        f.write(html)
    print("INJECTED_V3", len(html))


if __name__ == "__main__":
    main()
