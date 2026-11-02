# -*- coding: utf-8 -*-
"""按实例化端口为厂商IP/加密模块生成空壳（端口一律input，只用于展开检查）。"""
import re, sys
mods = sys.argv[2].split(",")
srcs = sys.argv[3:]
out = []
for m in mods:
    for f in srcs:
        s = open(f, encoding="utf-8", errors="ignore").read()
        s = re.sub(r"//[^\n]*", "", s)
        mt = re.search(r"\b%s\b\s*(#\s*\((.*?)\)\s*)?\w+\s*\((.*?)\)\s*;" % m, s, re.S)
        if mt:
            params = re.findall(r"\.(\w+)\s*\(", mt.group(2) or "")
            ports = re.findall(r"\.(\w+)\s*\(", mt.group(3))
            p = (" #(" + ", ".join("parameter %s = 0" % x for x in params) + ")") if params else ""
            out.append("module %s%s (%s);\n%s\nendmodule\n" % (
                m, p, ", ".join(ports), "\n".join("    input [63:0] %s;" % x for x in ports)))
            break
    else:
        raise SystemExit("未找到实例：" + m)
open(sys.argv[1], "w").write("\n".join(out))
